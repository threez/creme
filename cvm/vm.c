/* The dispatch loop — the C counterpart of src/scheme/eval/vm.cr's #execute
 * (fetch/decode/dispatch over an explicit CallFrame stack, non-tail calls
 * push a new register window, tail calls reuse the current frame's window).
 * Only implements the exact opcode subset bench/creme.scm compiles to — see
 * cvm/README.md.
 *
 * Dispatch uses computed goto (GCC/Clang's `&&label`/`goto *ptr` extension)
 * when available, falling back to an ordinary `switch` otherwise (e.g. other
 * compilers). Computed goto chains each handler straight into the next
 * instruction's handler instead of returning to one shared switch/dispatch
 * point — the standard next step up from a switch-based bytecode loop (Lua,
 * CPython 3.11+, etc. all do this), and something Crystal's own VM has no
 * equivalent of (no computed-goto extension in Crystal), so it's a place
 * this VM can beat the Crystal one on the merits of the dispatch mechanism
 * itself, not just on lower per-op overhead. The instruction bodies are
 * written ONCE (via the CASE/NEXT macros below) and compiled into whichever
 * shape is active — see the CVM_COMPUTED_GOTO block for how. `frame`/`base`
 * are cached locals, refreshed only right after an op that can change which
 * frame is on top (a call or a return) — everything else reuses them
 * as-is, matching the invariant that only those ops touch `vm->depth`. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gc.h>

#include "opcodes.h"
#include "profiler.h"
#include "vm.h"

/* Set once by main.c right after allocating the VM -- cvm_abort's own
 * signature (unchanged across ~100+ existing call sites) has no VM*
 * parameter, so this is how it reaches the current run's guard-handler
 * stack. Mirrors profiler.c's own g_profiled_vm (same rationale: a
 * fixed API a signal handler/utility function can't take extra
 * parameters through). */
static VM *g_current_vm = NULL;

void cvm_set_current_vm(VM *vm) {
  g_current_vm = vm;
}

/* Lazily builds the one process-wide condition RecordType every
 * cvm_abort/error-raised condition uses -- mirrors record.cr's own
 * CONDITION_TYPE constant (name "condition", fields "message"/
 * "irritants"). Field/type names are plain T_SYM values pointing at
 * static string literals -- safe (unlike an ordinary T_STR) since T_SYM
 * is never mutated through string-set!. */
static RecordType *get_condition_type(VM *vm) {
  if (vm->condition_type) return vm->condition_type;
  RecordType *rt = GC_MALLOC(sizeof(RecordType));
  rt->name = v_sym("condition", 9);
  rt->n_fields = 2;
  rt->field_names = GC_MALLOC(sizeof(Value) * 2);
  rt->field_names[0] = v_sym("message", 7);
  rt->field_names[1] = v_sym("irritants", 9);
  vm->condition_type = rt;
  return rt;
}

Value cvm_make_condition(VM *vm, const char *msg, size_t msglen, Value irritants) {
  char *copy = GC_MALLOC(msglen ? msglen : 1);
  memcpy(copy, msg, msglen);
  SchemeRecord *r = GC_MALLOC(sizeof(SchemeRecord));
  r->type = get_condition_type(vm);
  r->fields = GC_MALLOC(sizeof(Value) * 2);
  r->fields[0] = v_str(copy, (int)msglen);
  r->fields[1] = irritants;
  return v_record(r);
}

int cvm_is_condition(VM *vm, Value v) {
  return v.tag == T_RECORD && v.as.record->type == get_condition_type(vm);
}

/* Raises `condition` to the nearest installed guard handler -- pops it
 * (guard semantics: an error inside the handler's OWN clause-checking
 * code propagates to an OUTER handler, not this same one again) and
 * longjmps back to OP_PUSHHANDLER's own setjmp call site, which does the
 * rest (unwind draining, upvalue closing, depth collapse). Never
 * returns. The caller MUST have already confirmed vm->n_handlers > 0 --
 * this only pops/jumps, it doesn't fall back to aborting the process. */
_Noreturn void cvm_raise_condition(VM *vm, Value condition) {
  GuardHandler *h = &vm->handlers[--vm->n_handlers];
  vm->pending_condition = condition;
  longjmp(h->buf, 1);
}

_Noreturn void cvm_abort(const char *fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);

  if (g_current_vm && g_current_vm->n_handlers > 0) {
    Value cond = cvm_make_condition(g_current_vm, buf, strlen(buf), v_nil());
    cvm_raise_condition(g_current_vm, cond);
  }

  fputs(buf, stderr);
  fputc('\n', stderr);
  exit(1);
}

int cvm_global_intern(VM *vm, const char *name, int len) {
  for (int i = 0; i < vm->n_globals; i++) {
    if ((int)strlen(vm->globals[i].name) == len && memcmp(vm->globals[i].name, name, (size_t)len) == 0) {
      return i;
    }
  }
  if (vm->n_globals >= CVM_GLOBALS_CAP) cvm_abort("cvm: global table full (CVM_GLOBALS_CAP=%d)", CVM_GLOBALS_CAP);
  int slot = vm->n_globals++;
  vm->globals[slot].name = name;
  vm->globals[slot].value = v_nil();
  vm->globals[slot].bound = 0;
  return slot;
}

void cvm_register_builtin(VM *vm, const char *name, BuiltinFn fn) {
  int slot = cvm_global_intern(vm, name, (int)strlen(name));
  vm->globals[slot].value = v_builtin(fn);
  vm->globals[slot].bound = 1;
}

/* ---- numeric fallback: fixnum-or-double promotion, mirroring
 * Interpreter#num_add/num_sub's role in vm.cr's Add/Sub arms, minus the
 * bignum/rational/complex tower (this bench never needs it — see
 * cvm/README.md's "numeric tower" note). ---- */
double as_double(Value v, const char *who) {
  if (v.tag == T_INT) return (double)v.as.i;
  if (v.tag == T_FLOAT) return v.as.f;
  cvm_abort("%s: not a number", who);
  return 0.0; /* unreachable */
}

Value num_add(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) {
    int64_t r;
    if (__builtin_add_overflow(x.as.i, y.as.i, &r)) {
      cvm_abort("+: integer overflow (bignum fallback not implemented in this prototype)");
    }
    return v_int(r);
  }
  return v_float(as_double(x, "+") + as_double(y, "+"));
}

Value num_sub(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) {
    int64_t r;
    if (__builtin_sub_overflow(x.as.i, y.as.i, &r)) {
      cvm_abort("-: integer overflow (bignum fallback not implemented in this prototype)");
    }
    return v_int(r);
  }
  return v_float(as_double(x, "-") - as_double(y, "-"));
}

Value num_mul(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) {
    int64_t r;
    if (__builtin_mul_overflow(x.as.i, y.as.i, &r)) {
      cvm_abort("*: integer overflow (bignum fallback not implemented in this prototype)");
    }
    return v_int(r);
  }
  return v_float(as_double(x, "*") * as_double(y, "*"));
}

int num_lt(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) return x.as.i < y.as.i;
  return as_double(x, "<") < as_double(y, "<");
}

int num_le(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) return x.as.i <= y.as.i;
  return as_double(x, "<=") <= as_double(y, "<=");
}

int num_gt(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) return x.as.i > y.as.i;
  return as_double(x, ">") > as_double(y, ">");
}

int num_ge(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) return x.as.i >= y.as.i;
  return as_double(x, ">=") >= as_double(y, ">=");
}

int num_eq(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) return x.as.i == y.as.i;
  return as_double(x, "=") == as_double(y, "=");
}

/* ---- eqv? ----
 * Mirrors Scheme.scheme_eqv? for every tag this prototype has: numbers/
 * chars/bools/nil compare by value, strings/symbols by content (this
 * prototype has no symbol interning to compare by identity against, and
 * R7RS leaves string eqv? implementation-defined for non-identical but
 * content-equal strings anyway), everything else (pairs/vectors/closures/
 * builtins/ports) by identity (pointer equality). */
int cvm_eqv(Value a, Value b) {
  if (a.tag != b.tag) {
    /* An int and a float are never eqv? even if numerically equal
     * (R7RS: eqv? distinguishes exactness) — mirrors scheme_eqv?. */
    return 0;
  }
  switch (a.tag) {
  case T_NIL:
    return 1;
  case T_BOOL:
    return a.as.b == b.as.b;
  case T_INT:
    return a.as.i == b.as.i;
  case T_FLOAT:
    return a.as.f == b.as.f;
  case T_CHAR:
    return a.as.i == b.as.i;
  case T_STR:
  case T_SYM:
    return a.as.str.len == b.as.str.len && memcmp(a.as.str.chars, b.as.str.chars, (size_t)a.as.str.len) == 0;
  case T_PAIR:
    return a.as.pair == b.as.pair;
  case T_VECTOR:
    return a.as.vec == b.as.vec;
  case T_BYTEVECTOR:
    return a.as.bv == b.as.bv;
  case T_PROMISE:
    return a.as.promise == b.as.promise;
  case T_VALUES:
    return a.as.values == b.as.values;
  case T_PORT:
    return a.as.port == b.as.port;
  case T_CLOSURE:
    return a.as.closure == b.as.closure;
  case T_CASE_CLOSURE:
    return a.as.case_closure == b.as.case_closure;
  case T_RECORD_TYPE:
    return a.as.record_type == b.as.record_type;
  case T_RECORD:
    return a.as.record == b.as.record;
  case T_RECORD_CALLABLE:
    return a.as.record_callable == b.as.record_callable;
  case T_PARAMETER:
    return a.as.parameter == b.as.parameter;
  case T_BUILTIN:
    return a.as.builtin == b.as.builtin;
  case T_BOX:
    return a.as.box.ptr == b.as.box.ptr;
  default:
    return 0;
  }
}

/* ---- upvalues / closures ---- */

static Value upvalue_get(Upvalue *uv) {
  return uv->slot ? *uv->slot : uv->closed;
}

static void upvalue_close(Upvalue *uv) {
  if (uv->slot) {
    uv->closed = *uv->slot;
    uv->slot = NULL;
  }
}

static void frame_add_opened(Frame *f, Upvalue *uv) {
  if (f->n_opened >= f->cap_opened) {
    f->cap_opened = f->cap_opened ? f->cap_opened * 2 : 4;
    f->opened = GC_REALLOC(f->opened, sizeof(Upvalue *) * (size_t)f->cap_opened);
  }
  f->opened[f->n_opened++] = uv;
}

static void close_upvalues(Frame *f) {
  for (int i = 0; i < f->n_opened; i++) upvalue_close(f->opened[i]);
  f->n_opened = 0;
}

/* Restores every parameter an UnwindAction is tracking to its saved
 * (pre-parameterize) value -- run on ParamPop (normal exit) or by a
 * guard handler draining the unwind stack down past it (see
 * OP_PUSHHANDLER's own resume branch). */
static void run_unwind_action(UnwindAction *a) {
  for (int i = 0; i < a->n; i++) a->params[i]->value = a->saved[i];
}

static Closure *make_closure(VM *vm, Frame *frame, int proto_idx) {
  Chunk *proto = frame->chunk->protos[proto_idx];
  Closure *cl = GC_MALLOC(sizeof(Closure));
  cl->chunk = proto;
  cl->n_upvalues = proto->n_upvalues;
  cl->upvalues = GC_MALLOC(sizeof(Upvalue *) * (size_t)(proto->n_upvalues ? proto->n_upvalues : 1));
  for (int i = 0; i < proto->n_upvalues; i++) {
    UpvalDesc d = proto->upvalues[i];
    if (d.from_parent_local) {
      Upvalue *uv = GC_MALLOC(sizeof(Upvalue));
      uv->slot = &vm->stack[frame->base + d.index];
      uv->closed = v_nil();
      frame_add_opened(frame, uv);
      cl->upvalues[i] = uv;
    } else {
      cl->upvalues[i] = frame->closure->upvalues[d.index];
    }
  }
  return cl;
}

/* ---- records (define-record-type) ----
 * Mirrors record.cr's eval_define_record_type parsing exactly, walking the
 * raw form Cons chain baked into the const pool by HelperForm/
 * HelperFormLocal's own const operand (opcode.cr) -- (define-record-type
 * name (ctor field...) pred (field accessor [mutator])...). */

static int sym_eq(Value a, Value b) {
  return a.as.str.len == b.as.str.len && memcmp(a.as.str.chars, b.as.str.chars, (size_t)a.as.str.len) == 0;
}

static Value list_ref(Value lst, int i) {
  while (i-- > 0) {
    if (lst.tag != T_PAIR) cvm_abort("define-record-type: malformed form");
    lst = lst.as.pair->cdr;
  }
  if (lst.tag != T_PAIR) cvm_abort("define-record-type: malformed form");
  return lst.as.pair->car;
}

static int list_len(Value lst) {
  int n = 0;
  while (lst.tag == T_PAIR) {
    n++;
    lst = lst.as.pair->cdr;
  }
  return n;
}

typedef struct {
  Value *values; /* bindings, in the same order record_type_names.cr returns: type, ctor, pred, then per field [accessor, mutator?] */
  Value *names;  /* parallel Value (T_SYM) array -- only consulted for the top-level HelperForm's by-name global binding */
  int count;
} RecordBindings;

/* Parses `form` and builds a fresh RecordType plus every generated
 * constructor/predicate/accessor/mutator RecordCallable -- one call per
 * define-record-type EXECUTION (not per compile), so HelperFormLocal
 * (inside a function body) genuinely produces a disjoint type on every
 * call, matching R7RS and this project's own real interpreter. */
static RecordBindings build_record_bindings(Value form) {
  if (form.tag != T_PAIR) cvm_abort("define-record-type: malformed form");
  Value parts = form.as.pair->cdr; /* drop the leading `define-record-type` symbol */
  int n_parts = list_len(parts);
  if (n_parts < 3) cvm_abort("define-record-type: malformed");

  Value type_name = list_ref(parts, 0);
  if (type_name.tag != T_SYM) cvm_abort("define-record-type: type name must be a symbol");

  Value ctor_spec = list_ref(parts, 1);
  if (ctor_spec.tag != T_PAIR) cvm_abort("define-record-type: malformed constructor spec");
  Value ctor_name = ctor_spec.as.pair->car;
  if (ctor_name.tag != T_SYM) cvm_abort("define-record-type: constructor name must be a symbol");
  Value ctor_fields_list = ctor_spec.as.pair->cdr;
  int n_ctor_fields = list_len(ctor_fields_list);
  Value *ctor_field_names = GC_MALLOC(sizeof(Value) * (size_t)(n_ctor_fields ? n_ctor_fields : 1));
  {
    Value cur = ctor_fields_list;
    int i = 0;
    while (cur.tag == T_PAIR) {
      Value f = cur.as.pair->car;
      if (f.tag != T_SYM) cvm_abort("define-record-type: constructor field must be a symbol");
      ctor_field_names[i++] = f;
      cur = cur.as.pair->cdr;
    }
  }

  Value pred_name = list_ref(parts, 2);
  if (pred_name.tag != T_SYM) cvm_abort("define-record-type: predicate name must be a symbol");

  int n_fields = n_parts - 3;
  Value *field_names = GC_MALLOC(sizeof(Value) * (size_t)(n_fields ? n_fields : 1));
  Value *accessor_names = GC_MALLOC(sizeof(Value) * (size_t)(n_fields ? n_fields : 1));
  int *has_mutator = GC_MALLOC(sizeof(int) * (size_t)(n_fields ? n_fields : 1));
  Value *mutator_names = GC_MALLOC(sizeof(Value) * (size_t)(n_fields ? n_fields : 1));
  {
    Value cur = parts;
    for (int i = 0; i < 3; i++) cur = cur.as.pair->cdr; /* skip type/ctor/pred */
    int idx = 0;
    while (cur.tag == T_PAIR) {
      Value spec = cur.as.pair->car;
      int speclen = list_len(spec);
      if (speclen != 2 && speclen != 3) cvm_abort("define-record-type: bad field spec");
      Value fname = list_ref(spec, 0);
      if (fname.tag != T_SYM) cvm_abort("define-record-type: field name must be a symbol");
      Value acc = list_ref(spec, 1);
      if (acc.tag != T_SYM) cvm_abort("define-record-type: accessor name must be a symbol");
      field_names[idx] = fname;
      accessor_names[idx] = acc;
      if (speclen == 3) {
        Value mut = list_ref(spec, 2);
        if (mut.tag != T_SYM) cvm_abort("define-record-type: mutator name must be a symbol");
        has_mutator[idx] = 1;
        mutator_names[idx] = mut;
      } else {
        has_mutator[idx] = 0;
      }
      idx++;
      cur = cur.as.pair->cdr;
    }
  }
  for (int i = 0; i < n_ctor_fields; i++) {
    int found = 0;
    for (int j = 0; j < n_fields; j++) {
      if (sym_eq(ctor_field_names[i], field_names[j])) {
        found = 1;
        break;
      }
    }
    if (!found) cvm_abort("define-record-type: constructor field is not a declared field");
  }

  RecordType *rt = GC_MALLOC(sizeof(RecordType));
  rt->name = type_name;
  rt->n_fields = n_fields;
  rt->field_names = field_names;

  int count = 3;
  for (int i = 0; i < n_fields; i++) count += has_mutator[i] ? 2 : 1;

  RecordBindings rb;
  rb.count = count;
  rb.values = GC_MALLOC(sizeof(Value) * (size_t)count);
  rb.names = GC_MALLOC(sizeof(Value) * (size_t)count);

  int idx = 0;
  rb.names[idx] = type_name;
  rb.values[idx] = v_record_type(rt);
  idx++;

  RecordCallable *ctor = GC_MALLOC(sizeof(RecordCallable));
  ctor->type = rt;
  ctor->kind = RC_CTOR;
  ctor->n_ctor_args = n_ctor_fields;
  ctor->ctor_field_indices = GC_MALLOC(sizeof(int) * (size_t)(n_ctor_fields ? n_ctor_fields : 1));
  for (int i = 0; i < n_ctor_fields; i++) {
    for (int j = 0; j < n_fields; j++) {
      if (sym_eq(ctor_field_names[i], field_names[j])) {
        ctor->ctor_field_indices[i] = j;
        break;
      }
    }
  }
  rb.names[idx] = ctor_name;
  rb.values[idx] = v_record_callable(ctor);
  idx++;

  RecordCallable *pred = GC_MALLOC(sizeof(RecordCallable));
  pred->type = rt;
  pred->kind = RC_PRED;
  rb.names[idx] = pred_name;
  rb.values[idx] = v_record_callable(pred);
  idx++;

  for (int i = 0; i < n_fields; i++) {
    RecordCallable *acc = GC_MALLOC(sizeof(RecordCallable));
    acc->type = rt;
    acc->kind = RC_ACCESSOR;
    acc->field_index = i;
    rb.names[idx] = accessor_names[i];
    rb.values[idx] = v_record_callable(acc);
    idx++;
    if (has_mutator[i]) {
      RecordCallable *mut = GC_MALLOC(sizeof(RecordCallable));
      mut->type = rt;
      mut->kind = RC_MUTATOR;
      mut->field_index = i;
      rb.names[idx] = mutator_names[i];
      rb.values[idx] = v_record_callable(mut);
      idx++;
    }
  }

  return rb;
}

/* Invokes one of a record type's generated constructor/predicate/
 * accessor/mutator -- the callable-value counterpart of dispatch_call's
 * T_CLOSURE/T_BUILTIN branches, recognized directly by tag (see
 * RecordCallable's own doc comment in value.h for why: cvm's plain
 * BuiltinFn function pointer has nowhere to stash a captured record
 * type/field index the way a real closure can). */
static Value call_record_callable(RecordCallable *rc, Value *args, int nargs) {
  switch (rc->kind) {
  case RC_CTOR: {
    if (nargs != rc->n_ctor_args) {
      cvm_abort("%.*s: expected %d argument(s), got %d", rc->type->name.as.str.len, rc->type->name.as.str.chars, rc->n_ctor_args, nargs);
    }
    SchemeRecord *r = GC_MALLOC(sizeof(SchemeRecord));
    r->type = rc->type;
    r->fields = GC_MALLOC(sizeof(Value) * (size_t)(rc->type->n_fields ? rc->type->n_fields : 1));
    for (int i = 0; i < rc->type->n_fields; i++) r->fields[i] = v_nil();
    for (int i = 0; i < rc->n_ctor_args; i++) r->fields[rc->ctor_field_indices[i]] = args[i];
    return v_record(r);
  }
  case RC_PRED: {
    if (nargs != 1) cvm_abort("record predicate: expected 1 argument");
    Value v = args[0];
    return v_bool(v.tag == T_RECORD && v.as.record->type == rc->type);
  }
  case RC_ACCESSOR: {
    if (nargs != 1) cvm_abort("record accessor: expected 1 argument");
    Value v = args[0];
    if (v.tag != T_RECORD || v.as.record->type != rc->type) cvm_abort("record accessor: expected a %.*s record", rc->type->name.as.str.len, rc->type->name.as.str.chars);
    return v.as.record->fields[rc->field_index];
  }
  case RC_MUTATOR: {
    if (nargs != 2) cvm_abort("record mutator: expected 2 arguments");
    Value v = args[0];
    if (v.tag != T_RECORD || v.as.record->type != rc->type) cvm_abort("record mutator: expected a %.*s record", rc->type->name.as.str.len, rc->type->name.as.str.chars);
    v.as.record->fields[rc->field_index] = args[1];
    return v_nil();
  }
  default:
    cvm_abort("cvm: bad RecordCallable kind %d", rc->kind);
    return v_nil(); /* unreachable */
  }
}

/* ---- pairs / cxr ---- */

Value cvm_cons(VM *vm, Value car, Value cdr) {
  (void)vm;
  Pair *p = GC_MALLOC(sizeof(Pair));
  p->car = car;
  p->cdr = cdr;
  return v_pair(p);
}

/* Mirrors Op::Cxr's own loop in vm.cr exactly (see opcode.cr's doc comment):
 * bit 1 (LSB-first) => car, 0 => cdr, terminated by the sentinel `code==1`.
 * Deopts to the real builtin on a non-pair in the Crystal VM; this
 * prototype just aborts instead (see cvm/README.md — never hit by this
 * bench). */
static Value exec_cxr(Value v, int code) {
  while (code != 1) {
    if (v.tag != T_PAIR) {
      cvm_abort("cxr: expected pair (fast-path deopt not implemented in this prototype)");
    }
    v = (code & 1) ? v.as.pair->car : v.as.pair->cdr;
    code >>= 1;
  }
  return v;
}

/* ---- quasiquote ----
 * Mirrors vm.cr's own build_qq exactly (see that method's doc comment):
 * QQConst returns its literal verbatim; QQHole/QQSpliceItem pull the next
 * hole's pre-evaluated value from stack[hole_base + *idx] (both compiled
 * into their own contiguous register by the Crystal compiler's
 * compile_qq_holes, in the same depth-first order this walk uses, so no
 * explicit index needs to travel with the template itself); QQList/QQVector
 * rebuild their items in order, splicing a QQSpliceItem's list in place.
 * Needs a growable scratch buffer since a splice can contribute an
 * unbounded number of items to what's otherwise a fixed-size template. */
typedef struct {
  Value *data;
  int len, cap;
} QQBuf;

static void qqbuf_push(QQBuf *b, Value v) {
  if (b->len >= b->cap) {
    b->cap = b->cap ? b->cap * 2 : 8;
    b->data = GC_REALLOC(b->data, sizeof(Value) * (size_t)b->cap);
  }
  b->data[b->len++] = v;
}

static void qq_build_items(VM *vm, QQTemplate *t, Value *stack, int hole_base, int *idx, QQBuf *buf) {
  for (int i = 0; i < t->n_items; i++) {
    QQTemplate *item = t->items[i];
    if (item->tag == QQ_SPLICE) {
      Value list = stack[hole_base + (*idx)++];
      while (list.tag == T_PAIR) {
        qqbuf_push(buf, list.as.pair->car);
        list = list.as.pair->cdr;
      }
      if (list.tag != T_NIL) cvm_abort("quasiquote: unquote-splicing of an improper list");
    } else {
      qqbuf_push(buf, cvm_build_qq(vm, item, stack, hole_base, idx));
    }
  }
}

Value cvm_build_qq(VM *vm, QQTemplate *t, Value *stack, int hole_base, int *idx) {
  switch (t->tag) {
  case QQ_CONST:
    return t->const_value;
  case QQ_HOLE:
    return stack[hole_base + (*idx)++];
  case QQ_LIST: {
    QQBuf buf = {0};
    qq_build_items(vm, t, stack, hole_base, idx, &buf);
    Value result = cvm_build_qq(vm, t->tail, stack, hole_base, idx);
    for (int i = buf.len - 1; i >= 0; i--) result = cvm_cons(vm, buf.data[i], result);
    return result;
  }
  case QQ_VECTOR: {
    QQBuf buf = {0};
    qq_build_items(vm, t, stack, hole_base, idx, &buf);
    Vector *vec = GC_MALLOC(sizeof(Vector));
    vec->len = buf.len;
    vec->items = GC_MALLOC(sizeof(Value) * (size_t)(buf.len ? buf.len : 1));
    memcpy(vec->items, buf.data, sizeof(Value) * (size_t)buf.len);
    return v_vector(vec);
  }
  case QQ_SPLICE:
    /* Only ever appears as a QQList/QQVector item, handled by
     * qq_build_items above — reaching here means a malformed template. */
    return v_nil();
  default:
    cvm_abort("cvm: unknown QQTemplate tag %d", t->tag);
    return v_nil(); /* unreachable */
  }
}

/* ---- case dispatch ----
 * Mirrors Op::CaseDispatch's own lookup in vm.cr exactly: normalize `key`
 * into the same tagged shape CaseDispatchKey uses (only int/char/sym/bool/
 * nil are hashable case-datum types — anything else can never match any
 * entry, matching the Crystal VM's `else -> nil` case), then linear-scan
 * the table's entries for one whose tag+payload match (small tables in
 * practice — `case`'s own clause count — so this trades the Crystal side's
 * O(1) Hash lookup for a simpler O(n) scan rather than adding a real hash
 * table just for this). Returns the table's own default target if nothing
 * matches. */
static int cvm_case_dispatch(Value key, CaseDispatchTable *table) {
  int tag;
  int64_t ival = 0;
  const char *sval = NULL;
  int sval_len = 0;
  switch (key.tag) {
  case T_INT:
    tag = CDK_INT;
    ival = key.as.i;
    break;
  case T_CHAR:
    tag = CDK_CHAR;
    ival = key.as.i;
    break;
  case T_SYM:
    tag = CDK_SYM;
    sval = key.as.str.chars;
    sval_len = key.as.str.len;
    break;
  case T_BOOL:
    tag = CDK_BOOL;
    ival = key.as.b;
    break;
  case T_NIL:
    tag = CDK_NIL;
    break;
  default:
    return table->default_target;
  }
  for (int i = 0; i < table->n_entries; i++) {
    CaseDispatchEntry *e = &table->entries[i];
    if (e->tag != tag) continue;
    if (tag == CDK_SYM) {
      if (e->sval_len == sval_len && memcmp(e->sval, sval, (size_t)sval_len) == 0) return e->target;
    } else if (tag == CDK_NIL || e->ival == ival) {
      return e->target;
    }
  }
  return table->default_target;
}

/* ---- call machinery ---- */

static void bind_args(VM *vm, Chunk *callee, int nargs, int new_base, Value *stack, int arg_base) {
  int fixed = callee->param_count;
  if (callee->has_rest) {
    if (nargs < fixed) cvm_abort("%s: expected at least %d argument(s), got %d", callee->name, fixed, nargs);
    for (int i = 0; i < fixed; i++) stack[new_base + i] = stack[arg_base + i];
    Value rest = v_nil();
    for (int i = nargs - 1; i >= fixed; i--) rest = cvm_cons(vm, stack[arg_base + i], rest);
    stack[new_base + fixed] = rest;
  } else {
    if (nargs != fixed) cvm_abort("%s: expected %d argument(s), got %d", callee->name, fixed, nargs);
    for (int i = 0; i < fixed; i++) stack[new_base + i] = stack[arg_base + i];
  }
}

/* Returns 1 if this delivered the target frame's return (that whole
 * dispatch, chunk or reentrant cvm_apply call, is done — value in *out), 0
 * otherwise (execution continues in the caller). Mirrors VM#deliver_return
 * in vm.cr. `target_depth` is normally 0 (a top-level cvm_run_chunk call)
 * but is the depth cvm_apply pushed its own frame at when this dispatch is
 * a reentrant call from a builtin (see cvm_apply) — either way, "done" means
 * depth has unwound back to whatever it was right before this dispatch's
 * own outermost frame was pushed. */
static int deliver_return(VM *vm, Value val, Value *out, int target_depth) {
  Frame *finished = &vm->frames[vm->depth - 1];
  close_upvalues(finished);
  vm->depth--;
  if (vm->depth == target_depth) {
    *out = val;
    return 1;
  }
  vm->stack[vm->frames[vm->depth - 1].base + finished->return_reg] = val;
  return 0;
}

/* Returns 1 if this call delivered the target frame's return (mirrors
 * deliver_return's own signal), writing the result into *out. `callee` is
 * already resolved by the caller (register / global / local / upvalue —
 * see opcode.cr's Call-family doc comment: `a` is always just the
 * contiguous arg anchor regardless of how the callee itself was found). */
static int dispatch_call(VM *vm, Frame *frame, Instruction *ins, Value callee, int tail, Value *out, int target_depth) {
  int caller_base = frame->base;
  int nargs = ins->b;
  int arg_base = caller_base + ins->a + 1;

  if (callee.tag == T_CASE_CLOSURE) {
    /* Mirrors BytecodeCaseClosure#select_clause exactly: first clause (in
     * source order) whose arity accepts nargs -- a fixed-arity clause
     * needs an exact match, a rest-taking clause accepts anything >= its
     * fixed count. */
    CaseClosure *cc = callee.as.case_closure;
    Closure *matched = NULL;
    for (int i = 0; i < cc->n_clauses; i++) {
      Closure *cl = cc->clauses[i];
      int ok = cl->chunk->has_rest ? nargs >= cl->chunk->param_count : nargs == cl->chunk->param_count;
      if (ok) {
        matched = cl;
        break;
      }
    }
    if (!matched) cvm_abort("case-lambda: no matching clause for %d argument(s)", nargs);
    callee = v_closure(matched);
  }

  if (callee.tag == T_RECORD_CALLABLE) {
    Value result = call_record_callable(callee.as.record_callable, &vm->stack[arg_base], nargs);
    if (tail) {
      return deliver_return(vm, result, out, target_depth);
    }
    vm->stack[caller_base + ins->c] = result;
    return 0;
  }

  if (callee.tag == T_PARAMETER) {
    if (nargs != 0) cvm_abort("parameter: expected 0 arguments, got %d", nargs);
    Value result = callee.as.parameter->value;
    if (tail) {
      return deliver_return(vm, result, out, target_depth);
    }
    vm->stack[caller_base + ins->c] = result;
    return 0;
  }

  if (callee.tag == T_CLOSURE) {
    Closure *cl = callee.as.closure;
    int new_base = tail ? caller_base : caller_base + frame->chunk->num_registers;
    if (new_base + cl->chunk->num_registers > CVM_STACK_CAP) cvm_abort("cvm: register stack exhausted (CVM_STACK_CAP=%d)", CVM_STACK_CAP);
    if (tail) close_upvalues(frame);
    bind_args(vm, cl->chunk, nargs, new_base, vm->stack, arg_base);
    if (tail) {
      frame->chunk = cl->chunk;
      frame->closure = cl;
      frame->base = new_base;
      frame->ip = 0;
      /* return_reg carries over unchanged, matching CallFrame#reset. */
    } else {
      if (vm->depth >= CVM_FRAMES_CAP) cvm_abort("cvm: call depth exceeded (CVM_FRAMES_CAP=%d)", CVM_FRAMES_CAP);
      Frame *nf = &vm->frames[vm->depth];
      nf->chunk = cl->chunk;
      nf->base = new_base;
      nf->closure = cl;
      nf->ip = 0;
      nf->return_reg = ins->c;
      nf->n_opened = 0;
      vm->depth++;
    }
    return 0;
  }

  if (callee.tag == T_BUILTIN) {
    Value result = callee.as.builtin(vm, &vm->stack[arg_base], nargs);
    if (tail) {
      return deliver_return(vm, result, out, target_depth);
    }
    vm->stack[caller_base + ins->c] = result;
    return 0;
  }

  cvm_abort("cvm: attempt to call a non-procedure value");
  return 0; /* unreachable */
}

/* ---- main dispatch loop ---- */

#if defined(__GNUC__) || defined(__clang__)
#define CVM_COMPUTED_GOTO 1
#endif

/* The shared dispatch core, entered either fresh (cvm_run_chunk, always at
 * depth 0) or reentrantly (cvm_apply, called from a builtin like map/apply/
 * a mux request handler — depth > 0, with the caller's own frames still
 * live below). Runs until `vm->depth` unwinds back to `target_depth`
 * (the depth it was AT ENTRY, before this dispatch's own outermost frame —
 * already pushed by the caller — is accounted for), returning that frame's
 * value. See deliver_return's own doc comment for the exact signal. */
static Value cvm_dispatch(VM *vm, int target_depth) {
  Frame *frame = &vm->frames[vm->depth - 1];
  int base = frame->base;
  Value *stack = vm->stack;
  Value final_result;
  Instruction *ins;

#ifdef CVM_COMPUTED_GOTO
  static const void *dispatch_table[OP_COUNT] = {
      [OP_LOADK] = &&L_OP_LOADK, [OP_LOADNIL] = &&L_OP_LOADNIL, [OP_LOADTRUE] = &&L_OP_LOADTRUE,
      [OP_LOADFALSE] = &&L_OP_LOADFALSE, [OP_MOVE] = &&L_OP_MOVE, [OP_GETUPVAL] = &&L_OP_GETUPVAL,
      [OP_GETGLOBAL] = &&L_OP_GETGLOBAL, [OP_DEFGLOBAL] = &&L_OP_DEFGLOBAL, [OP_ADD] = &&L_OP_ADD,
      [OP_SUB] = &&L_OP_SUB, [OP_CONS] = &&L_OP_CONS, [OP_ISNULL] = &&L_OP_ISNULL, [OP_NUMEQ] = &&L_OP_NUMEQ,
      [OP_ADDIMM] = &&L_OP_ADDIMM, [OP_SUBIMM] = &&L_OP_SUBIMM, [OP_MULIMM] = &&L_OP_MULIMM,
      [OP_TESTLTIMM] = &&L_OP_TESTLTIMM, [OP_TESTEQIMM] = &&L_OP_TESTEQIMM, [OP_TESTLT] = &&L_OP_TESTLT,
      [OP_TESTLTUP] = &&L_OP_TESTLTUP, [OP_TESTEQUP] = &&L_OP_TESTEQUP, [OP_TESTFALSE] = &&L_OP_TESTFALSE,
      [OP_JMP] = &&L_OP_JMP, [OP_CXR] = &&L_OP_CXR, [OP_ABS] = &&L_OP_ABS, [OP_CLOSURE] = &&L_OP_CLOSURE,
      [OP_HELPERFORM] = &&L_OP_HELPERFORM, [OP_CALL] = &&L_OP_CALL, [OP_TAILCALL] = &&L_OP_TAILCALL,
      [OP_CALLGLOBAL] = &&L_OP_CALLGLOBAL, [OP_TAILCALLGLOBAL] = &&L_OP_TAILCALLGLOBAL,
      [OP_CALLLOCAL] = &&L_OP_CALLLOCAL, [OP_TAILCALLLOCAL] = &&L_OP_TAILCALLLOCAL,
      [OP_CALLUPVAL] = &&L_OP_CALLUPVAL, [OP_TAILCALLUPVAL] = &&L_OP_TAILCALLUPVAL,
      [OP_RETURN] = &&L_OP_RETURN, [OP_ADDRETURN] = &&L_OP_ADDRETURN, [OP_VECREFUP] = &&L_OP_VECREFUP,
      [OP_VECSETUP] = &&L_OP_VECSETUP, [OP_NOT] = &&L_OP_NOT, [OP_QUASIQUOTE] = &&L_OP_QUASIQUOTE,
      [OP_MUL] = &&L_OP_MUL, [OP_NUMLT] = &&L_OP_NUMLT, [OP_NUMGE] = &&L_OP_NUMGE,
      [OP_NUMLTIMM] = &&L_OP_NUMLTIMM, [OP_NUMGTIMM] = &&L_OP_NUMGTIMM, [OP_NUMEQIMM] = &&L_OP_NUMEQIMM,
      [OP_ADDUP] = &&L_OP_ADDUP, [OP_NUMGEUP] = &&L_OP_NUMGEUP, [OP_NUMLEUP] = &&L_OP_NUMLEUP,
      [OP_ISPAIR] = &&L_OP_ISPAIR, [OP_ISEQ] = &&L_OP_ISEQ, [OP_SETUPVAL] = &&L_OP_SETUPVAL,
      [OP_VECREFIMM] = &&L_OP_VECREFIMM, [OP_VECSETIMM] = &&L_OP_VECSETIMM,
      [OP_STRREFIMM] = &&L_OP_STRREFIMM, [OP_STRREFUP] = &&L_OP_STRREFUP,
      [OP_TESTGE] = &&L_OP_TESTGE, [OP_TESTGTIMM] = &&L_OP_TESTGTIMM, [OP_TESTISEQ] = &&L_OP_TESTISEQ,
      [OP_CASEDISPATCH] = &&L_OP_CASEDISPATCH,
      [OP_NUMLE] = &&L_OP_NUMLE, [OP_NUMGT] = &&L_OP_NUMGT,
      [OP_NUMLEIMM] = &&L_OP_NUMLEIMM, [OP_NUMGEIMM] = &&L_OP_NUMGEIMM,
      [OP_SUBUP] = &&L_OP_SUBUP, [OP_MULUP] = &&L_OP_MULUP,
      [OP_NUMLTUP] = &&L_OP_NUMLTUP, [OP_NUMGTUP] = &&L_OP_NUMGTUP, [OP_NUMEQUP] = &&L_OP_NUMEQUP,
      [OP_ISEQIMM] = &&L_OP_ISEQIMM, [OP_ISEQUP] = &&L_OP_ISEQUP,
      [OP_TESTLE] = &&L_OP_TESTLE, [OP_TESTGT] = &&L_OP_TESTGT,
      [OP_TESTLEIMM] = &&L_OP_TESTLEIMM, [OP_TESTGEIMM] = &&L_OP_TESTGEIMM, [OP_TESTISEQIMM] = &&L_OP_TESTISEQIMM,
      [OP_VECREF] = &&L_OP_VECREF, [OP_VECLEN] = &&L_OP_VECLEN, [OP_VECSET] = &&L_OP_VECSET,
      [OP_VECLENUP] = &&L_OP_VECLENUP, [OP_CASEMATCH] = &&L_OP_CASEMATCH,
      [OP_SUBRETURN] = &&L_OP_SUBRETURN, [OP_MULRETURN] = &&L_OP_MULRETURN,
      /* Ops present in the real Scheme::Op enum (opcode.cr) but not yet
       * implemented here — see cvm/README.md for current coverage. Each
       * gets a real dispatch-table entry (required so OP_COUNT/array
       * sizing/bounds-checking stay correct and a chunk that uses one of
       * these degrades to a clean abort instead of `goto *NULL`), all
       * sharing one abort label since the failure is identical regardless
       * of which one was hit. Closing this list is tracked as follow-up
       * work, grouped by real cost in the project's own planning notes. */
      [OP_SETGLOBAL] = &&L_OP_SETGLOBAL, [OP_STRREF] = &&L_OP_STRREF, [OP_STRSET] = &&L_OP_STRSET,
      [OP_BVREF] = &&L_OP_BVREF, [OP_BVSET] = &&L_OP_BVSET, [OP_CMPZERO] = &&L_OP_CMPZERO,
      [OP_BVREFIMM] = &&L_OP_BVREFIMM, [OP_STRSETIMM] = &&L_OP_STRSETIMM, [OP_BVSETIMM] = &&L_OP_BVSETIMM,
      [OP_STRSETUP] = &&L_OP_STRSETUP, [OP_BVREFUP] = &&L_OP_BVREFUP, [OP_BVSETUP] = &&L_OP_BVSETUP,
      [OP_THROW] = &&L_OP_THROW, [OP_TESTEQ] = &&L_OP_TESTEQ, [OP_TESTLEUP] = &&L_OP_TESTLEUP,
      [OP_TESTGTUP] = &&L_OP_TESTGTUP, [OP_TESTGEUP] = &&L_OP_TESTGEUP, [OP_TESTISEQUP] = &&L_OP_TESTISEQUP,
      [OP_RETURNGLOBAL] = &&L_OP_RETURNGLOBAL, [OP_RETURNUPVAL] = &&L_OP_RETURNUPVAL,
      [OP_NUMLTRETURN] = &&L_OP_NUMLTRETURN, [OP_NUMLERETURN] = &&L_OP_NUMLERETURN, [OP_NUMGTRETURN] = &&L_OP_NUMGTRETURN,
      [OP_NUMGERETURN] = &&L_OP_NUMGERETURN, [OP_NUMEQRETURN] = &&L_OP_NUMEQRETURN, [OP_ISEQRETURN] = &&L_OP_ISEQRETURN,
      [OP_MAKECASECLOSURE] = &&L_OP_MAKECASECLOSURE, [OP_DESTRUCTURE] = &&L_OP_DESTRUCTURE,
      [OP_PARAMPUSH] = &&L_OP_PARAMPUSH, [OP_PARAMPOP] = &&L_OP_PARAMPOP,
      [OP_PUSHHANDLER] = &&L_OP_PUSHHANDLER, [OP_POPHANDLER] = &&L_OP_POPHANDLER, [OP_GUARDRERAISE] = &&L_OP_GUARDRERAISE,
      [OP_MAKEPROMISE] = &&L_OP_MAKEPROMISE, [OP_HELPERFORMLOCAL] = &&L_OP_HELPERFORMLOCAL,
  };
#define CASE(op) L_##op:
#define NEXT()                                          \
  do {                                                   \
    if (vm->profiler.enabled) cvm_profiler_tick(vm, frame); \
    ins = &frame->chunk->instrs[frame->ip++];            \
    goto *dispatch_table[ins->op];                       \
  } while (0)
  if (vm->profiler.enabled) cvm_profiler_tick(vm, frame);
  ins = &frame->chunk->instrs[frame->ip++];
  goto *dispatch_table[ins->op];
#else
#define CASE(op) case op:
#define NEXT() break
  for (;;) {
    if (vm->profiler.enabled) cvm_profiler_tick(vm, frame);
    ins = &frame->chunk->instrs[frame->ip++];
    switch (ins->op) {
#endif

  CASE(OP_LOADK)
    stack[base + ins->a] = frame->chunk->consts[ins->b];
    NEXT();
  CASE(OP_LOADNIL)
    stack[base + ins->a] = v_nil();
    NEXT();
  CASE(OP_LOADTRUE)
    stack[base + ins->a] = v_bool(1);
    NEXT();
  CASE(OP_LOADFALSE)
    stack[base + ins->a] = v_bool(0);
    NEXT();
  CASE(OP_MOVE)
    stack[base + ins->a] = stack[base + ins->b];
    NEXT();
  CASE(OP_GETUPVAL)
    stack[base + ins->a] = upvalue_get(frame->closure->upvalues[ins->b]);
    NEXT();
  CASE(OP_GETGLOBAL) {
    GlobalCell *cell = &vm->globals[ins->b];
    if (!cell->bound) cvm_abort("unbound variable: %s", cell->name);
    stack[base + ins->a] = cell->value;
    NEXT();
  }
  CASE(OP_DEFGLOBAL) {
    GlobalCell *cell = &vm->globals[ins->a];
    cell->value = stack[base + ins->b];
    cell->bound = 1;
    NEXT();
  }
  CASE(OP_SETGLOBAL) {
    GlobalCell *cell = &vm->globals[ins->a];
    if (!cell->bound) cvm_abort("unbound variable: %s", cell->name);
    cell->value = stack[base + ins->b];
    NEXT();
  }
  CASE(OP_ADD)
    stack[base + ins->a] = num_add(stack[base + ins->b], stack[base + ins->c]);
    NEXT();
  CASE(OP_SUB)
    stack[base + ins->a] = num_sub(stack[base + ins->b], stack[base + ins->c]);
    NEXT();
  CASE(OP_CONS)
    stack[base + ins->a] = cvm_cons(vm, stack[base + ins->b], stack[base + ins->c]);
    NEXT();
  CASE(OP_ISNULL)
    stack[base + ins->a] = v_bool(stack[base + ins->b].tag == T_NIL);
    NEXT();
  CASE(OP_NUMEQ)
    stack[base + ins->a] = v_bool(num_eq(stack[base + ins->b], stack[base + ins->c]));
    NEXT();
  CASE(OP_ADDIMM)
    stack[base + ins->a] = num_add(stack[base + ins->b], v_int(ins->c));
    NEXT();
  CASE(OP_SUBIMM)
    stack[base + ins->a] = num_sub(stack[base + ins->b], v_int(ins->c));
    NEXT();
  CASE(OP_MULIMM) {
    Value x = stack[base + ins->b];
    if (x.tag != T_INT) cvm_abort("*: not an integer (float/overflow fallback not implemented in this prototype)");
    int64_t r;
    if (__builtin_mul_overflow(x.as.i, (int64_t)ins->c, &r)) cvm_abort("*: integer overflow (bignum fallback not implemented in this prototype)");
    stack[base + ins->a] = v_int(r);
    NEXT();
  }
  CASE(OP_TESTLTIMM)
    if (!num_lt(stack[base + ins->a], v_int(ins->c))) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTEQIMM)
    if (!num_eq(stack[base + ins->a], v_int(ins->c))) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTLT)
    if (!num_lt(stack[base + ins->a], stack[base + ins->c])) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTLTUP)
    if (!num_lt(stack[base + ins->a], upvalue_get(frame->closure->upvalues[ins->c]))) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTEQUP)
    if (!num_eq(stack[base + ins->a], upvalue_get(frame->closure->upvalues[ins->c]))) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTEQ)
    if (!num_eq(stack[base + ins->a], stack[base + ins->c])) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTLEUP)
    if (!num_le(stack[base + ins->a], upvalue_get(frame->closure->upvalues[ins->c]))) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTGTUP)
    if (!num_gt(stack[base + ins->a], upvalue_get(frame->closure->upvalues[ins->c]))) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTGEUP)
    if (!num_ge(stack[base + ins->a], upvalue_get(frame->closure->upvalues[ins->c]))) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTISEQUP)
    if (!cvm_eqv(stack[base + ins->a], upvalue_get(frame->closure->upvalues[ins->c]))) frame->ip += ins->b;
    NEXT();
  CASE(OP_THROW) {
    Value msg = frame->chunk->consts[ins->a];
    cvm_abort("%.*s", msg.as.str.len, msg.as.str.chars);
  }
  CASE(OP_TESTFALSE)
    if (v_falsy(stack[base + ins->a])) frame->ip += ins->b;
    NEXT();
  CASE(OP_JMP)
    frame->ip += ins->b;
    NEXT();
  CASE(OP_CXR)
    stack[base + ins->a] = exec_cxr(stack[base + ins->b], ins->c);
    NEXT();
  CASE(OP_ABS) {
    Value v = stack[base + ins->b];
    if (v.tag != T_INT || v.as.i == INT64_MIN) {
      cvm_abort("abs: not a (non-INT64_MIN) integer (deopt not implemented in this prototype)");
    }
    stack[base + ins->a] = v_int(v.as.i < 0 ? -v.as.i : v.as.i);
    NEXT();
  }
  CASE(OP_CMPZERO) {
    Value v = stack[base + ins->b];
    if (v.tag != T_INT) {
      cvm_abort("zero?/positive?/negative?: not an integer (deopt not implemented in this prototype)");
    }
    int result;
    switch (ins->c) {
    case 0:
      result = v.as.i == 0;
      break;
    case 1:
      result = v.as.i > 0;
      break;
    case 2:
      result = v.as.i < 0;
      break;
    default:
      cvm_abort("cvm: bad CmpZero test %d", ins->c);
      result = 0; /* unreachable */
    }
    stack[base + ins->a] = v_bool(result);
    NEXT();
  }
  CASE(OP_CLOSURE)
    stack[base + ins->a] = v_closure(make_closure(vm, frame, ins->b));
    NEXT();
  CASE(OP_MAKECASECLOSURE) {
    int n = ins->c;
    CaseClosure *cc = GC_MALLOC(sizeof(CaseClosure));
    cc->n_clauses = n;
    cc->clauses = GC_MALLOC(sizeof(Closure *) * (size_t)(n ? n : 1));
    for (int i = 0; i < n; i++) {
      Value clv = stack[base + ins->b + i];
      if (clv.tag != T_CLOSURE) cvm_abort("cvm: case-lambda clause is not a closure");
      cc->clauses[i] = clv.as.closure;
    }
    stack[base + ins->a] = v_case_closure(cc);
    NEXT();
  }
  CASE(OP_HELPERFORM) {
    /* c=0 (import): already fully resolved at emit time (the global table
     * is pre-seeded with whatever the import would have bound — see
     * cvm/README.md), so a no-op here is correct. c=1 (define-library)
     * never actually appears as a compiled top-level form (only a
     * library's OWN body forms get flattened into the chunk, never the
     * define-library wrapper itself), so it's also unreachable-in-
     * practice as a no-op. c=3 (define-syntax) stays compile-time-only —
     * expanding a syntax-rules use needs real pattern matching, which
     * this VM doesn't implement (see bootstrap.c's bi_expand_if_macro for
     * that narrower, still-open gap). c=4 (defmacro) DOES need real work
     * now: binds a genuine T_MACRO value (see value.h's own doc comment)
     * under the macro's name, so a defmacro EXPORTED from a library
     * compiled straight to bytecode (e.g. sxql-select! from (creme
     * sxql), Crystal-native-precompiled into this image) is recognizable
     * as a macro by expand-if-macro when the self-hosted compiler runs
     * reentrant under cvm and later compiles a USE of it — matching what
     * Crystal's own eval_defmacro does (env.define(name, mac)) for
     * exactly the same reason. c=2 (top-level define-record-type) is the
     * pre-existing real-work case below. */
    if (ins->c == 2) {
      Value form = frame->chunk->consts[ins->b];
      RecordBindings rb = build_record_bindings(form);
      for (int i = 0; i < rb.count; i++) {
        Value name = rb.names[i];
        int slot = cvm_global_intern(vm, name.as.str.chars, name.as.str.len);
        vm->globals[slot].value = rb.values[i];
        vm->globals[slot].bound = 1;
      }
      /* eval_define_record_type returns the raw type-name form itself
       * (not the type descriptor) -- record_type_names.cr's `names[0]`/
       * rb.names[0] is exactly that symbol. */
      stack[base + ins->a] = rb.names[0];
    } else if (ins->c == 4) {
      Value form = frame->chunk->consts[ins->b];
      if (form.tag != T_PAIR) cvm_abort("defmacro: malformed form");
      Value parts = form.as.pair->cdr; /* drop the leading `defmacro` symbol */
      if (parts.tag != T_PAIR) cvm_abort("defmacro: malformed form");
      Value name = parts.as.pair->car;
      if (name.tag != T_SYM) cvm_abort("defmacro: name must be a symbol");
      int slot = cvm_global_intern(vm, name.as.str.chars, name.as.str.len);
      vm->globals[slot].value = v_macro(form.as.pair);
      vm->globals[slot].bound = 1;
      /* eval_defmacro returns the macro's own name symbol (interpreter.cr),
       * same convention record-type-definition's own HelperForm result
       * above already follows. */
      stack[base + ins->a] = name;
    } else {
      stack[base + ins->a] = v_nil();
    }
    NEXT();
  }
  CASE(OP_HELPERFORMLOCAL) {
    Value form = frame->chunk->consts[ins->b];
    RecordBindings rb = build_record_bindings(form);
    for (int i = 0; i < rb.count; i++) stack[base + ins->a + i] = rb.values[i];
    NEXT();
  }
  CASE(OP_VECREFUP) {
    Value vec = upvalue_get(frame->closure->upvalues[ins->b]);
    Value idxv = stack[base + ins->c];
    if (vec.tag != T_VECTOR || idxv.tag != T_INT) cvm_abort("vector-ref: bad arguments");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= vec.as.vec->len) cvm_abort("vector-ref: index %d out of range", idx);
    stack[base + ins->a] = vec.as.vec->items[idx];
    NEXT();
  }
  CASE(OP_VECSETUP) {
    Value vec = upvalue_get(frame->closure->upvalues[ins->a]);
    Value idxv = stack[base + ins->b];
    if (vec.tag != T_VECTOR || idxv.tag != T_INT) cvm_abort("vector-set!: bad arguments");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= vec.as.vec->len) cvm_abort("vector-set!: index %d out of range", idx);
    vec.as.vec->items[idx] = stack[base + ins->c];
    stack[base + ins->d] = vec;
    NEXT();
  }
  CASE(OP_BVREF) {
    Value bv = stack[base + ins->b];
    if (bv.tag != T_BYTEVECTOR) cvm_abort("bytevector-u8-ref: not a bytevector");
    Value idxv = stack[base + ins->c];
    if (idxv.tag != T_INT) cvm_abort("bytevector-u8-ref: not an integer index");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= bv.as.bv->len) cvm_abort("bytevector-u8-ref: index %d out of range", idx);
    stack[base + ins->a] = v_int(bv.as.bv->bytes[idx]);
    NEXT();
  }
  CASE(OP_BVSET) {
    Value bv = stack[base + ins->a];
    if (bv.tag != T_BYTEVECTOR) cvm_abort("bytevector-u8-set!: not a bytevector");
    Value idxv = stack[base + ins->b];
    if (idxv.tag != T_INT) cvm_abort("bytevector-u8-set!: not an integer index");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= bv.as.bv->len) cvm_abort("bytevector-u8-set!: index %d out of range", idx);
    Value val = stack[base + ins->c];
    if (val.tag != T_INT || val.as.i < 0 || val.as.i > 255) cvm_abort("bytevector-u8-set!: byte out of range");
    bv.as.bv->bytes[idx] = (unsigned char)val.as.i;
    NEXT();
  }
  CASE(OP_BVREFIMM) {
    Value bv = stack[base + ins->b];
    if (bv.tag != T_BYTEVECTOR) cvm_abort("bytevector-u8-ref: not a bytevector");
    int idx = ins->c;
    if (idx < 0 || idx >= bv.as.bv->len) cvm_abort("bytevector-u8-ref: index %d out of range", idx);
    stack[base + ins->a] = v_int(bv.as.bv->bytes[idx]);
    NEXT();
  }
  CASE(OP_BVSETIMM) {
    Value bv = stack[base + ins->a];
    if (bv.tag != T_BYTEVECTOR) cvm_abort("bytevector-u8-set!: not a bytevector");
    int idx = ins->b;
    if (idx < 0 || idx >= bv.as.bv->len) cvm_abort("bytevector-u8-set!: index %d out of range", idx);
    Value val = stack[base + ins->c];
    if (val.tag != T_INT || val.as.i < 0 || val.as.i > 255) cvm_abort("bytevector-u8-set!: byte out of range");
    bv.as.bv->bytes[idx] = (unsigned char)val.as.i;
    NEXT();
  }
  CASE(OP_BVREFUP) {
    Value bv = upvalue_get(frame->closure->upvalues[ins->b]);
    Value idxv = stack[base + ins->c];
    if (bv.tag != T_BYTEVECTOR || idxv.tag != T_INT) cvm_abort("bytevector-u8-ref: bad arguments");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= bv.as.bv->len) cvm_abort("bytevector-u8-ref: index %d out of range", idx);
    stack[base + ins->a] = v_int(bv.as.bv->bytes[idx]);
    NEXT();
  }
  CASE(OP_BVSETUP) {
    Value bv = upvalue_get(frame->closure->upvalues[ins->a]);
    Value idxv = stack[base + ins->b];
    if (bv.tag != T_BYTEVECTOR || idxv.tag != T_INT) cvm_abort("bytevector-u8-set!: bad arguments");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= bv.as.bv->len) cvm_abort("bytevector-u8-set!: index %d out of range", idx);
    Value val = stack[base + ins->c];
    if (val.tag != T_INT || val.as.i < 0 || val.as.i > 255) cvm_abort("bytevector-u8-set!: byte out of range");
    bv.as.bv->bytes[idx] = (unsigned char)val.as.i;
    stack[base + ins->d] = bv;
    NEXT();
  }
  CASE(OP_NOT)
    stack[base + ins->a] = v_bool(v_falsy(stack[base + ins->b]));
    NEXT();
  CASE(OP_QUASIQUOTE) {
    int idx = 0;
    stack[base + ins->a] = cvm_build_qq(vm, frame->chunk->qq_templates[ins->b], stack, base + ins->c, &idx);
    NEXT();
  }
  CASE(OP_MAKEPROMISE) {
    Promise *p = GC_MALLOC(sizeof(Promise));
    p->thunk = stack[base + ins->b];
    p->forced = 0;
    p->cached = v_nil();
    stack[base + ins->a] = v_promise(p);
    NEXT();
  }
  CASE(OP_DESTRUCTURE) {
    Value src = stack[base + ins->a];
    Value *vals;
    int n;
    Value single = src;
    if (src.tag == T_VALUES) {
      vals = src.as.values->items;
      n = src.as.values->len;
    } else {
      vals = &single;
      n = 1;
    }
    int fixed = ins->c;
    int has_rest = ins->d != 0;
    if (has_rest) {
      if (n < fixed) cvm_abort("let-values: expected at least %d value(s), got %d", fixed, n);
    } else if (n != fixed) {
      cvm_abort("let-values: expected %d value(s), got %d", fixed, n);
    }
    for (int i = 0; i < fixed; i++) stack[base + ins->b + i] = vals[i];
    if (has_rest) {
      Value rest = v_nil();
      for (int i = n - 1; i >= fixed; i--) rest = cvm_cons(vm, vals[i], rest);
      stack[base + ins->b + fixed] = rest;
    }
    NEXT();
  }
  CASE(OP_MUL)
    stack[base + ins->a] = num_mul(stack[base + ins->b], stack[base + ins->c]);
    NEXT();
  CASE(OP_NUMLT)
    stack[base + ins->a] = v_bool(num_lt(stack[base + ins->b], stack[base + ins->c]));
    NEXT();
  CASE(OP_NUMGE)
    stack[base + ins->a] = v_bool(num_ge(stack[base + ins->b], stack[base + ins->c]));
    NEXT();
  CASE(OP_NUMLTIMM)
    stack[base + ins->a] = v_bool(num_lt(stack[base + ins->b], v_int(ins->c)));
    NEXT();
  CASE(OP_NUMGTIMM)
    stack[base + ins->a] = v_bool(num_gt(stack[base + ins->b], v_int(ins->c)));
    NEXT();
  CASE(OP_NUMEQIMM)
    stack[base + ins->a] = v_bool(num_eq(stack[base + ins->b], v_int(ins->c)));
    NEXT();
  CASE(OP_ADDUP)
    stack[base + ins->a] = num_add(stack[base + ins->b], upvalue_get(frame->closure->upvalues[ins->c]));
    NEXT();
  CASE(OP_NUMGEUP)
    stack[base + ins->a] = v_bool(num_ge(stack[base + ins->b], upvalue_get(frame->closure->upvalues[ins->c])));
    NEXT();
  CASE(OP_NUMLEUP)
    stack[base + ins->a] = v_bool(num_le(stack[base + ins->b], upvalue_get(frame->closure->upvalues[ins->c])));
    NEXT();
  CASE(OP_ISPAIR)
    stack[base + ins->a] = v_bool(stack[base + ins->b].tag == T_PAIR);
    NEXT();
  CASE(OP_ISEQ)
    stack[base + ins->a] = v_bool(cvm_eqv(stack[base + ins->b], stack[base + ins->c]));
    NEXT();
  CASE(OP_SETUPVAL) {
    Upvalue *uv = frame->closure->upvalues[ins->a];
    Value v = stack[base + ins->b];
    if (uv->slot) *uv->slot = v; else uv->closed = v;
    NEXT();
  }
  CASE(OP_VECREFIMM) {
    Value vec = stack[base + ins->b];
    if (vec.tag != T_VECTOR) cvm_abort("vector-ref: not a vector");
    int idx = ins->c;
    if (idx < 0 || idx >= vec.as.vec->len) cvm_abort("vector-ref: index %d out of range", idx);
    stack[base + ins->a] = vec.as.vec->items[idx];
    NEXT();
  }
  CASE(OP_VECSETIMM) {
    Value vec = stack[base + ins->a];
    if (vec.tag != T_VECTOR) cvm_abort("vector-set!: not a vector");
    int idx = ins->b;
    if (idx < 0 || idx >= vec.as.vec->len) cvm_abort("vector-set!: index %d out of range", idx);
    vec.as.vec->items[idx] = stack[base + ins->c];
    NEXT();
  }
  CASE(OP_STRREFIMM) {
    Value sv = stack[base + ins->b];
    if (sv.tag != T_STR) cvm_abort("string-ref: not a string");
    int idx = ins->c;
    if (idx < 0 || idx >= sv.as.str.len) cvm_abort("string-ref: index %d out of range", idx);
    stack[base + ins->a] = v_char((unsigned char)sv.as.str.chars[idx]);
    NEXT();
  }
  CASE(OP_STRREF) {
    Value sv = stack[base + ins->b];
    if (sv.tag != T_STR) cvm_abort("string-ref: not a string");
    Value idxv = stack[base + ins->c];
    if (idxv.tag != T_INT) cvm_abort("string-ref: not an integer index");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= sv.as.str.len) cvm_abort("string-ref: index %d out of range", idx);
    stack[base + ins->a] = v_char((unsigned char)sv.as.str.chars[idx]);
    NEXT();
  }
  /* string-set! mutates the underlying buffer in place — safe here
   * because every T_STR value in this prototype now genuinely owns its
   * own buffer (see builtins.c/strings.c/mux.c/sql.c's Group C fixes
   * closing every place that used to alias a source/literal buffer
   * instead of copying it), so casting away `const` on `chars` (declared
   * that way only to stop MOST code from writing through it) is sound. */
  CASE(OP_STRSET) {
    Value sv = stack[base + ins->a];
    if (sv.tag != T_STR) cvm_abort("string-set!: not a string");
    Value idxv = stack[base + ins->b];
    if (idxv.tag != T_INT) cvm_abort("string-set!: not an integer index");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= sv.as.str.len) cvm_abort("string-set!: index %d out of range", idx);
    Value ch = stack[base + ins->c];
    if (ch.tag != T_CHAR) cvm_abort("string-set!: not a character");
    ((char *)sv.as.str.chars)[idx] = (char)ch.as.i;
    NEXT();
  }
  CASE(OP_STRSETIMM) {
    Value sv = stack[base + ins->a];
    if (sv.tag != T_STR) cvm_abort("string-set!: not a string");
    int idx = ins->b;
    if (idx < 0 || idx >= sv.as.str.len) cvm_abort("string-set!: index %d out of range", idx);
    Value ch = stack[base + ins->c];
    if (ch.tag != T_CHAR) cvm_abort("string-set!: not a character");
    ((char *)sv.as.str.chars)[idx] = (char)ch.as.i;
    NEXT();
  }
  CASE(OP_STRREFUP) {
    Value sv = upvalue_get(frame->closure->upvalues[ins->b]);
    if (sv.tag != T_STR) cvm_abort("string-ref: not a string");
    Value idxv = stack[base + ins->c];
    if (idxv.tag != T_INT) cvm_abort("string-ref: not an integer index");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= sv.as.str.len) cvm_abort("string-ref: index %d out of range", idx);
    stack[base + ins->a] = v_char((unsigned char)sv.as.str.chars[idx]);
    NEXT();
  }
  CASE(OP_STRSETUP) {
    Value sv = upvalue_get(frame->closure->upvalues[ins->a]);
    if (sv.tag != T_STR) cvm_abort("string-set!: not a string");
    Value idxv = stack[base + ins->b];
    if (idxv.tag != T_INT) cvm_abort("string-set!: not an integer index");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= sv.as.str.len) cvm_abort("string-set!: index %d out of range", idx);
    Value ch = stack[base + ins->c];
    if (ch.tag != T_CHAR) cvm_abort("string-set!: not a character");
    ((char *)sv.as.str.chars)[idx] = (char)ch.as.i;
    stack[base + ins->d] = sv;
    NEXT();
  }
  CASE(OP_TESTGE)
    if (!num_ge(stack[base + ins->a], stack[base + ins->c])) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTGTIMM)
    if (!num_gt(stack[base + ins->a], v_int(ins->c))) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTISEQ)
    if (!cvm_eqv(stack[base + ins->a], stack[base + ins->c])) frame->ip += ins->b;
    NEXT();
  CASE(OP_CASEDISPATCH)
    frame->ip = cvm_case_dispatch(stack[base + ins->a], &frame->chunk->case_tables[ins->b]);
    NEXT();
  CASE(OP_CASEMATCH) {
    Value key = stack[base + ins->b];
    Value datums = frame->chunk->consts[ins->c];
    int found = 0;
    if (datums.tag == T_VECTOR) {
      for (int i = 0; i < datums.as.vec->len; i++) {
        if (cvm_eqv(key, datums.as.vec->items[i])) { found = 1; break; }
      }
    }
    stack[base + ins->a] = v_bool(found);
    NEXT();
  }
  CASE(OP_NUMLE)
    stack[base + ins->a] = v_bool(num_le(stack[base + ins->b], stack[base + ins->c]));
    NEXT();
  CASE(OP_NUMGT)
    stack[base + ins->a] = v_bool(num_gt(stack[base + ins->b], stack[base + ins->c]));
    NEXT();
  CASE(OP_NUMLEIMM)
    stack[base + ins->a] = v_bool(num_le(stack[base + ins->b], v_int(ins->c)));
    NEXT();
  CASE(OP_NUMGEIMM)
    stack[base + ins->a] = v_bool(num_ge(stack[base + ins->b], v_int(ins->c)));
    NEXT();
  CASE(OP_SUBUP)
    stack[base + ins->a] = num_sub(stack[base + ins->b], upvalue_get(frame->closure->upvalues[ins->c]));
    NEXT();
  CASE(OP_MULUP)
    stack[base + ins->a] = num_mul(stack[base + ins->b], upvalue_get(frame->closure->upvalues[ins->c]));
    NEXT();
  CASE(OP_NUMLTUP)
    stack[base + ins->a] = v_bool(num_lt(stack[base + ins->b], upvalue_get(frame->closure->upvalues[ins->c])));
    NEXT();
  CASE(OP_NUMGTUP)
    stack[base + ins->a] = v_bool(num_gt(stack[base + ins->b], upvalue_get(frame->closure->upvalues[ins->c])));
    NEXT();
  CASE(OP_NUMEQUP)
    stack[base + ins->a] = v_bool(num_eq(stack[base + ins->b], upvalue_get(frame->closure->upvalues[ins->c])));
    NEXT();
  CASE(OP_ISEQIMM)
    stack[base + ins->a] = v_bool(stack[base + ins->b].tag == T_INT && stack[base + ins->b].as.i == ins->c);
    NEXT();
  CASE(OP_ISEQUP)
    stack[base + ins->a] = v_bool(cvm_eqv(stack[base + ins->b], upvalue_get(frame->closure->upvalues[ins->c])));
    NEXT();
  CASE(OP_TESTLE)
    if (!num_le(stack[base + ins->a], stack[base + ins->c])) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTGT)
    if (!num_gt(stack[base + ins->a], stack[base + ins->c])) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTLEIMM)
    if (!num_le(stack[base + ins->a], v_int(ins->c))) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTGEIMM)
    if (!num_ge(stack[base + ins->a], v_int(ins->c))) frame->ip += ins->b;
    NEXT();
  CASE(OP_TESTISEQIMM)
    if (!(stack[base + ins->a].tag == T_INT && stack[base + ins->a].as.i == ins->c)) frame->ip += ins->b;
    NEXT();
  CASE(OP_VECREF) {
    Value vec = stack[base + ins->b];
    if (vec.tag != T_VECTOR) cvm_abort("vector-ref: not a vector");
    Value idxv = stack[base + ins->c];
    if (idxv.tag != T_INT) cvm_abort("vector-ref: not an integer index");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= vec.as.vec->len) cvm_abort("vector-ref: index %d out of range", idx);
    stack[base + ins->a] = vec.as.vec->items[idx];
    NEXT();
  }
  CASE(OP_VECLEN) {
    Value vec = stack[base + ins->b];
    if (vec.tag != T_VECTOR) cvm_abort("vector-length: not a vector");
    stack[base + ins->a] = v_int(vec.as.vec->len);
    NEXT();
  }
  CASE(OP_VECSET) {
    Value vec = stack[base + ins->a];
    if (vec.tag != T_VECTOR) cvm_abort("vector-set!: not a vector");
    Value idxv = stack[base + ins->b];
    if (idxv.tag != T_INT) cvm_abort("vector-set!: not an integer index");
    int idx = (int)idxv.as.i;
    if (idx < 0 || idx >= vec.as.vec->len) cvm_abort("vector-set!: index %d out of range", idx);
    vec.as.vec->items[idx] = stack[base + ins->c];
    NEXT();
  }
  CASE(OP_VECLENUP) {
    Value vec = upvalue_get(frame->closure->upvalues[ins->b]);
    if (vec.tag != T_VECTOR) cvm_abort("vector-length: not a vector");
    stack[base + ins->a] = v_int(vec.as.vec->len);
    NEXT();
  }
  /* Every op below this line can change which frame is on top (a non-tail
   * Call pushes one, a tail call rewrites the current one's base/chunk, a
   * Return pops one) — `frame`/`base` are refreshed right after, then
   * NEXT() dispatches off the (possibly new) frame's own next instruction.
   * Every op above never touches vm->depth, so it never needs this. */
  CASE(OP_CALL)
    dispatch_call(vm, frame, ins, stack[base + ins->a], 0, &final_result, target_depth);
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  CASE(OP_TAILCALL)
    if (dispatch_call(vm, frame, ins, stack[base + ins->a], 1, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  CASE(OP_CALLGLOBAL) {
    GlobalCell *cell = &vm->globals[ins->d];
    if (!cell->bound) cvm_abort("unbound variable: %s", cell->name);
    dispatch_call(vm, frame, ins, cell->value, 0, &final_result, target_depth);
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_TAILCALLGLOBAL) {
    GlobalCell *cell = &vm->globals[ins->d];
    if (!cell->bound) cvm_abort("unbound variable: %s", cell->name);
    if (dispatch_call(vm, frame, ins, cell->value, 1, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_CALLLOCAL)
    dispatch_call(vm, frame, ins, stack[base + ins->d], 0, &final_result, target_depth);
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  CASE(OP_TAILCALLLOCAL)
    if (dispatch_call(vm, frame, ins, stack[base + ins->d], 1, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  CASE(OP_CALLUPVAL)
    dispatch_call(vm, frame, ins, upvalue_get(frame->closure->upvalues[ins->d]), 0, &final_result, target_depth);
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  CASE(OP_TAILCALLUPVAL)
    if (dispatch_call(vm, frame, ins, upvalue_get(frame->closure->upvalues[ins->d]), 1, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  CASE(OP_RETURN)
    if (deliver_return(vm, stack[base + ins->a], &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  CASE(OP_RETURNGLOBAL) {
    GlobalCell *cell = &vm->globals[ins->a];
    if (!cell->bound) cvm_abort("unbound variable: %s", cell->name);
    if (deliver_return(vm, cell->value, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_RETURNUPVAL) {
    Value v = upvalue_get(frame->closure->upvalues[ins->a]);
    if (deliver_return(vm, v, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_ADDRETURN) {
    Value res = num_add(stack[base + ins->b], stack[base + ins->c]);
    stack[base + ins->a] = res;
    if (deliver_return(vm, res, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_SUBRETURN) {
    Value res = num_sub(stack[base + ins->b], stack[base + ins->c]);
    stack[base + ins->a] = res;
    if (deliver_return(vm, res, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_MULRETURN) {
    Value res = num_mul(stack[base + ins->b], stack[base + ins->c]);
    stack[base + ins->a] = res;
    if (deliver_return(vm, res, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_NUMLTRETURN) {
    Value res = v_bool(num_lt(stack[base + ins->b], stack[base + ins->c]));
    stack[base + ins->a] = res;
    if (deliver_return(vm, res, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_NUMLERETURN) {
    Value res = v_bool(num_le(stack[base + ins->b], stack[base + ins->c]));
    stack[base + ins->a] = res;
    if (deliver_return(vm, res, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_NUMGTRETURN) {
    Value res = v_bool(num_gt(stack[base + ins->b], stack[base + ins->c]));
    stack[base + ins->a] = res;
    if (deliver_return(vm, res, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_NUMGERETURN) {
    Value res = v_bool(num_ge(stack[base + ins->b], stack[base + ins->c]));
    stack[base + ins->a] = res;
    if (deliver_return(vm, res, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_NUMEQRETURN) {
    Value res = v_bool(num_eq(stack[base + ins->b], stack[base + ins->c]));
    stack[base + ins->a] = res;
    if (deliver_return(vm, res, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_ISEQRETURN) {
    Value res = v_bool(cvm_eqv(stack[base + ins->b], stack[base + ins->c]));
    stack[base + ins->a] = res;
    if (deliver_return(vm, res, &final_result, target_depth)) return final_result;
    frame = &vm->frames[vm->depth - 1];
    base = frame->base;
    NEXT();
  }
  CASE(OP_PARAMPUSH) {
    int n = ins->c;
    Parameter **params = GC_MALLOC(sizeof(Parameter *) * (size_t)(n ? n : 1));
    Value *newvals = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
    for (int i = 0; i < n; i++) {
      Value pv = stack[base + ins->a + i];
      if (pv.tag != T_PARAMETER) cvm_abort("parameterize: expected a parameter object");
      Parameter *p = pv.as.parameter;
      Value newval = stack[base + ins->b + i];
      if (p->has_converter) newval = cvm_apply(vm, p->converter, &newval, 1);
      params[i] = p;
      newvals[i] = newval;
    }
    if (vm->n_unwind >= CVM_UNWIND_CAP) cvm_abort("cvm: parameterize/dynamic-wind unwind stack full (CVM_UNWIND_CAP=%d)", CVM_UNWIND_CAP);
    UnwindAction *ua = &vm->unwind_stack[vm->n_unwind++];
    ua->params = params;
    ua->n = n;
    ua->saved = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
    for (int i = 0; i < n; i++) {
      ua->saved[i] = params[i]->value;
      params[i]->value = newvals[i];
    }
    NEXT();
  }
  CASE(OP_PARAMPOP)
    vm->n_unwind--;
    run_unwind_action(&vm->unwind_stack[vm->n_unwind]);
    NEXT();
  /* PushHandler's own CASE body is entered twice in spirit (though only
   * ever compiled/executed as ONE C code path): once normally, right
   * after installing the handler (falls straight through to the final
   * NEXT() below); and again whenever setjmp's corresponding longjmp
   * (cvm_raise_condition, called from cvm_abort or a builtin like
   * error/raise) resumes execution here -- setjmp returns nonzero on
   * that path, and everything inside the `if` is the actual guard
   * "catch": unwind every pending parameterize/dynamic-wind action above
   * this handler's own saved mark, close upvalues for every discarded
   * frame, collapse the call stack straight back to this frame, deliver
   * the condition into the clause-checking code's own register, and jump
   * execution to the clause-checking code itself (`resume_ip`). Mirrors
   * vm.cr's handle_guarded_error exactly, just expressed as "resume a
   * suspended C computation" instead of "catch a Crystal exception". */
  CASE(OP_PUSHHANDLER) {
    if (vm->n_handlers >= CVM_HANDLERS_CAP) cvm_abort("cvm: guard handler stack full (CVM_HANDLERS_CAP=%d)", CVM_HANDLERS_CAP);
    GuardHandler *h = &vm->handlers[vm->n_handlers];
    h->depth = vm->depth;
    h->unwind_mark = vm->n_unwind;
    h->condition_reg = ins->a;
    h->resume_ip = frame->ip + ins->b;
    vm->n_handlers++;
    if (setjmp(h->buf) != 0) {
      for (int i = h->depth; i < vm->depth; i++) close_upvalues(&vm->frames[i]);
      while (vm->n_unwind > h->unwind_mark) {
        vm->n_unwind--;
        run_unwind_action(&vm->unwind_stack[vm->n_unwind]);
      }
      vm->depth = h->depth;
      frame = &vm->frames[vm->depth - 1];
      base = frame->base;
      stack[base + h->condition_reg] = vm->pending_condition;
      frame->ip = h->resume_ip;
      NEXT();
    }
    NEXT();
  }
  CASE(OP_POPHANDLER)
    vm->n_handlers--;
    NEXT();
  CASE(OP_GUARDRERAISE) {
    if (vm->n_handlers > 0) {
      cvm_raise_condition(vm, vm->pending_condition);
    }
    /* No outer handler left -- surface it the same way an unhandled
     * error would, matching the real VM's own SchemeRuntimeError
     * propagating past every guard when nothing catches it. */
    if (cvm_is_condition(vm, vm->pending_condition)) {
      Value msg = vm->pending_condition.as.record->fields[0];
      cvm_abort("%.*s", msg.as.str.len, msg.as.str.chars);
    }
    cvm_abort("cvm: unhandled exception (re-raised, no outer guard)");
  }

  /* Every op in Scheme::Op (opcode.cr) has a real dispatch_table entry
   * above now (full 119/119 parity) -- no L_UNIMPL fallback label is
   * live here anymore. If a future Scheme::Op grows a new member without
   * immediate cvm support, add its [OP_X] = &&L_UNIMPL entry back to the
   * dispatch_table initializer plus a shared `L_UNIMPL:
   * cvm_abort("cvm: opcode %d not implemented", ins->op);` label here
   * (see git history for the exact shape) rather than leaving it an
   * unhandled array slot, which would `goto *NULL`. */
#ifndef CVM_COMPUTED_GOTO
    default:
      cvm_abort("cvm: unimplemented opcode %d", ins->op);
    }
  }
#endif
  return final_result; /* unreachable: every path above returns via a CASE's own `return final_result;` */
}

void cvm_run_chunk(VM *vm, Chunk *chunk) {
  Frame *f0 = &vm->frames[0];
  f0->chunk = chunk;
  f0->base = 0;
  f0->closure = NULL;
  f0->ip = 0;
  f0->return_reg = -1;
  f0->n_opened = 0;
  vm->depth = 1;
  cvm_dispatch(vm, 0);
}

/* Reentrant counterpart of cvm_run_chunk -- runs an already-loaded
 * top-level Chunk (e.g. from cvm_load_from_bytes) from WITHIN an
 * already-running program and returns its value, instead of assuming
 * depth 0/a fresh VM. Mirrors cvm_apply's own T_CLOSURE frame-push
 * exactly (new_base at the current top frame's own register-window
 * boundary), just without bind_args -- a top-level program chunk from
 * BytecodeCompiler.compile_program always takes 0 arguments, the same
 * assumption cvm_run_chunk itself already makes for frame 0. Used by
 * (creme bootstrap)'s cvm-side `load-chunk-bytes` builtin (bootstrap.c). */
Value cvm_run_loaded_chunk(VM *vm, Chunk *chunk) {
  Frame *caller = &vm->frames[vm->depth - 1];
  int new_base = caller->base + caller->chunk->num_registers;
  if (new_base + chunk->num_registers > CVM_STACK_CAP) {
    cvm_abort("cvm: register stack exhausted (CVM_STACK_CAP=%d)", CVM_STACK_CAP);
  }
  if (vm->depth >= CVM_FRAMES_CAP) cvm_abort("cvm: call depth exceeded (CVM_FRAMES_CAP=%d)", CVM_FRAMES_CAP);
  int target_depth = vm->depth;
  Frame *nf = &vm->frames[vm->depth];
  nf->chunk = chunk;
  nf->base = new_base;
  nf->closure = NULL;
  nf->ip = 0;
  nf->return_reg = -1;
  nf->n_opened = 0;
  vm->depth++;
  return cvm_dispatch(vm, target_depth);
}

/* Reentrant "call a Scheme value from C" entry point — used by builtins
 * that themselves invoke a callback (map/for-each/apply) and, later, by
 * cvm/mux.c's request handler. A T_BUILTIN just runs directly (no frame
 * needed); a T_CLOSURE gets a real frame pushed at the CURRENT top frame's
 * own register-window boundary (mirroring dispatch_call's non-tail-call
 * `new_base` computation) and runs via the same dispatch core every
 * ordinary Call op uses, until that one frame (and whatever it itself
 * calls) returns. `args` need not live inside vm->stack — bind_args's own
 * stack-relative copy assumes contiguous operand-addressed registers, which
 * doesn't fit a plain C array a builtin built on its own stack, so this
 * copies args in directly rather than reusing bind_args. */
Value cvm_apply(VM *vm, Value fn, Value *args, int nargs) {
  if (fn.tag == T_BUILTIN) return fn.as.builtin(vm, args, nargs);
  if (fn.tag == T_RECORD_CALLABLE) return call_record_callable(fn.as.record_callable, args, nargs);
  if (fn.tag == T_PARAMETER) {
    if (nargs != 0) cvm_abort("parameter: expected 0 arguments, got %d", nargs);
    return fn.as.parameter->value;
  }
  if (fn.tag == T_CASE_CLOSURE) {
    CaseClosure *cc = fn.as.case_closure;
    Closure *matched = NULL;
    for (int i = 0; i < cc->n_clauses; i++) {
      Closure *cl = cc->clauses[i];
      int ok = cl->chunk->has_rest ? nargs >= cl->chunk->param_count : nargs == cl->chunk->param_count;
      if (ok) {
        matched = cl;
        break;
      }
    }
    if (!matched) cvm_abort("case-lambda: no matching clause for %d argument(s)", nargs);
    fn = v_closure(matched);
  }
  if (fn.tag != T_CLOSURE) cvm_abort("cvm: attempt to apply a non-procedure value");

  Closure *cl = fn.as.closure;
  Frame *caller = &vm->frames[vm->depth - 1];
  int new_base = caller->base + caller->chunk->num_registers;
  if (new_base + cl->chunk->num_registers > CVM_STACK_CAP) {
    cvm_abort("cvm: register stack exhausted (CVM_STACK_CAP=%d)", CVM_STACK_CAP);
  }

  int fixed = cl->chunk->param_count;
  if (cl->chunk->has_rest) {
    if (nargs < fixed) cvm_abort("%s: expected at least %d argument(s), got %d", cl->chunk->name, fixed, nargs);
    for (int i = 0; i < fixed; i++) vm->stack[new_base + i] = args[i];
    Value rest = v_nil();
    for (int i = nargs - 1; i >= fixed; i--) rest = cvm_cons(vm, args[i], rest);
    vm->stack[new_base + fixed] = rest;
  } else {
    if (nargs != fixed) cvm_abort("%s: expected %d argument(s), got %d", cl->chunk->name, fixed, nargs);
    for (int i = 0; i < fixed; i++) vm->stack[new_base + i] = args[i];
  }

  if (vm->depth >= CVM_FRAMES_CAP) cvm_abort("cvm: call depth exceeded (CVM_FRAMES_CAP=%d)", CVM_FRAMES_CAP);
  int target_depth = vm->depth;
  Frame *nf = &vm->frames[vm->depth];
  nf->chunk = cl->chunk;
  nf->base = new_base;
  nf->closure = cl;
  nf->ip = 0;
  nf->return_reg = -1; /* unused: deliver_return signals completion by depth, not a write through this */
  nf->n_opened = 0;
  vm->depth++;
  return cvm_dispatch(vm, target_depth);
}
