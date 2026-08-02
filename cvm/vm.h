/* Runtime chunk/frame/VM structures — the C-side counterpart of
 * src/scheme/compile/chunk.cr's Chunk, src/scheme/compile/bytecode_closure.cr's
 * BytecodeClosure/Upvalue, and src/scheme/eval/vm.cr's CallFrame/VM. See
 * cvm/README.md for the overall design and what's deliberately NOT
 * implemented. */
#ifndef CVM_VM_H
#define CVM_VM_H

#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/time.h>

#include "value.h"

/* HOT struct: exactly what cvm_dispatch's NEXT() fetches, once per executed
 * opcode. Deliberately kept to five ints (20 bytes) with NOTHING else in it
 * -- the per-instruction source position (file/line/col) that used to live
 * here too pushed this to 40 bytes, half of which the dispatch loop never
 * reads, so every instruction fetch pulled a whole extra cache line's worth
 * of dead weight through the D-cache on a bytecode-dispatch-bound workload
 * (nqueens, fib, tak -- tight loops of tiny ops where instruction-stream
 * cache density dominates). That cold position data now lives in a parallel
 * `InsPos` array on Chunk (see below), touched ONLY by --profile's report,
 * exactly the same hot/cold-split reasoning as the Value 24->16 shrink in
 * doc/optimization-cvm.md's Section 1. */
typedef struct {
  int op, a, b, c, d;
} Instruction;

/* COLD, parallel to Chunk.instrs (same index space): the optional per-
 * instruction source position ChunkSerializer emits (chunk_serializer.cr).
 * `has_pos` mirrors that serialized optional flag; file/line/col are only
 * meaningful when it's set. Read ONLY by --profile's report to symbolize a
 * sampled (chunk, ip) as file:line -- never by the dispatch loop -- so
 * keeping it out of the hot Instruction struct above costs the profiler one
 * extra indexed load it doesn't care about the latency of, and saves the
 * dispatch loop 20 bytes per instruction it fetches millions of times. */
typedef struct {
  int has_pos;
  const char *file;
  int line, col;
} InsPos;

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
  InsPos *positions; /* parallel to instrs (n_instrs entries), --profile-only
                      * -- see InsPos's own doc comment. NULL is never valid
                      * once a chunk is loaded; loader.c always allocates it
                      * alongside instrs. */
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
 * since `frames` is a fixed-capacity array for the VM's whole lifetime,
 * never reallocated after cvm_alloc_vm builds it (see its own doc
 * comment, and CVM_DEFAULT_FRAMES_CAP's, for why). */
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
 * own `after` thunk with zero arguments. An EXC_HANDLER action (with-
 * exception-handler's own installed-handler bookkeeping, builtins.c's
 * bi_with_exception_handler) restores vm->n_exc_handlers to `mark`
 * directly in C -- NOT via cvm_apply'ing a Scheme thunk the way
 * DYNAMIC_WIND does, since restoring to an absolute remembered depth
 * (rather than blindly decrementing by one) stays correct even if
 * raise-continuable's own pop-call-pushback around the installed
 * handler is still mid-flight when this action runs (the handler
 * itself escaping past its own installer via a raised exception or a
 * captured continuation, before raise-continuable's temporary pop was
 * ever pushed back) -- a plain "pop one" would double-pop in that case. */
typedef enum { UNWIND_PARAMS, UNWIND_DYNAMIC_WIND, UNWIND_EXC_HANDLER } UnwindKind;
typedef struct {
  UnwindKind kind;
  /* UNWIND_PARAMS */
  Parameter **params;
  Value *saved;
  int n;
  /* UNWIND_DYNAMIC_WIND */
  Value after;
  /* UNWIND_EXC_HANDLER */
  int mark;
} UnwindAction;

/* Registers and call frames are fixed-capacity for a given VM's whole
 * lifetime, allocated once (by cvm_alloc_vm, vm.c) and never reallocated
 * afterward — deliberately, not just for simplicity: an open Upvalue
 * holds a raw `Value *` into `stack`, and a realloc-style grow would
 * invalidate every such pointer silently. This bench's recursion depth
 * and register usage are tiny (a few dozen frames, a few registers
 * each), so generous fixed caps cost a few MB and remove an entire
 * class of bugs. A future version wanting to lift this limit (as
 * opposed to just choosing a different one up front) would need
 * upvalues to reference the stack indirectly (e.g. index + a stable
 * segment table) instead of a raw pointer. Same reasoning for the guard
 * handler / unwind-action stacks below.
 *
 * CVM_DEFAULT_STACK_CAP/CVM_DEFAULT_FRAMES_CAP are just that -- the
 * defaults cvm_alloc_vm falls back to when asked for 0, not a hard
 * limit baked into the VM struct's own layout the way they used to be
 * (`Value stack[CVM_STACK_CAP]`/`Frame frames[CVM_FRAMES_CAP]` as fixed
 * array MEMBERS). An embedder wanting to cap a given script's resource
 * use tighter (or looser) than these calls cvm_alloc_vm with its own
 * values instead -- see that function's own doc comment. */
#define CVM_DEFAULT_STACK_CAP (1 << 20)
#define CVM_DEFAULT_FRAMES_CAP 8192
#define CVM_GLOBALS_CAP 4096
#define CVM_HANDLERS_CAP 256
#define CVM_UNWIND_CAP 1024
#define CVM_EXC_HANDLERS_CAP 256

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

/* Shared across a profiled VM AND every child VM cvm_new_child_vm ever
 * creates from it (see that function's own comment) -- (creme actor)'s
 * spawn and (creme mux)'s worker-pool/inline dispatch VMs all run
 * Scheme code on THEIR OWN VM instance, never the one --profile actually
 * enabled tracking on, so without this, cvm_profiler_tick's samples
 * would only ever reflect whatever the ORIGINAL top-level thread itself
 * happened to be doing (which, for a spawn-then-block-forever program,
 * is essentially nothing) -- one shared accumulation buffer, mutex-
 * protected, is what actually lets "hot Scheme functions" reflect work
 * done by every thread a profiled program spins up. The mutex is only
 * ever taken on the rare "about to record a sample" path (once every
 * ~vm_interval instructions per thread, not per instruction -- see
 * cvm_profiler_tick's own countdown check, still lock-free and
 * per-VM-instance), so this adds no meaningful per-instruction cost. */
typedef struct {
  VmSample vm_samples[CVM_PROFILE_VM_SAMPLES_CAP];
  int n_vm_samples;
  pthread_mutex_t mu;
} SharedVmSamples;

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
   * ticked from cvm_dispatch's NEXT() — see profiler.c's cvm_profiler_tick.
   * `vm_interval`/`vm_countdown` stay PER-VM-INSTANCE (each thread jitters
   * and decrements its own, lock-free, matching the original single-
   * threaded design exactly) -- only where the countdown actually hits
   * zero and a sample gets recorded does it touch `shared_vm_samples`,
   * below, which is genuinely shared (see SharedVmSamples's own comment). */
  int vm_interval;   /* mean instructions between samples */
  int vm_countdown;
  SharedVmSamples *shared_vm_samples; /* NULL unless enabled */

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
  Value *stack;      /* GC_MALLOC'd once by cvm_alloc_vm, sized stack_cap */
  int stack_cap;
  Frame *frames;     /* GC_MALLOC'd once by cvm_alloc_vm, sized frames_cap */
  int frames_cap;
  int depth;
  GlobalCell globals[CVM_GLOBALS_CAP];
  int n_globals;
  GuardHandler handlers[CVM_HANDLERS_CAP];
  int n_handlers;
  UnwindAction unwind_stack[CVM_UNWIND_CAP];
  int n_unwind;
  /* with-exception-handler's installed-handler stack (builtins.c's
   * bi_with_exception_handler/bi_raise_continuable/bi_raise) -- a
   * genuine cvm-native builtin now, not just a Scheme-level shim in
   * cvm/compiler-run.scm (see that file's own comment on why it used to
   * live there only, and why that meant precompiled --emit-cvm programs
   * couldn't use with-exception-handler at all). */
  Value exc_handlers[CVM_EXC_HANDLERS_CAP];
  int n_exc_handlers;
  Value pending_condition;   /* set by cvm_raise_condition right before its
                               * longjmp; read back by GuardReraise. */
  int pending_handler_idx;  /* set by cvm_raise_condition right before its
                              * longjmp, to the vm->handlers[] index it is
                              * targeting -- read back by OP_PUSHHANDLER's
                              * own resume branch instead of trusting a
                              * stack-local. PushHandler's CASE body is one
                              * shared piece of code re-executed once per
                              * nested guard within the SAME C stack frame
                              * (no intervening cvm_apply recursion): a
                              * local variable set at install time and read
                              * again after the corresponding longjmp is
                              * NOT reliably preserved even if declared
                              * volatile, because every dynamic install
                              * shares the exact same physical stack slot/
                              * register for that local (it's a loop, not
                              * real recursion) -- a LATER nested guard's
                              * own install simply overwrites whatever an
                              * EARLIER, still-pending guard's local held,
                              * so by the time that earlier guard's own
                              * longjmp resumes, the shared local no longer
                              * holds its value. Communicating the target
                              * index through this heap field instead (set
                              * immediately before longjmp, read immediately
                              * after resuming) sidesteps that entirely --
                              * it's a plain memory read on the far side of
                              * the jump, not a value carried across it. */
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
  /* current-output-port/current-input-port's own backing Parameter
   * objects (builtins.c's cvm_init_current_ports) -- one per VM
   * instance, which already gives them the same per-actor-thread
   * independence a `_Thread_local` C global would (see cvm_new_child_vm,
   * vm.c), while also being reachable as a real T_PARAMETER through the
   * ordinary global table (so `parameterize` can target them, unlike
   * when these were plain 0-arg builtins). */
  Parameter *current_output_param;
  Parameter *current_input_param;
  Profiler profiler;

  /* (creme actor) (actor.c): set only for a spawned actor's own VM (the
   * main script's VM leaves has_actor_unwind at its GC_MALLOC zero-init
   * default), so an uncaught cvm_abort inside that actor's thunk longjmps
   * here (see cvm_abort, vm.c) instead of exit()ing the whole process —
   * the actor thread's entry function reads abort_message back out to
   * build that actor's own <down> notification, then unwinds just that
   * OS thread. */
  jmp_buf actor_unwind;
  int has_actor_unwind;
  char abort_message[1024];

  /* cvm_register_required_builtins's (main.c) own idempotency tracking,
   * PER-VM (an actor's cvm_new_child_vm gets its own fresh globals table,
   * so it needs its own fresh "what have I registered so far" state too,
   * not a process-wide one). Needed because that function is now called
   * repeatedly over a single VM's lifetime -- not just once at startup,
   * but every time bootstrap.c's bi_load_chunk_bytes loads another chunk
   * (every nested self-hosted-compiler library load, every `eval` call) --
   * so it must skip any family (including the always-on base/write pair)
   * it already registered on THIS vm, rather than unconditionally
   * re-running every register_fn every time: re-registering would silently
   * overwrite a real Scheme-level redefinition of a builtin name (e.g.
   * prim_call_spec.scm's own "deopts + to a runtime redefinition" cases,
   * which permanently shadow `+` at the global level) back to the
   * original native closure, breaking exactly that kind of test. See
   * cvm_register_required_builtins's own doc comment (main.c) for the bit
   * layout `registered_family_mask` uses. */
  int base_write_registered;
  /* uint64_t, not int -- BUILTIN_FAMILIES (main.c) plus the 3 CVM_EXTRA_BIT_*
   * bits now needs more than 31 usable bits (32-bit `int` overflowed --
   * UB on the shift itself once the family count + 2 reached 31 -- the
   * moment a new family got added past that point; confirmed via a real
   * `examples_cvm_spec.scm` regression when (creme pkey)/(creme x509)
   * pushed the count over the edge). */
  uint64_t registered_family_mask;

  /* cvm_cons's (vm.c) own batch-refilled freelist -- GC_malloc_many
   * (Boehm GC's own sanctioned API for exactly this: many same-size,
   * high-churn allocations) hands back a whole chunk of Pair-sized
   * blocks linked through their own first word at once, so a `cons`-
   * heavy loop pays the allocator's per-call lock/size-class-lookup
   * overhead only once per chunk instead of once per cons cell. Every
   * block GC_malloc_many returns is a REAL, individually-collectible
   * GC_MALLOC'd object from the moment it's handed out (not a manually
   * "freed"/recycled one) -- there is no reuse-after-still-referenced
   * risk here the way an application-level object pool would have, since
   * nothing is ever put back once cvm_cons links it into a real pair. */
  void *pair_freelist;
};

/* Note: condition_type (above) is lazily built PER-VM (see vm.c's
 * get_condition_type) despite its own doc comment calling it "process-
 * wide" -- true for the single-VM case this project always had before
 * (creme actor), but each spawned actor's VM now lazily builds its OWN
 * RecordType instance the first time IT raises a condition, so two
 * actors' condition objects are tagged with DIFFERENT (if
 * structurally-identical) RecordType pointers. Harmless for everything
 * actor.c currently sends between actors (plain data, records, actor
 * refs -- never a condition object itself), but worth knowing before
 * ever trying to pass a raised condition across an actor boundary. */

/* loader.c
 *
 * `required_families_out`/`required_families_count_out`: if non-NULL, filled
 * in with the SCB1 "required families" metadata section (an array of
 * GC_MALLOC'd, NUL-terminated C strings, and its count) that now sits
 * between the magic and the chunk body -- see chunk_serializer.cr's
 * `serialize`. Pass NULL for both if the caller doesn't need the list; the
 * bytes are still correctly skipped either way so the chunk body that
 * follows is read from the right offset. */
Chunk *cvm_load(const char *path, VM *vm, char ***required_families_out, int *required_families_count_out);
Chunk *cvm_load_from_bytes(VM *vm, const unsigned char *bytes, size_t len, char ***required_families_out, int *required_families_count_out);

/* Peeks just the magic + required-families metadata section of `path`
 * (opening and closing the file itself, independently of cvm_load) so a
 * caller -- main.c -- can decide which builtin families to register BEFORE
 * calling cvm_load for real. See loader.c's own doc comment on this
 * function for why this is a separate open rather than sharing a Reader
 * with cvm_load. `names_out`/`count_out` follow the same GC_MALLOC'd-array/
 * NUL-terminated-C-string convention as cvm_load's own out params; pass
 * NULL for both if not needed (though then there's no reason to call this
 * at all). */
void cvm_peek_required_families(const char *path, char ***names_out, int *count_out);

/* main.c
 *
 * Registers the two always-on families (base/write) plus, for every other
 * name in `families`, whichever cvm_register_*_builtins function that
 * family maps to (silently skipping a name cvm has no native family for --
 * see this function's own doc comment in main.c). Called once at startup
 * with the loaded file's own required-families metadata, and again by
 * bootstrap.c's bi_load_chunk_bytes (cvm's "compiler mode" case: the
 * startup call only sees precompiled compiler-run.cvmc's own near-empty
 * list, since the REAL target script's required families aren't known
 * until the self-hosted compiler actually compiles it, well after startup
 * registration already ran) with the real target's own list. */
void cvm_register_required_builtins(VM *vm, char **families, int n_families);

/* vm.c */
void cvm_run_chunk(VM *vm, Chunk *chunk);
Value cvm_run_loaded_chunk(VM *vm, Chunk *chunk);
Value cvm_apply(VM *vm, Value fn, Value *args, int nargs);
int cvm_global_intern(VM *vm, const char *name, int len);
/* Allocates a fresh, zero-initialized VM plus its stack/frames arrays
 * (GC_MALLOC'd once, sized `stack_cap`/`frames_cap` -- see those fields'
 * own doc comment in the VM struct above for why never reallocated
 * afterward). Either argument may be 0 to take the CVM_DEFAULT_STACK_CAP/
 * CVM_DEFAULT_FRAMES_CAP default. Every VM-creation site in this codebase
 * (the main script's own top-level VM in main.c, cvm_new_child_vm's actor
 * spawn, cvm_new_empty_vm's environment/eval target, all below) goes
 * through this one function, so an embedder wanting to cap a given
 * script's resource use tighter (or looser) than the defaults has exactly
 * one place to do it consistently, rather than 3+ raw GC_MALLOC(sizeof(VM))
 * call sites to keep in sync by hand. */
VM *cvm_alloc_vm(int stack_cap, int frames_cap);
VM *cvm_new_child_vm(VM *parent);
void cvm_setup_frame0(VM *vm);
VM *cvm_new_empty_vm(void);
void cvm_register_builtin(VM *vm, const char *name, BuiltinFn fn);
Value cvm_cons(VM *vm, Value car, Value cdr);
/* builtins.c's `+`/`-`/`*`/car/cdr/cons implementations, exposed (not
 * `static`) purely so vm.c's OP_CALLGLOBAL call-site quickening (see
 * opcodes.h's OP_QCALLGLOBAL_* doc comment) can compare a global cell's
 * CURRENT value against these exact function pointers by identity, with no
 * string/name lookup involved. Not meant to be called directly from
 * outside builtins.c/vm.c — go through the normal global binding instead. */
Value bi_plus(VM *vm, Value *args, int nargs);
Value bi_minus(VM *vm, Value *args, int nargs);
Value bi_star(VM *vm, Value *args, int nargs);
Value bi_cons(VM *vm, Value *args, int nargs);
Value bi_car(VM *vm, Value *args, int nargs);
Value bi_cdr(VM *vm, Value *args, int nargs);
Value bi_modulo(VM *vm, Value *args, int nargs);
/* Same reasoning as bi_plus/etc. above, for string-append/number->string
 * (builtins.c) and hash-table-set!/hash-table-ref (hashtable.c) -- exposed
 * only so vm.c's quicken_callglobal_op can identity-compare a global
 * cell's current value against them. */
Value bi_string_append(VM *vm, Value *args, int nargs);
Value bi_number_to_string(VM *vm, Value *args, int nargs);
Value bi_hash_table_set(VM *vm, Value *args, int nargs);
Value bi_hash_table_ref(VM *vm, Value *args, int nargs);
/* Shared Port read/write primitives (builtins.c) -- exposed so a module
 * outside builtins.c (e.g. csv.c's streaming reader/writer) can read/
 * write through an arbitrary Port the same kind-dispatched way write-
 * string/read-char etc. do, without duplicating that dispatch logic.
 * cvm_port_read_char/cvm_port_peek_char return -1 at EOF, else a byte
 * value 0-255 (this prototype's chars are byte-wide, see string-ref's
 * own "byte-wise" comment). */
void cvm_port_write_bytes(Port *p, const char *bytes, int len);
int cvm_port_read_char(Port *p);
int cvm_port_peek_char(Port *p);
Value cvm_build_qq(VM *vm, QQTemplate *t, Value *stack, int hole_base, int *idx);
int cvm_eqv(Value a, Value b);
int cvm_equal(Value a, Value b);
/* A 64-bit hash consistent with cvm_equal (any a, b with cvm_equal(a,b) must
 * have cvm_hash_value(a) == cvm_hash_value(b)) -- see builtins.c's own
 * comment next to cvm_equal_rec for how it mirrors that function tag-for-
 * tag. Used by hashtable.c's Verstable-backed hash-table type. */
uint64_t cvm_hash_value(Value v);
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
void cvm_register_base_builtins(VM *vm);
void cvm_register_cxr_builtins(VM *vm);
void cvm_register_complex_builtins(VM *vm);
void cvm_register_char_builtins(VM *vm);
void cvm_register_write_builtins(VM *vm);
void cvm_register_process_context_builtins(VM *vm);
void cvm_register_lazy_builtins(VM *vm);
void cvm_register_math_builtins(VM *vm);
void cvm_register_introspection_builtins(VM *vm);
void cvm_register_file_builtins(VM *vm);
void cvm_register_env_builtins(VM *vm);

/* Builds vm->current_output_param/vm->current_input_param (fresh
 * Parameter objects, defaulting to real stdout/stdin) -- see their own
 * VM-struct doc comment above. Called once by cvm_register_base_builtins
 * for the top-level VM, and again by cvm_new_child_vm (vm.c) for every
 * freshly spawned actor VM, so each gets its OWN independent pair
 * rather than inheriting the parent's via that function's own wholesale
 * `globals` memcpy. */
void cvm_init_current_ports(VM *vm);

/* (scheme process-context)'s command-line -- set once by main.c before
 * running anything, from this process's own argv: any arguments trailing
 * the target file path (cvm has no other flags a script consumer would
 * ever need to see). `argv`'s lifetime is the whole process (points
 * straight into main's own argv array), so no copy is made. */
void cvm_set_command_line_args(const char *program_name, int argc, char **argv);

_Noreturn void cvm_abort(const char *fmt, ...);

/* Installed as Boehm GC's own out-of-memory callback (GC_set_oom_fn,
 * main.c, right after GC_INIT()) -- process-wide, covering every thread
 * (the main script's VM and every spawned actor's own VM alike). Without
 * this, GC's default oom_fn just returns NULL, and every GC_MALLOC call
 * site throughout cvm (there are hundreds, none of them NULL-checked --
 * that's the norm this codebase already runs on, see value.h's own
 * "everything leaks, nothing is freed" header comment) dereferences that
 * NULL immediately: an unchecked, undiagnosed segfault instead of the
 * same clean "cvm: out of memory" abort every OTHER resource-exhaustion
 * case here already gives (stack/frame/handler-table-full, GMP OOM via
 * main.c's own mp_set_memory_functions hooks, etc). Routes through the
 * existing cvm_abort machinery, so a script running under an installed
 * `guard` gets a genuinely catchable condition for this too, not just a
 * hard process exit -- the same distinction cvm_abort already makes for
 * every other error kind. */
void *cvm_gc_oom_handler(size_t bytes_requested);

#endif
