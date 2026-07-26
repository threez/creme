/* Runtime chunk/frame/VM structures — the C-side counterpart of
 * src/scheme/compile/chunk.cr's Chunk, src/scheme/compile/bytecode_closure.cr's
 * BytecodeClosure/Upvalue, and src/scheme/eval/vm.cr's CallFrame/VM. See
 * cvm/README.md for the overall design and what's deliberately NOT
 * implemented. */
#ifndef CVM_VM_H
#define CVM_VM_H

#include <setjmp.h>
#include <signal.h>
#include <sys/time.h>

#include "value.h"

typedef struct {
  int op, a, b, c, d;
  int has_pos; /* mirrors ChunkSerializer's per-instruction optional
                * position record (chunk_serializer.cr) — file/line/col
                * below are only meaningful when this is set. Used only by
                * --profile's report to symbolize a sampled (chunk, ip) as
                * file:line. */
  const char *file;
  int line, col;
} Instruction;

/* Mirrors Scheme::UpvalDesc (chunk.cr). `name` is carried for parity with
 * the real format's debug info; cvm doesn't currently use it for anything
 * (upvalues are resolved purely by index). */
typedef struct {
  int from_parent_local;
  int index;
  const char *name;
} UpvalDesc;

/* Mirrors ast.cr's QQTemplate hierarchy (QQConst/QQHole/QQSpliceItem/QQList/
 * QQVector) — see cvm_serializer.cr's write_qq_template for the on-disk
 * shape and vm.c's build_qq for how this is walked at Op::Quasiquote time.
 * QQ_HOLE/QQ_SPLICE carry no payload: the hole's value was already compiled
 * into its own contiguous register by the Crystal compiler's
 * compile_qq_holes, and build_qq pulls it out purely by traversal order. */
typedef struct QQTemplate {
  int tag; /* QQ_CONST/QQ_HOLE/QQ_SPLICE/QQ_LIST/QQ_VECTOR */
  Value const_value;             /* QQ_CONST only */
  struct QQTemplate **items;     /* QQ_LIST/QQ_VECTOR */
  int n_items;
  struct QQTemplate *tail;       /* QQ_LIST only */
} QQTemplate;

/* Mirrors chunk.cr's CaseDispatchKey/CaseDispatchTable — Op::CaseDispatch's
 * jump table. `sval`/`sval_len` are only meaningful for CDK_SYM; every other
 * tag uses `ival` (CDK_INT: the integer; CDK_CHAR: the codepoint; CDK_BOOL:
 * 0/1; CDK_NIL: unused). `target`/`default_target` are ABSOLUTE instruction
 * indices (unlike Jmp/TestFalse's relative offsets) — matches vm.cr's own
 * `frame.ip = ...` assignment for this op. */
typedef struct {
  int tag; /* CDK_* */
  int64_t ival;
  char *sval;
  int sval_len;
  int target;
} CaseDispatchEntry;

typedef struct {
  CaseDispatchEntry *entries;
  int n_entries;
  int default_target;
} CaseDispatchTable;

typedef struct Chunk {
  Instruction *instrs;
  int n_instrs;
  Value *consts;
  int n_consts;
  struct Chunk **protos;
  int n_protos;
  UpvalDesc *upvalues;
  int n_upvalues;
  int param_count;
  int has_rest;
  int num_registers;
  char *name;
  QQTemplate **qq_templates;
  int n_qq_templates;
  CaseDispatchTable *case_tables;
  int n_case_tables;
} Chunk;

/* An open upvalue points into the VM's own register stack; closing copies
 * the value out so it survives the owning frame's registers being reused.
 * Heap-allocated (one per capture) and shared by pointer between the
 * creating frame's `opened` list and the closure's own `upvalues` array —
 * mirrors bytecode_closure.cr's Upvalue exactly. */
struct Upvalue {
  Value *slot; /* NULL once closed */
  Value closed;
};

struct Closure {
  Chunk *chunk;
  Upvalue **upvalues;
  int n_upvalues;
};

typedef struct Frame {
  Chunk *chunk;
  int base;
  Closure *closure; /* NULL for a top-level (non-closure) frame */
  int ip;
  int return_reg; /* meaningless for depth==0's frame */
  Upvalue **opened;
  int n_opened, cap_opened;
} Frame;

typedef struct {
  const char *name;
  Value value;
  int bound;
} GlobalCell;

/* One installed `guard` -- mirrors vm.cr's own GuardHandler exactly
 * (depth/condition_reg/resume_ip), plus the jmp_buf that makes an error
 * raised arbitrarily deep (including through cvm_apply's own reentrant C
 * recursion, e.g. inside a map/for-each callback) unwind straight back
 * here in one step, regardless of how many C stack frames sit between the
 * raise site and here. `depth` is `vm->depth` AT THE TIME PushHandler
 * ran -- vm->frames[depth-1] is guard's own frame, valid indefinitely
 * since `frames` is a fixed array (see CVM_FRAMES_CAP's own comment). */
typedef struct {
  jmp_buf buf;
  int depth;
  int unwind_mark; /* vm->n_unwind at install time -- see UnwindAction */
  int condition_reg;
  int resume_ip;
} GuardHandler;

/* One pending `parameterize` restoration OR `dynamic-wind` after-thunk --
 * mirrors vm.cr's own UnwindAction/ParamRestoreAction for the parameterize
 * case; the dynamic-wind case is this project's own addition, added
 * alongside it since both need EXACTLY the same "run this when either
 * ParamPop happens normally OR a guard handler drains the unwind stack
 * down past this entry" trigger (see run_unwind_action). On ParamPop
 * (normal exit) OR on an error unwinding past this action (a guard
 * handler above it draining the unwind stack down to its own saved
 * mark), a PARAMS action puts every one of its `n` parameters' pre-
 * parameterize value back in one shot; a DYNAMIC_WIND action calls its
 * own `after` thunk with zero arguments. */
typedef enum { UNWIND_PARAMS, UNWIND_DYNAMIC_WIND } UnwindKind;
typedef struct {
  UnwindKind kind;
  /* UNWIND_PARAMS */
  Parameter **params;
  Value *saved;
  int n;
  /* UNWIND_DYNAMIC_WIND */
  Value after;
} UnwindAction;

/* Registers and call frames are fixed-capacity, allocated once, and never
 * reallocated for the VM's whole lifetime — deliberately, not just for
 * simplicity: an open Upvalue holds a raw `Value *` into `stack`, and a
 * realloc-style grow would invalidate every such pointer silently. This
 * bench's recursion depth and register usage are tiny (a few dozen frames,
 * a few registers each), so generous fixed caps cost a few MB and remove an
 * entire class of bugs. A future version wanting to lift this limit would
 * need upvalues to reference the stack indirectly (e.g. index + a stable
 * segment table) instead of a raw pointer. Same reasoning for the guard
 * handler / unwind-action stacks below. */
#define CVM_STACK_CAP (1 << 20)
#define CVM_FRAMES_CAP 8192
#define CVM_GLOBALS_CAP 4096
#define CVM_HANDLERS_CAP 256
#define CVM_UNWIND_CAP 1024

/* ---- profiling (see profiler.h/profiler.c) ---- */

/* One sampled (chunk, instruction) hit, with a running count. The samples
 * table is a small fixed-cap linear-scan array, not a hash table — the
 * number of DISTINCT (chunk, ip) pairs a bench program actually hits is
 * small, so a hash table would be needless machinery (matches this VM's
 * existing "generous fixed caps, no realloc" style for stack/frames). */
#define CVM_PROFILE_VM_SAMPLES_CAP 4096
typedef struct {
  Chunk *chunk;
  int ip;
  long count;
} VmSample;

/* One sampled native-stack frame's return address, captured by the SIGPROF
 * handler (async-signal-safe: no allocation, no symbol resolution — just a
 * raw pointer copy). Resolved to a symbol name only after the run, via
 * dladdr(), and folded into counts there. */
#define CVM_PROFILE_NATIVE_SAMPLES_CAP 65536
typedef struct {
  void *pcs[16];
  int n_pcs;
} NativeSample;

typedef struct {
  int enabled;

  /* VM-level (prof-vm analog): a cooperative, per-instruction countdown
   * ticked from cvm_dispatch's NEXT() — see profiler.c's cvm_profiler_tick. */
  int vm_interval;   /* mean instructions between samples */
  int vm_countdown;
  VmSample vm_samples[CVM_PROFILE_VM_SAMPLES_CAP];
  int n_vm_samples;

  /* Native (prof-native analog): SIGPROF + backtrace(3), installed/torn down
   * narrowly around the profiled run by cvm_profiler_start_native/_stop_native. */
  struct sigaction old_sigprof_action;
  struct itimerval old_itimer;
  NativeSample *native_samples; /* GC_MALLOC'd array, CVM_PROFILE_NATIVE_SAMPLES_CAP entries */
  int n_native_samples;
} Profiler;

/* Allocated via GC_MALLOC (main.c), not calloc/malloc — Boehm GC only
 * scans memory it manages (its own heap objects, plus the C stack/statics
 * as conservative roots); a plain malloc'd VM would make `stack`/`frames`
 * (holding the only references to plenty of GC_MALLOC'd Pairs/Vectors/
 * Closures) invisible to the collector's mark phase, so anything reachable
 * ONLY through a register would look unreachable and get collected out
 * from under a running program. GC_MALLOC also zero-inits, matching the
 * previous calloc's own guarantee. */
struct VM {
  Value stack[CVM_STACK_CAP];
  Frame frames[CVM_FRAMES_CAP];
  int depth;
  GlobalCell globals[CVM_GLOBALS_CAP];
  int n_globals;
  GuardHandler handlers[CVM_HANDLERS_CAP];
  int n_handlers;
  UnwindAction unwind_stack[CVM_UNWIND_CAP];
  int n_unwind;
  Value pending_condition;   /* set by cvm_raise_condition right before its
                               * longjmp; read back by GuardReraise. */
  RecordType *condition_type; /* one process-wide type shared by every
                               * condition cvm_abort/error construct --
                               * mirrors record.cr's own CONDITION_TYPE
                               * constant; lazily built on first use (see
                               * vm.c's get_condition_type). */
  const char *source_file; /* fallback for --profile's file:line report when an
                             * instruction has no per-instruction file of its
                             * own (has_pos unset) — set by main.c from the
                             * loaded .cvmc path itself, since SCB1 (unlike
                             * the old CVM2 header) carries no separate
                             * original-source-file field. */
  Profiler profiler;
};

/* loader.c */
Chunk *cvm_load(const char *path, VM *vm);
Chunk *cvm_load_from_bytes(VM *vm, const unsigned char *bytes, size_t len);

/* vm.c */
void cvm_run_chunk(VM *vm, Chunk *chunk);
Value cvm_run_loaded_chunk(VM *vm, Chunk *chunk);
Value cvm_apply(VM *vm, Value fn, Value *args, int nargs);
int cvm_global_intern(VM *vm, const char *name, int len);
void cvm_register_builtin(VM *vm, const char *name, BuiltinFn fn);
Value cvm_cons(VM *vm, Value car, Value cdr);
Value cvm_build_qq(VM *vm, QQTemplate *t, Value *stack, int hole_base, int *idx);
int cvm_eqv(Value a, Value b);
double as_double(Value v, const char *who);
Value num_add(Value x, Value y);
Value num_sub(Value x, Value y);
Value num_mul(Value x, Value y);
Value num_div(Value x, Value y);
int num_lt(Value x, Value y);
int num_le(Value x, Value y);
int num_gt(Value x, Value y);
int num_ge(Value x, Value y);
int num_eq(Value x, Value y);
/* Canonicalizes `q` (lowest terms, positive denominator) and collapses to
 * a plain T_INT when the denominator is 1 -- the ONE construction path
 * every T_RATIONAL Value goes through (see value.h's Rational doc
 * comment). Aborts if the collapsed integer doesn't fit an int64_t (this
 * prototype has no bignum T_INT to fall back to). Does NOT take ownership
 * of/clear `q` -- callers still own their own local mpq_t. */
Value make_rational_from_mpq(mpq_t q);
/* Collapses to `real` when `imag` is an exact (T_INT) zero, mirroring
 * SchemeComplex.make exactly (a T_RATIONAL is never itself zero, see
 * value.h) -- otherwise wraps both in a fresh T_COMPLEX. */
Value make_complex(Value real, Value imag);
void cvm_set_current_vm(VM *vm);
Value cvm_make_condition(VM *vm, const char *msg, size_t msglen, Value irritants);
int cvm_is_condition(VM *vm, Value v);
_Noreturn void cvm_raise_condition(VM *vm, Value condition);

/* profiler.c */
void cvm_profiler_tick(VM *vm, Frame *frame);
void cvm_profiler_start_native(VM *vm);
void cvm_profiler_stop_native(VM *vm);
void cvm_profiler_report(VM *vm);

/* builtins.c */
void cvm_register_builtins(VM *vm);

_Noreturn void cvm_abort(const char *fmt, ...);

#endif
