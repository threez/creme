# The performance journey — icecreme, the standalone C11 VM

`icecreme` is a second, independent implementation of this project's bytecode
format: a standalone C11 VM (`icecreme/vm.c`) with its own self-hosted
Scheme-to-bytecode compiler (`modules/creme/compiler/compiler.sld`),
distinct from the native Crystal compiler/VM under `src/creme/`. Having a
genuinely separate implementation of the same bytecode semantics is useful
in its own right — it's a real cross-check on the bytecode format and
compiler behavior, not just an alternate runtime — and its C-level hot
path has its own distinct set of costs worth optimizing on their own
terms.

This document covers optimization work specific to icecreme's own
implementation. Two sibling documents cover the rest of this project's
performance work:
- `doc/internals/optimization-crystal.md` — the native Crystal VM/interpreter only.
- `doc/internals/optimization-general.md` — techniques shared by (or ported across)
  both compilers/VM backends, including several new opcodes implemented
  in icecreme as part of that shared work (counted-loop fusion, its
  redefinition-safe extension to self-recursive global functions) — not
  duplicated here.

## Results so far

Each section below is one change, in the order it landed, with its own
measured effect. The load-bearing wins:

| # | Change | Effect |
|---|--------|--------|
| 1 | Shrink `Value` 24→16 bytes | **~35% suite**, fib 2.1× |
| 2 | Batch-allocate cons cells | list-build ~4–7% |
| 3 | Inline call machinery + int fast paths | deep-recursion & loops meaningfully faster |
| 4 | Call-site quickening for primitive calls | per-call-site win after first hit |
| 5 | Call-site quickening for record accessors | record-heavy code faster |
| 6 | Hot/cold-split `Instruction` 40→20 bytes | ~6% suite, ~2% nqueens |
| 7 | Self-recursive tail-call fast path | ~12% nqueens, ~7% suite |

For ideas explored and rejected — the measurements that ruled them out,
and where icecreme stands against Guile (its JIT, and why the interpreter-level
tail is exhausted) — see `doc/internals/deadend-icecreme.md`. Read it before starting new
work, so you don't chase a ceiling that isn't there.

---

## 1. Shrinking the tagged `Value` representation

icecreme represents every Scheme value as a single `Value` struct: a type tag
plus a payload. That struct was 24 bytes — a `T_STR`/`T_SYM`'s length and
a `T_BOX`'s kind lived inside the payload union itself, alongside a
pointer, which forced 16-byte alignment padding on the union as a whole.

Moving those two fields out of the union and onto a new top-level `aux`
field on `Value` itself shrank the union back down to a plain 8-byte
word: `sizeof(Value)` went from 24 to 16 bytes, and `sizeof(Pair)` (two
`Value`s) from 48 to 32.

This crossed a real x86-64 SysV ABI threshold: a struct passed by value
between functions is only passed in registers if it fits in 16 bytes or
less; above that, the ABI passes it in memory instead. Every value in
icecreme is passed by value constantly — through the dispatch loop, into every
arithmetic/comparison helper, through the call machinery — so call-heavy
code benefited the most from crossing back under that threshold. Measured
on the standard micro-benchmark suite: total time dropped **~35%**, and
`fib` specifically was **~2.1× faster**. An HTTP-server benchmark
exercising SQL, DAO macros, JSON, HTML templating, and concurrent request
routing confirmed the effect end-to-end too: **~11% more throughput**,
with no correctness regressions. This was a `icecreme/*.c`-only change; the
native Crystal VM and the self-hosted compiler running under it are
unaffected either way.

---

## 2. Batch-allocating cons cells

`creme_cons` called the Boehm GC's `GC_MALLOC` once per cons cell allocated.
Boehm's collector provides `GC_malloc_many` for exactly this shape of
workload: requesting many same-size, high-churn allocations at once,
returned as a single linked chunk, so a cons-heavy loop pays the
allocator's own per-call lock/size-class-lookup overhead once per chunk
instead of once per individual cell. Each cell handed out this way is
still a real, individually-collectible GC object from the moment it's
returned — not a manually recycled one — so there's no reuse-after-still-
referenced risk the way an application-level object pool would carry.

Profiling first, before changing anything, established exactly which
workloads this could plausibly help: comparing a run with the collector
disabled entirely against a normal run showed only genuinely cons-heavy
code (building a list by consing) had a real, reproducible
GC-attributable cost (~28% of its own runtime) — arithmetic-heavy,
vector-heavy, and string-heavy workloads were all within measurement
noise, since those allocate in bulk up front rather than one small object
per element. This change captures part of that ceiling (list-building
became **~4–7% faster**; a workload with much lower cons volume was
unaffected), and the HTTP-server benchmark saw a smaller but real
**~2–3% more throughput**. It doesn't capture the whole GC-attributable
ceiling identified during profiling — the cost of actually *collecting*
list cells that genuinely escape (they're the list being returned to the
caller) is unchanged; only the allocation-side overhead is addressed.

---

## 3. Inlining call machinery and arithmetic/comparison fast paths

Benchmarking icecreme against a reference Lua interpreter identified several
workloads where icecreme measurably trailed despite winning overall on the
full suite: deep non-tail recursion, a triply-recursive integer
benchmark, a tight vector-sum loop with no function calls at all, and a
backtracking search — a mix of call-heavy and pure-arithmetic-loop
shapes.

Two distinct fixes, from two distinct root causes:

- **Call machinery wasn't being inlined into the dispatch loop.** The
  functions handling call dispatch, argument binding, and return delivery
  were genuine out-of-line C function calls from inside the VM's hot
  dispatch loop, on every single Scheme call. Marking them `static
  inline` with a forced-inline attribute gave a real, repeatable **~6–7%**
  improvement on the triply-recursive benchmark, confirmed via several
  rounds of isolated, repeated timing showing tightly clustered,
  non-overlapping before/after results.

  A follow-up hypothesis — that the *order* the call-dispatch function
  checked callable kinds in mattered, since an ordinary closure call is
  overwhelmingly the most common case but was checked last — was tested
  first by simple reordering and measured no difference at all: branch
  prediction already handled that check order fine on a hot, repetitive
  call site. The real cost turned out to be structural, not
  positional: every callable-kind check was an independent `if`, not an
  `else if` chain, so a closure call still evaluated every other check on
  its way to the one that actually matched, regardless of which check
  came first textually — reordering which independent `if` appears
  first doesn't reduce how many of them a matching call still runs
  through. Restructuring the two common cases (an ordinary closure, and
  a native builtin) to check first *and* return immediately — genuinely
  skipping the rarer cases (case-lambda dispatch, record-callables,
  continuations, parameters) rather than merely being checked before
  them — gave a real, repeatable **~2–5%** further improvement across
  the same call-heavy workloads, confirmed the same way.

- **The integer fast path inside the numeric helper functions wasn't
  being inlined either.** Each arithmetic/comparison helper (add,
  subtract, multiply, and the ordering/equality comparisons) has a
  same-tag-integer fast path that's only two instructions long, but the
  *whole* function — including its float/rational/complex fallback
  paths — is too large for the compiler to inline automatically at every
  arithmetic instruction's call site in the dispatch loop, confirmed by
  disassembling the compiled dispatch loop and finding real call
  instructions to these helpers on every arithmetic/comparison op, even
  for two plain machine integers. The native Crystal VM already avoids
  exactly this by inlining its own integer fast path directly into its
  dispatch loop (see `doc/internals/optimization-crystal.md`, Section 6); icecreme's C
  VM had never received the equivalent treatment. Small `static inline`
  wrapper functions were added, each checking for the same-integer-tag
  case and falling through to the real helper function — with identical
  error messages and identical float/rational/complex behavior — the
  instant either operand isn't a plain integer, used in every
  arithmetic, comparison, and counted-loop opcode.

  A separate experiment — building with a more aggressive compiler
  optimization level as the project default, specifically to see whether
  it would find and apply this same class of inlining automatically — was
  tried and measured **worse**: a consistent ~3–4% *regression* on the
  triply-recursive benchmark, and a wash on the full benchmark suite's
  total. Larger generated code from more aggressive inlining and loop
  unrolling elsewhere in the file hurt instruction-cache locality for the
  dispatch loop's own hot cycle by more than it gained anywhere else —
  the same reason several other bytecode-interpreter dispatch loops in
  the wild are deliberately built at a lower optimization level. The
  project's default build configuration was left as it was.

Net effect, measured across the full micro-benchmark suite: the
non-tail-recursive integer benchmark and the vector-sum loop (which has
no function calls at all, making it the clearest signal that the
arithmetic fast-path fix — not the call-machinery fix — was what mattered
there) both improved meaningfully, and a tail-recursive accumulation
loop went from being slower than the reference Lua interpreter to faster
than it. Across the whole suite, icecreme's total time relative to that same
reference interpreter improved from being narrowly ahead to being clearly
ahead.

---

## 4. Call-site quickening for primitive calls

icecreme's self-hosted bootstrap compiler (`modules/creme/compiler/
compiler.sld`) fuses `+`/`-`/`*`/`car`/`cdr`/`cons` (and others) into
dedicated single-purpose opcodes at compile time — but only when it can
*statically* prove the call site is safe to fuse. That proof is
all-or-nothing per compilation unit: the moment the compiler sees any
`(define ...)`/`(set! ...)` of one of these names anywhere earlier in
the same file (`mark-redefined!`, tracked in
`redefined-fusable-globals`), it permanently disables fusion for that
name for the rest of that file — even if the redefinition is later
undone, or guarded behind a branch that never actually runs. Every call
to that primitive from that point on compiles as an ordinary
`OP_CALLGLOBAL` to a real n-ary builtin function (`builtins.c`'s
`bi_plus`/`bi_minus`/`bi_star`/`bi_car`/`bi_cdr`/`bi_cons`), paying full
call-dispatch overhead on every single call, forever, regardless of
what the global actually holds at runtime.

This is exactly the shape of problem an inline cache solves, applied to
a call site instead of a property/field access: cache what showed up,
guard it, specialize the common case, deopt on mismatch. `OP_CALLGLOBAL`
now quickens itself the first time its target resolves to one of these
builtins with a matching argument count — rewriting the instruction in
place (self-modifying bytecode, kept safe under icecreme's actor model, where
the same `Chunk`'s instructions can be shared and executed concurrently
across pthreads — see `icecreme/actor.c` — via a single relaxed atomic store:
every racing writer independently computes the identical target opcode
for a given instruction, so the only thing an ordinary write could get
wrong is a torn value, which the atomic store rules out for free) to one
of six new `OP_QCALLGLOBAL_*` opcodes (`icecreme/opcodes.h`, appended after
`OP_COUNT` — runtime-only, never part of the on-disk format, so they can
never collide with a real op id). Each quickened opcode re-checks the
global's *current* value against the exact expected builtin function
pointer on every single execution (no name/hashtable lookup — a direct
pointer-identity comparison against the same statically-known C function
address `bi_plus` etc. already resolve to) and permanently deopts back
to a plain `OP_CALLGLOBAL` — falling back to the exact same generic call
this same instruction visit, not just the next one — the instant that
check fails, i.e. a genuine redefinition.

Verified correct end-to-end, not just fast: a call site that starts
generic, quickens, gets legitimately redefined to a different closure at
runtime (must deopt and reflect the new definition), and is then
restored to the original builtin (must re-quicken) was exercised
directly and produced the right answer at every step. The full
`spec/creme` suite (851 examples) still passes with no new failures.

**Measured effect**, isolated to the case this actually targets (code
that redefines one of these names anywhere in the same file, then
either restores it or never executes the redefinition — the compiler
still can't tell that in advance, so it de-fuses the whole file's calls
to that name regardless): a microbenchmark exercising `+`/`-`/`*`/
`cons`/`car`/`cdr` in hot loops, each name redefined-then-restored
first to force every call through `OP_CALLGLOBAL` instead of the
compiler's own fused ops, dropped from **~0.34s to ~0.245s** — **~28%
faster** (~1.4×), consistently across repeated runs. Ordinary code that
never redefines these names was already hitting the compiler's static
fusion path and sees no change from this at all — that's expected and
correct: quickening only ever activates on the specific call sites the
static compiler had to give up on, not on ones it already handled.

---

## 5. Call-site quickening for record accessors

The same technique from Section 4, applied to `define-record-type`
field accessors. Top-level `define-record-type` (the shape real
programs use — see Section 4's own doc for why the internal,
non-top-level desugaring is a separate, narrower legacy path not
targeted here) compiles a field accessor's global binding to a
`RecordCallable` of kind `RC_ACCESSOR` (`icecreme/value.h`), built by
`build_record_bindings` (`icecreme/vm.c`). A call like `(point-x p)`
therefore always compiles to a plain `OP_CALLGLOBAL` against a
`T_RECORD_CALLABLE` — never a fused op of its own, since accessors
aren't part of the compiler's static fusion list at all — so it paid
full generic `dispatch_call` overhead (tag-check chain, frame
bookkeeping, `call_record_callable`'s kind switch) on every single
call, forever, structurally the same shape of problem as `car`/`cdr`
before Section 4, and slightly heavier.

`quicken_callglobal_op` now recognizes this case too: a `T_BUILTIN`
target quickens as before, but a `T_RECORD_CALLABLE` target with kind
`RC_ACCESSOR` and a matching 1-argument call site now rewrites the
call to a new `OP_QCALLGLOBAL_RECACC` opcode (`icecreme/opcodes.h`,
appended after the six existing `OP_QCALLGLOBAL_*` ops, same
runtime-only/never-serialized treatment). Each execution re-checks the
global's *current* value is still a `T_RECORD_CALLABLE` of kind
`RC_ACCESSOR`, that the argument is actually a `T_RECORD`, and that its
`RecordType*` matches the accessor's own type by pointer identity
(exactly the same check `call_record_callable`'s `RC_ACCESSOR` case
always made) before reading `fields[field_index]` directly — and
deopts permanently back to a plain `OP_CALLGLOBAL` the instant any of
that fails (a redefinition of the accessor's name, or a call on the
wrong record type, which then raises through the generic path exactly
as it always did).

Verified correct end-to-end: a call site that starts generic,
quickens, is redefined to a different procedure at runtime (deopts,
returns the shadowed value), and is then restored to the original
accessor (re-quickens, computes correctly again) was exercised
directly, and calling the accessor on a value of the wrong record type
still raises whether or not that call site has already quickened. See
`spec/creme/record_accessor_quicken_spec.scm` for the automated
version of these same cases — the full `spec/creme` suite (892
examples as of this writing) still passes with no new failures.

**Measured effect**: `competition/bench/record-accessor-quicken.scm`
(a standalone microbenchmark, deliberately not part of
`competition/bench.scm`'s cross-language suite — this is an icecreme-only
runtime behavior, nothing to compare across languages) sums both
fields of a two-field record through their accessors 20 million times
in a tight loop. Built and run before and after this change (same
compiled `.ice`, only `icecreme/icecreme` itself rebuilt in between): steady-
state time dropped from **~0.56s–0.60s to ~0.44s** — roughly **~22%
faster** (~1.3×), consistent with Section 4's own measured effect for
the builtin case. Ordinary record-field-access code that never
redefines an accessor sees the exact same accessors it always called,
just faster after the first call at each site quickens — there's no
static-fusion counterpart here for it to already be hitting instead
(unlike the builtin case in Section 4).

---

## 6. Hot/cold-splitting the instruction stream

The `Instruction` struct the dispatch loop fetches once per executed
opcode (`ins = &frame->chunk->instrs[frame->ip++]`) was 40 bytes: five
`int`s for the actual instruction (`op`/`a`/`b`/`c`/`d`, 20 bytes) plus a
per-instruction source position (`has_pos`/`file`/`line`/`col`, another 20
bytes). That position data is read in exactly one place — `--profile`'s
report, symbolizing a sampled `(chunk, ip)` as `file:line` — and never by
the dispatch loop itself. So half of every instruction fetched, millions
of times over, was dead weight in the D-cache on the common (non-profiled)
path.

Splitting it is the same hot/cold reasoning as Section 1's `Value` shrink,
applied to the other structure the dispatch loop touches constantly: move
the four position fields into a parallel `InsPos` array on `Chunk` (same
index space as `instrs`, populated by the loader alongside it), leaving the
hot `Instruction` at a flat 20 bytes with nothing in it the loop doesn't
read. The profiler pays one extra indexed load (`chunk->positions[ip]`) it
doesn't care about the latency of; the dispatch loop gets a 2×-denser
instruction stream. Touches only `vm.h` (the two structs), `loader.c`
(populate the parallel array), and `profiler.c` (read from it) — the
dispatch loop is unchanged, and behavior is identical (the `--profile`
report symbolizes exactly as before).

The measured win is real but modest, and — usefully — its size tracks
code footprint exactly as the cache-density explanation predicts:

- **nqueens(12)** (the workload that motivated this — see the profile
  showing its `safe?` helper as ~90% of samples, spread flat across ~13
  tiny opcodes): **~1–2% faster**, only just above a measured ~0.6%
  run-to-run noise floor. `safe?`'s whole loop body is ~260 bytes at 20
  B/instruction (was ~520), and *both* fit comfortably in L1 — so its
  bytecode was already L1-resident every iteration regardless, and halving
  a structure that already hits in L1 barely moves fetch latency. A single
  tight loop is close to the best case for the *old* layout, so the worst
  case for this change.
- **The full 9-function micro-benchmark suite** (fib/sum-to/build-list/
  vector-sum/hashtable/record/string-build/tak/nqueens compiled into one
  chunk — a larger, more varied instruction footprint that no longer
  stays entirely L1-resident): **~6% faster**, cleanly above noise.

So this isn't the ~35% Section 1 saw — a single L1-resident loop is
exactly where instruction-stream density matters least — but it's a clean,
zero-risk change that also halves the memory footprint of every loaded
chunk, and it pays off more the larger and more varied a program's code
gets (the whole-program HTTP-server chunk, the self-hosted compiler's own
chunk). Verified against the full icecreme spec suite and the `examples/*.scm`
sweep with no behavior change; the `--profile` report is byte-identical
before and after.

---

## 7. A self-tail-call fast path

Profiling `nqueens` — the workload where icecreme trails the other bytecode VMs
(Guile, Racket) by the widest margin — put ~90% of its time in one helper,
`safe?`, a tight self-recursive loop that walks a growing list checking for
conflicts. `safe?` is a nested `define`, so its self-recursion compiles to
`TailCallUpval`: every iteration resolves the callee through an upvalue,
then runs the full generic call machinery (`dispatch_call`) to reuse the
frame.

But a tail call to *the currently-executing closure* is a special case
where almost everything `dispatch_call` computes is already known.
`frame->chunk`/`closure`/`base` are all unchanged (a tail call reuses the
same register window), and that window was already stack-cap-validated when
the frame was first set up — so the callee tag-check chain, the redundant
cap check, and the chunk/closure/base rewrites are pure overhead. All that
genuinely still has to happen is closing any upvalues this frame opened
(their backing registers are about to be overwritten by the new args),
rebinding the args in place (the same forward-shifting copy `bind_args`
already does for every tail call), and jumping back to `ip = 0`.

`try_self_tail_call` (vm.c) does exactly that, guarded by `callee.tag ==
T_CLOSURE && callee.as.closure == frame->closure`; the three tail-call
handlers (`OP_TAILCALL`/`OP_TAILCALLLOCAL`/`OP_TAILCALLUPVAL`) try it first
and fall through to the generic `dispatch_call` on any non-self call, so
everything else is untouched. This is entirely icecreme-side — no bytecode or
compiler change, and no new opcode — mirroring how the existing quickening
work (Sections 4–5) specializes a hot site without touching the format.

Measured (min of interleaved runs, same compiled chunk):

- **nqueens(12): ~12% faster.** Notably larger than the ~5% the
  instruction-sample profile alone would suggest `TailCallUpval` was worth
  — because the win isn't just the skipped machinery. The generic path
  forces the dispatch loop to reload `frame = &vm->frames[vm->depth-1]`
  and `base = frame->base` after every call (the callee *might* have
  changed the current frame); the self path provably doesn't, so those
  dependent loads — and the return-check branch — drop out of the loop's
  critical path every iteration. Sample-position profiling can't see that
  pipeline cost, only wall-clock A/B can.
- **The full 9-function suite: ~7% faster** (fib and tak are self-
  recursive too; every `named let`/loop lowers to a self-call).

This narrows but does not close the Guile gap on `nqueens` (~9.8× → ~8.7×):
most of that workload's time is the actual per-element list-walking
(`car`/`cdr`/compare), not call overhead. This runtime fast path captures
the whole achievable win at zero format risk: going further — a compiler-
emitted `OP_SELFTAILCALL` that skips even the `upvalue_get` — was
prototyped and measured at **0%** (the `upvalue_get` was never on the
critical path), so it's a documented dead end, see `doc/internals/deadend-icecreme.md`.

Correctness is the gate here, since this is the single hottest VM path: the
full icecreme spec suite runs unchanged (same pre-existing failures, zero new),
and targeted edge cases confirm the subtle parts — closures capturing a
loop variable each iteration still capture *distinct* values (upvalues
close correctly before the registers are reused), deep tail recursion
still doesn't grow the frame stack, and mutual (non-self) recursion still
takes the generic path.

## 8. A larger default initial GC heap

Every allocation in icecreme goes through Boehm's `GC_MALLOC` (see
`doc/internals/improvement-areas.md`'s "Boehm conservative GC" note and `hashtable.c`/
`creme_ffi.c` for the only two exceptions, neither of which is an ordinary
Scheme heap object — freeing ordinary GC objects by hand was considered and
rejected, since Boehm's conservative stack/register scanning gives no way to
*prove* an object is unreachable from every C frame, only to infer it after
the fact). Given that, the next lever isn't touching individual allocations
but the collector's own startup sizing: libgc grows its heap in increments as
a program allocates past what it currently holds, and each of those
heap-growth events is itself a stop-the-world pause. A short-lived, small
program pays for several of these over its lifetime for no reason other than
starting from libgc's own conservative default.

Tested via the `GC_INITIAL_HEAP_SIZE` env var (read directly by `GC_INIT()`
itself, no code change needed to try it), median of 11 runs each of
`competition/scheme/bench/creme.scm`'s 9-workload suite through `icecreme/icecreme`
directly (not the full `bench.scm` harness, which would also rerun 8 other
language runtimes per rep):

| config | median total | vs. libgc default |
|---|---|---|
| unset (libgc's own default) | 0.201s | — |
| `GC_INITIAL_HEAP_SIZE=64M` | 0.186s | −7.5% |
| `GC_INITIAL_HEAP_SIZE=256M` | 0.163s | **−18.7%** |
| `GC_INITIAL_HEAP_SIZE=1G` | 0.163s | −18.7% (no further win past 256M) |

Per-workload, the win concentrates exactly where allocation is heaviest —
`hashtable-test` 0.095s → 0.079s, `record-test` 0.054s → 0.036s, `build-list`
0.012s → 0.007s — while non-allocating workloads (`tak`, `fib`,
`vector-sum-test`) barely move, confirming the mechanism is fewer
heap-growth pauses, not some unrelated effect.

`main.c` now calls `GC_expand_hp` to 256M right after `GC_INIT()`, but only
when the caller hasn't set `GC_INITIAL_HEAP_SIZE` themselves — an explicit
env var still wins, this is a default, not an override. `GC_expand_hp` only
grows libgc's address-space reservation, not memory committed up front, so
this costs nothing even for icecreme's long-running-server use (`mux-listen!`'s
`app.scm`, see `main.c`'s own header comment) — pages are still faulted in
lazily as the heap is actually used.

**`GC_ENABLE_INCREMENTAL=1`, tested at the same time, is a dead end** — see
`doc/internals/deadend-icecreme.md`.
