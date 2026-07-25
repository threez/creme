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

_Noreturn void cvm_abort(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
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
static double as_double(Value v, const char *who) {
  if (v.tag == T_INT) return (double)v.as.i;
  if (v.tag == T_FLOAT) return v.as.f;
  cvm_abort("%s: not a number", who);
  return 0.0; /* unreachable */
}

static Value num_add(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) {
    int64_t r;
    if (__builtin_add_overflow(x.as.i, y.as.i, &r)) {
      cvm_abort("+: integer overflow (bignum fallback not implemented in this prototype)");
    }
    return v_int(r);
  }
  return v_float(as_double(x, "+") + as_double(y, "+"));
}

static Value num_sub(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) {
    int64_t r;
    if (__builtin_sub_overflow(x.as.i, y.as.i, &r)) {
      cvm_abort("-: integer overflow (bignum fallback not implemented in this prototype)");
    }
    return v_int(r);
  }
  return v_float(as_double(x, "-") - as_double(y, "-"));
}

static Value num_mul(Value x, Value y) {
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

static int num_le(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) return x.as.i <= y.as.i;
  return as_double(x, "<=") <= as_double(y, "<=");
}

int num_gt(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) return x.as.i > y.as.i;
  return as_double(x, ">") > as_double(y, ">");
}

static int num_ge(Value x, Value y) {
  if (x.tag == T_INT && y.tag == T_INT) return x.as.i >= y.as.i;
  return as_double(x, ">=") >= as_double(y, ">=");
}

static int num_eq(Value x, Value y) {
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
  case T_PORT:
    return a.as.port == b.as.port;
  case T_CLOSURE:
    return a.as.closure == b.as.closure;
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
  CASE(OP_CLOSURE)
    stack[base + ins->a] = v_closure(make_closure(vm, frame, ins->b));
    NEXT();
  CASE(OP_HELPERFORM)
    /* Only ever the top-level `(import ...)` in this program — already
     * fully resolved at compile time, and the global table is pre-seeded
     * with the builtins it would have bound (see cvm/README.md). */
    stack[base + ins->a] = v_nil();
    NEXT();
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
  CASE(OP_NOT)
    stack[base + ins->a] = v_bool(v_falsy(stack[base + ins->b]));
    NEXT();
  CASE(OP_QUASIQUOTE) {
    int idx = 0;
    stack[base + ins->a] = cvm_build_qq(vm, frame->chunk->qq_templates[ins->b], stack, base + ins->c, &idx);
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
