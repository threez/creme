# icecreme dead-ends — explored and rejected

Companion to `doc/optimization-icecreme.md` (which covers the optimizations that
landed). This file collects icecreme optimization ideas that were explored and
then **reverted or declined**, each with the measurement that ruled it out —
so nobody re-chases them. Short by design; the point is the verdict, not the
prose.

## Where icecreme stands vs Guile (why the interpreter tail is exhausted)

The cross-language bench puts icecreme within ~1.1× of Guile 3.0.11 overall, but
3–8× behind on tight CPU loops (nqueens, fib, tak). **Most of that gap is
Guile's JIT** (the Lightening template JIT), not its interpreter. Measured by
toggling only `GUILE_JIT_THRESHOLD` (startup/compile cancel out), Guile's JIT
is worth **tak 2.3×, fib 2.8×, nqueens 3.2×**. Back that out and icecreme's
*interpreter* is within ~1.4–2.6× of Guile's *interpreter* — the same order as
the wins already banked, not a structural chasm. The remaining 3–8× to
production Guile is bytecode dispatch vs native code, which a standalone C11
interpreter can't close without becoming a JIT (a different project). So the
interpreter-level tail is short, and the ideas below are why.

Recurring theme across the 0% results: on this workload set wall-clock is set
by the **dependency chain** and by **allocation/GC**, not by shaving
individual off-critical-path instructions — an out-of-order core overlaps
those away.

## Rejected ideas

- **`SelfTailCall` opcode that skips the `upvalue_get`.** The Section-7
  self-tail-call fast path still resolves the callee via `upvalue_get` to
  discover it's a self-call. A runtime-quickened icecreme-only `OP_SELFTAILCALL`
  prototype that skips it entirely measured **0%** (nqueens + suite): the
  `upvalue_get` is a few L1-hot dependent loads, never on the critical path;
  Section 7's win was the eliminated per-iteration frame reload, not the
  resolve. A real compiler-emitted version would need correctness-critical
  static analysis (binding identity vs same-named shadows, plus
  `set!`-immutability — a wrong proof silently calls the wrong function)
  across the shared bytecode format and both VMs, for ~nothing. **Reverted.**

- **Dead-Move peephole (copy propagation).** The one provably-dead
  instruction in the whole micro-bench suite is record-test's second
  `Move a=12 b=3` (re-staging `p` into an arg register that still holds it).
  Built it properly as a copy-propagation pass in the shared
  `BytecodeCompiler` (per-function copy map, gated on the function creating no
  closure, cleared at every control-flow join). It correctly removed the Move
  (loop 13→12 ops) and passed the whole native suite (2131 examples, 0 fail,
  incl. the differential native-vs-self-hosted comparison) on both backends —
  but **0%** wall-clock (0.290s → 0.290s): a store nothing reads is never on
  the dependency chain, and record-test is allocation-dominated besides. A
  copy-propagation pass with real join-clearing correctness surface in the
  shared compiler, for 0%, isn't worth carrying. **Reverted.**

- **Fused `RecRef`/`RecMake` record opcodes.** Give record accessors/
  constructors the same fused, read-operand-straight-from-a-register form
  `car`/`cdr` get via `Cxr`. The ceiling is real (a `cons`/`car`/`cdr`
  version of record-test runs **1.56×** faster), but: (1) icecreme's accessor
  *dispatch* is already fused-tight — `OP_QCALLGLOBAL_RECACC` reads
  `record->fields[field_index]` directly, no frame push; the op would only
  drop the compiler's arg-staging Move; (2) emitting it needs compile-time
  record-type tracking (`define-record-type` is a runtime `HelperForm`, so
  accessors don't exist until runtime) plus redefinition-safe deopt across
  both VMs — large and correctness-critical for one synthetic workload.
  **Declined.**

- **General arg-staging Move reduction.** Profiling made Moves look like a big
  recoverable cost (record ~33% of samples, tak ~20%), but the bytecode shows
  they're overwhelmingly irreducible: tak rotates `x`/`y`/`z` through the arg
  window (a parallel permutation no allocation can remove), and fib already
  emits computed args (`(- n 1)`) straight into the arg slot (zero Moves). The
  compiler already does the reducible part. **No action.**

- **`Value`-by-value passing into the numeric helpers.** Checked whether
  `num_add`/etc. (two 16-byte `Value`s by value) were still real hot-path
  calls after Section 3's inlining. Disassembly (checked against relocation
  entries) confirms every `fast_*` wrapper and the call/bind/return helpers
  are fully inlined — zero real calls left in the dispatch loop; the only
  `num_*` calls are the cold non-fixnum fallback. Switching to `const Value *`
  would touch only cold code. **No change.**

- **`creme_profiler_tick` cost when profiling is off.** Every call site guards
  it behind `vm->profiler.enabled`, so with profiling off (the default) it's
  one predictably-false branch, not a call. **No change.**

- **`GC_ENABLE_INCREMENTAL=1` (Boehm's incremental/generational mode).**
  Tested alongside `doc/optimization-icecreme.md`'s Section 8 GC-heap-sizing work,
  same 9-workload suite, median of 11 runs: **+26.4% slower** (0.201s → 0.254s
  vs. the libgc default; +27.1% with a 256M initial heap too, same
  regression). Expected going in: incremental mode buys shorter *pause*
  latency via a write barrier on every pointer store, which nothing this
  benchmark measures (it's pure batch throughput) — so the barrier is
  pain with no corresponding gain here. Confirmed by the per-workload
  breakdown: the regression is worst on the most mutation-heavy workload,
  `nqueens` (0.0089s → 0.0318s, a backtracking search that conses/mutates a
  position list every step), and smallest on non-allocating ones (`tak`,
  `fib`). **Not adopted** — the 256M `GC_INITIAL_HEAP_SIZE` default from
  Section 8 is the win from this line of investigation, not this.

---

For the optimizations that landed (and their measured wins), see
`doc/optimization-icecreme.md`.
