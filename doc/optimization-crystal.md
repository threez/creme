# The performance journey — native Crystal VM/interpreter

How `scheme.cr` (the `creme` interpreter) got fast. This is a narrative of the
performance work on the **native Crystal** evaluation core — the
`Interpreter`/`VM`/`BytecodeCompiler` classes under `src/scheme/` — **what we
did, why, and where we ended up** — including the experiments we measured and
deliberately threw away.

This file covers only the native Crystal side. Two sibling documents cover
the rest of this project's performance work:
- `doc/optimization-general.md` — techniques shared by (or ported across)
  both the native compiler and the self-hosted Scheme-to-bytecode compiler,
  and portable library-level optimizations that benefit every backend
  equally.
- `doc/optimization-cvm.md` — `cvm`, the standalone C11 VM and its own
  compiler, which has a genuinely different implementation and its own
  distinct set of hot paths.

It covers only the performance thread. The parallel architectural work (the
R7RS library system, the annotation-driven builtin registration, the
one-file-per-library layout) is out of scope here.

---

## 1. Overview: what we were optimizing

The interpreter has a single evaluation path:

```
source → Lexer → Reader → analyze (→ Node AST) → BytecodeCompiler (→ Chunk)
       → VM#run (register bytecode dispatch loop)
```

There is no tree-walking evaluator anymore — it was deleted once the bytecode VM
became the sole path. Every optimization below is about making that
analyze → compile → execute pipeline, and especially the VM's dispatch loop,
faster.

The bar we held ourselves to: **beat the old tree-walker on every workload**,
measured, not assumed. The bytecode VM did not start out ahead — its first
working slice was actually *slower* than the tree-walker it replaced. Most of
the wins below are the story of closing that gap and then pulling clearly ahead.

---

## 2. How we measured (the discipline that shaped every decision)

Every change in this document was accepted or rejected on measurement, not
intuition. The methodology matters as much as the results:

- **The workloads.** `competition/bench/workloads.scm` defines seven micro-benchmarks, each
  chosen to stress a different hot path, run via `competition/scheme/bench/creme.scm`:
  - `fib` — deep non-tail recursion + integer arithmetic
  - `sum-to` — tail-recursive accumulation (trampoline / TCO)
  - `build-list` — allocation + list traversal
  - `vector-sum` — mutable array access
  - `string-build` — growable-buffer writes
  - `tak` — the Gabriel Takeuchi benchmark: triply-nested non-tail recursion
  - `nqueens` — backtracking search: recursion + list allocation + `car`/`cdr`
    traversal together
- **Back-to-back A/B.** The only reliable comparison is: stash the change,
  rebuild, measure the baseline, restore the change, rebuild, measure — both
  within the same short window. Comparing a measurement taken now against one
  taken earlier is worthless: the machine's thermal/background state drifts by
  several percent between rounds. We learned this the hard way — one change
  looked like a **−5.5%** win when compared across rounds, and turned out to be
  exactly **0%** under back-to-back measurement (the machine had simply gotten
  faster between the two readings). Every "win" below is a back-to-back result,
  usually min + median + mean over 25–30 runs.
- **Control benchmarks.** To attribute a cost to one operation, we ran the same
  loop with that operation swapped for a trivial one. For example, to isolate a
  record accessor's cost we compared a loop doing `(+ acc (point-x p))` against
  the identical loop doing `(+ acc 1)` — the difference is the accessor, with
  loop overhead cancelled out.
- **The rule.** Commit only a *clear* winner. A change that is neutral or a
  regression under back-to-back measurement is reverted, no matter how good the
  theory was. Several plausible ideas died this way (Section 8).

---

## 3. Foundational VM design

These are the structural decisions the bytecode VM is built on. They exist partly
for correctness (the explicit stack is what makes `call/cc`/`guard` possible) and
partly for speed.

- **Register bytecode, not a stack machine or tree-walker.** The compiler emits
  Lua-style register instructions into a `Chunk`. The VM (`src/scheme/eval/vm.cr`)
  runs a fetch-decode-dispatch loop over an explicit `CallFrame` stack rather
  than recursing in Crystal. The explicit stack is required for the unwinding
  features (`call/cc`, `dynamic-wind`, `guard`, `parameterize`) to unwind to an
  arbitrary saved depth; it is also simply less overhead per operation than
  re-walking an AST.

- **One shared register array.** Registers for every frame live in a single
  growable `@stack`; a `CallFrame` is just a `base` offset into it. A non-tail
  call opens a new window immediately above the caller's (`base +
  caller.num_registers`, a compile-time high-water mark); a **tail call reuses
  the current frame's exact window**, so a self-tail-recursive loop never grows
  the stack — genuinely O(1) space per iteration.

- **Pooled call frames.** `CallFrame` objects are pooled by depth in `@frames`
  with a `@depth` cursor. A call at a depth some earlier (since-returned) call
  already used reuses that same object (overwriting its fields) instead of
  allocating. Recursion depth — not call count — bounds how many frame objects a
  whole run ever needs (≈27 for `fib(27)`, not one per its ~630,000 calls).

**The honest arc.** The first VM slice ran *slower* than the tree-walker. The two
fixes that flipped it: (1) the fused primitive ops were still going through the
generic `apply` path (arity check, args-array allocation, call-stack push/pop,
a `Proc` call) instead of calling the same direct helpers the old tree-walker
used — routing them through the direct helpers closed most of the gap; and
(2) each call allocated a fresh register array and a fresh frame object — the
shared-stack and frame-pooling designs above removed both. Only after those did
the VM lead on every workload.

---

## 4. Value representation: fixnums are already unboxed

A dynamic language usually pays its biggest tax on boxing small integers — every
arithmetic result becoming a fresh heap object. This interpreter avoids that tax
by construction, and it is worth stating clearly because it removes a whole class
of "optimization" that would otherwise be tempting.

`SchemeInt` is a **value-type `struct`**, not a class, inside the
`SchemeValue` union (`src/scheme/value/values.cr`, `src/scheme/value/alias.cr`).
Crystal represents a `struct | class` union as a tagged value — a type tag plus
an inline payload — so:

- `sizeof(SchemeValue)` is **16 bytes**: an 8-byte type tag + an 8-byte payload.
- A `SchemeInt` lives **inline** in that payload (the raw `Int64`), not as a heap
  pointer — `SchemeInt.is_a?(Reference)` is `false`.
- `@stack` is an `Array(SchemeValue)`, so a register holds the integer inline.
  `SchemeInt.new(x.value + y.value)` is a register write, **not a heap
  allocation**.

We proved this rather than assuming it: a **5,000,000-iteration integer loop
allocates ≈27 KB total** (about 0.006 bytes per iteration — that residual is
one-time recompilation, not the arithmetic). Boxed integers would have cost on
the order of 80–160 MB for the same loop. So fixnum arithmetic is allocation-free
today, and "add fixnum unboxing" is already done.

`SchemeChar` was later converted to the same value-type `struct` representation
(Section 10) for the identical reason: chars are immutable and `eq?`/`eqv?`
already compare them by value, not identity, so nothing depends on a char being
heap-allocated, and a 4-byte char fits comfortably inside the existing 8-byte
union payload without growing `SchemeValue` at all. (The only representational
lever left — NaN-boxing the union down to 8 bytes — is discussed and set aside
in Section 8.)

---

## 5. Superinstruction fusion — the recurring theme

The single most productive technique was **superinstruction fusion**: profile the
VM to find the largest bucket of dispatched instructions, notice that many of
them exist only to *stage an operand* for the next instruction, and fuse the two
into one op that reads the operand directly. Each pass below was driven by an
actual profile (via the built-in VM-instruction sampler in `(creme prof)`), not a
guess, and targeted whatever the current hottest staging instruction was.

The opcode families live in `src/scheme/compile/opcode.cr`; each has a detailed
doc comment there.

- **Immediate operands** — `AddImm`/`SubImm`/`MulImm`/`NumLtImm`/… A call like
  `(- n 1)` or `(< n 2)` used to load the literal `1`/`2` into a register with a
  `LoadK` first. These ops bake a small integer literal directly into the
  instruction's operand (when it fits `Int32`), skipping the register + `LoadK`.
  Only literal-in-second-position is supported — that is the only shape the hot
  benchmarks use, and order matters for the non-commutative ops.

- **Closed-over operands** — `AddUp`/`SubUp`/…/`VecRefUp`/`VecSetUp`/… A named-let
  loop closing over `n` (a bound) or `v` (a vector) used to `GetUpval` each
  loop-invariant into a register before the op. These ops read the second (or
  object) operand straight from an upvalue. `vector-sum`'s profile showed
  `GetUpval` at ~28% of all dispatched instructions before this pass.

- **Compare-and-branch** — `TestLt`/`TestLe`/`TestGt`/`TestGe`/`TestEq`
  (+ `Imm`/`Up` variants). An `if`/`when` whose test is a comparison used to
  materialize the boolean into a register (`NumLt`) and then immediately test and
  discard it (`TestFalse`). These ops compare and branch in one step, never
  materializing the boolean — the test's value is only ever needed for
  truthiness. This is exactly what Lua's bytecode does (its `OP_LT`/`OP_LE`/
  `OP_EQ` are conditional-skip instructions) and what CPython 3.11+ does when it
  fuses `COMPARE_OP` with `POP_JUMP_IF_FALSE`.

- **Fused callee load** — `CallGlobal`/`CallLocal`/`CallUpval` and their tail
  variants. A call to a bare-name callee (`(fib …)`, a local, a named-let loop
  variable) used to stage the callee into a register (`GetGlobal`/`Move`/
  `GetUpval`) and then have `Call` read it back. These ops carry *where to fetch
  the callee* in an operand, eliminating that staging instruction. The global
  variant reuses the per-instruction inline cache (Section 7), so redefinition
  safety is unchanged.

- **Fused return** — `ReturnGlobal`/`ReturnUpval`, and `AddReturn`/`SubReturn`/…
  A bare-name value in tail position used to write itself into a (about-to-be-
  discarded) register and then have `Return` read it back out; and
  `(+ (fib …) (fib …))` in tail position used to `Add` into a register, then
  `Return` it. These ops deliver the return value directly. `fib`'s "return"
  bucket was ~20% of dispatched instructions before this.

- **The `cxr` accessor family as one prim** — `Op::Cxr`. `null?`/`pair?`/`cons`
  were already prims, but `car`/`cdr` (and `caar`/`cadr`/…/`cddddr`) compiled to a
  generic `CallGlobal`, so every `(car xs)` first staged `xs` into an argument
  register with a `Move` and then paid full call dispatch. `nqueens`' `safe?`
  inner loop is almost entirely `(car positions)`/`(cdr positions)`, and its
  profile showed those `call` rows plus their `local-ref positions` (Move) rows
  dominating. Rather than one opcode per accessor, a **single `Op::Cxr` encodes
  the whole car/cdr chain as a bitmap** in its operand (1=car, 0=cdr, applied
  LSB-first under a sentinel top bit — see `cxr_code`/`cxr_label`). Recognition
  keys on the **resolved builtin's name**, not the call's head symbol: any call
  whose head resolves to a cxr-named `Builtin` fuses, and the chain comes from
  that builtin's name. This covers the whole family — `car`/`cdr`, the 2-level
  `caar`/`cadr`/`cdar`/`cddr` (promoted from prelude closures to real
  `(scheme base)` builtins), and the 3-/4-level `caaar`…`cddddr` — **and it makes
  aliasing free**: because a plain `(define first car)` binds `first` to the `car`
  builtin, `(first x)` fuses exactly like `(car x)` with no dedicated alias table
  (this is how `first`/`second`/`third`/`rest` are now defined, replacing their
  old wrapper closures). The VM walks the chain reading each pair straight from a
  register (and, because a fused prim with a leaf local argument elides its
  staging `Move` via `local_register_of?`, drops that Move too). The family was
  historically excluded from prims because a non-pair must raise `car: expected
  pair` *with its own backtrace frame* (a fused op pushes none) — resolved by
  fast-pathing only the all-pairs case inline and **deopting to the real builtin
  on the first non-pair** (via `@interp.apply`, which pushes the frame and
  re-walks to raise at the same step), so the error message/frame/position stay
  byte-identical (guarded by `spec/scheme/eval/backtrace_spec.cr`). Measured:
  **`nqueens` ~0.050s → ~0.030s (about −40%)** back-to-back, with every other
  workload flat; and a fused `cadr` now edges out an explicit `(car (cdr x))`
  (one 2-step `Cxr` vs two ops), where the old prelude-closure `cadr` paid a full
  call per access. Same append-only-arm and redefinition-safety rules as the
  other prims (a shadowed/redefined accessor deopts at analyze time to a normal
  call).

- **`abs` and the sign predicates as unary numeric prims** — `Op::Abs` and
  `Op::CmpZero`. `nqueens`' `safe?` still showed `(abs …)` as the one remaining
  generic `call` in its loop; and `zero?`/`positive?`/`negative?` were prelude
  closures (literally `(= n 0)` etc.), paying a closure call each. `Op::Abs`
  fast-paths a non-`INT64_MIN` integer inline; `Op::CmpZero` (operand `c` selects
  `zero?`/`positive?`/`negative?`) fast-paths int and float. Both deopt to the
  real builtin for the rest (float/rational/overflow/error), same
  frame-preserving pattern as `Cxr` (they share `unary_prim_deopt`). The sign
  predicates were also promoted from prelude closures to real builtins (via the
  same `num_chain` the `=`/`>`/`<` builtins use, so tower semantics are identical)
  so the fusion has a `Builtin` to key on and to back first-class/deopt use.
  Measured: **`nqueens` ~0.030s → ~0.024s** (a further ~20%; ~53% under the
  original tree-through-`CallGlobal` baseline), and `zero?`/`positive?`/`abs`
  loops each **~2× faster** (~1.5s → ~0.8s on 20M iterations), every other
  workload flat.

- **`eq?` as a 2-arg predicate prim, full `NumEq`-style family** —
  `Op::IsEq`/`IsEqImm`/`IsEqUp`/`TestIsEq`/`TestIsEqImm`/`TestIsEqUp`/
  `IsEqReturn`. Unlike `null?`/`pair?` (already prims), `eq?` wasn't in
  `PRIM_OPS` at all — every use paid full dynamic-call overhead (arg-array
  alloc, builtin dispatch). Profiling `competition/scheme/demo-todo/
  app.scm` under load surfaced `(eq? (caar alist) key)` — `(creme sxql)`'s
  alist-lookup loop — as a real hot spot. `eq?`/`eqv?` are literally the
  same implementation in this codebase (`Scheme.scheme_eqv?`), and unlike
  the numeric comparisons it fuses alongside, `eq?` never raises and needs
  no numeric-tower/overflow fallback — so the fused op is just a direct
  call to that helper (or, for the `*Imm` shapes, an even simpler check:
  `imm_operand?` only ever bakes an integer literal, and `scheme_eqv?`
  says a non-int is never `eqv?` an int, so no `SchemeInt` allocation is
  needed there either). Named `IsEq` throughout (not `Eq`) to stay clear of
  `Op::TestEq`, which already exists for `=` (numeric equality) — an
  unrelated predicate that happens to share an English name with `eq?`.
  Measured with a standalone 5-entry-alist `eq?`-walk microbenchmark (3M
  iterations, isolating exactly the hot shape the profile found — see
  `spec/scheme/compile/prim_call_spec.cr`'s "eq? fusion" spec for the same
  shapes as correctness tests): **~35s → ~1.04s (about 34×)**; re-profiling
  `competition/bench.scm --profile` afterward shows the `call (eq? (caar
  alist) key)`/its `local-ref key` argument-staging row gone entirely from
  the "hot Scheme functions" table, replaced by a single `eq?` row. Same
  append-only-arm and redefinition-safety rules as every other prim (a
  shadowed/redefined `eq?` deopts at analyze time to a normal call) — and,
  per this section's own append-only invariant below, `TestIsEq`/
  `TestIsEqImm`/`TestIsEqUp` are appended at the true end of the dispatch
  loop's `case` (after `Op::CmpZero`), not inserted next to `TestEq`/
  `TestEqImm`/`TestEqUp` despite being conceptually part of that family —
  inserting there would've pushed every later arm (including `Call`/
  `Return`, among the hottest ops in the VM) back by one comparison.

- **Folding `not` in test position** — not a new op, a codegen rewrite in
  `compile_if`/`compile_when`. `(if (not X) a b)` ≡ `(if X b a)` exactly (both
  only consult the test's truthiness), so `peel_not` strips leading `not`
  wrappers from an if/when test and inverts the branch sense (each `not` toggles
  it; for `when`/`unless` it flips the negate flag). This drops the `not`
  instruction entirely, and — crucially — lets the now-unwrapped inner
  comparison fuse into a single compare-and-branch. `tak`'s inner test is
  `(not (< y x))`, which the profile showed as three separate hot instructions
  (`<` materializing a boolean, `not` inverting it, `if` testing it — together
  ~43% of samples); it now compiles to one `TestLt` with swapped targets.
  Only genuine `PrimOp::Not` nodes peel, so a shadowed/redefined `not` is
  untouched, and double negation cancels (`(not (not X))` → `X`). Measured
  back-to-back (same session): **`tak` 0.00355s → 0.00278s (~22%)**, other
  workloads unaffected (codegen is byte-identical for a test with no leading
  `not`).

- **Relaxing the prim Move-elision gate to a per-argument suffix.** A bare local
  argument to a fused prim (`(+ acc (vector-ref v i))`, `(= (car positions)
  col)`) could alias its own register directly, instead of being staged through
  a `Move`, only when *every* argument to that call was a side-effect-free leaf
  (`all_leaves`) — so the common `(op (compound…) local)` shape (nqueens'
  `safe?` does `(= (car positions) col)`) still forced a redundant `Move` of the
  trailing bare local. The actual correctness requirement is narrower: an
  operand can alias its register as long as no argument evaluated *after* it
  can mutate that local before the op runs — i.e. its own index is past the
  last non-leaf argument, not that the whole call is leaves-only. `safe?` drops
  from 23 to 20 instructions (9 to 8 registers); **`nqueens` ~5% faster**, no
  change to workloads without this mixed leaf/non-leaf argument shape.

- **Treating pure prim-call subtrees as side-effect-free in `leaf_node?`.**
  `leaf_node?` (used by the Move-elision gate above, and by the `*Up` fusions'
  own leaf-argument gates) only recognized bare locals/literals as safe to
  alias — a `PrimCallNode` argument like `(* i 2)` in `(vector-set! v i (* i
  2))`, or `(vector-ref v i)` in `(+ acc (vector-ref v i))`, was always treated
  as potentially unsafe, blocking both the `*Up` fusion (the vector, closed
  over by a named-let loop, couldn't fuse into `VecSetUp`/read straight from
  its upvalue) and the aliasing above. A prim call is genuinely side-effect-free
  exactly when every one of its own arguments is (it only ever writes its own
  destination register, plus — for `vector-set!` etc. — a heap object, never a
  caller-visible local's register), so `leaf_node?` now recurses into
  `PrimCallNode` args. `vector-sum-test`'s fill loop drops from 10 to 7
  instructions (6 to 4 registers), its sum loop from 7 to 6. A nested
  `set!`/call inside a prim argument still keeps the whole prim non-leaf,
  preserving the required left-to-right evaluation snapshot.

- **`case` hash dispatch — `Op::CaseDispatch`.** Modeled directly on YARV's
  `opt_case_dispatch` (Ruby's own bytecode compiles `case` to a hash-table
  jump instead of a clause chain): the previous lowering emitted one
  `Op::CaseMatch` + `Op::TestFalse` pair per clause (`compile_case_clauses`),
  so a `case` with N clauses cost up to O(N) clause probes, each itself
  scanning that clause's own datum vector by `eqv?`. When every clause's
  datums are a cheaply/safely hashable literal type — `SchemeInt`, `SchemeChar`,
  `SchemeSym`, `SchemeBool`, `SchemeNil` (excluding `SchemeFloat`'s bit-pattern
  `eqv?`, `SchemeRational`, and anything falling to the generic
  `Reference#same?` identity fallback — all legal but vanishingly rare as case
  datums), any `else` is absent or last (an `else` earlier in the list would
  short-circuit later clauses under the old clause-order semantics, which a
  hash table can't reproduce), and there are at least
  `CASE_DISPATCH_MIN_DATUMS` (8) datums total (below that a linear scan is
  already fast enough that building a `Hash` isn't worth it), `compile_case`
  instead emits one `Op::CaseDispatch` against a `CaseDispatchTable` built at
  compile time — an allocation-free `CaseDispatchKey` record normalizes the
  runtime key, and the table maps it straight to the matching clause's
  absolute instruction offset (or a default, for `else`/no-match), so
  `frame.ip` is set directly rather than walking a chain of relative jumps.
  Any `case` outside that shape (small clause count, a non-hashable datum, a
  misplaced `else`, a malformed clause) falls back to the exact original
  linear codegen, unchanged. Measured on a standalone worst-case microbenchmark
  (24 single-datum clauses, 3,000,000 iterations always matching the *last*
  clause — the case a linear scan pays most for): **~1.03s → ~0.24s (about
  4.3×)**; ordinary small `case` forms (below the datum threshold) are
  byte-for-byte the same codegen as before, so unaffected.

**An invariant this exposed.** Crystal compiles a `case`/`when` over an enum to a
*sequential comparison chain*, not a jump table. So inserting a new dispatch arm
in the middle of the loop's `case` pushes every later arm's comparisons back and
measurably slows them. New arms are therefore **appended at the end**, never
inserted mid-chain. This is a live constraint for anyone editing the dispatch
loop — an `AddReturn`-style op regressed `sum-to` ~5% purely from arm placement
until it was moved to the end.

---

## 6. Micro-overhead removal in the hot loop

With the fusion passes done, the remaining wins were about shaving fixed overhead
off each dispatched instruction.

- **Bounds-check-free register access.** The register allocator plus
  `ensure_stack_size` already guarantee every `base + reg` index is in range
  before it is touched, so Crystal's array bounds check on register access was
  pure overhead on the single hottest operation in the interpreter. The main
  dispatch loop moved to `@stack.unsafe_fetch`/`unsafe_put`. The arithmetic
  helper `exec_prim` then did the same by binding its register variable to the
  raw buffer pointer (`@stack.to_unsafe`), whose `[]`/`[]=` are unchecked —
  a one-line change that made every arithmetic register access in that method
  bounds-check-free, safe because nothing `exec_prim` calls ever grows `@stack`.

- **Bounds-check-free instruction fetch, then dropping the guard that made it
  provable.** The fetch/decode step (`instructions.unsafe_fetch(frame.ip)`) and
  `top_frame`'s `@frames.unsafe_fetch(@depth - 1)`, run once per dispatched
  instruction, were converted the same way as register access above — each is
  provably in range (the fetch is dominated by a `frame.ip >=
  instructions.size` guard with nothing mutating `frame.ip` in between; `@depth`
  is always ≥ 1 for an executing VM), but LLVM can't prove either across the
  intervening heap loads on its own. Measured (min-of-8, release): **`fib(30)`
  ~7%, `tak(24,16,8)` ~8.5%, `build-list` ~4.5% faster**. This established that
  Crystal lowers a dense enum `case` to a real jump table at `--release`
  (confirmed via an isolated micro-benchmark), so — unlike the interpreter's
  own dispatch loop, which is hand-written as a sequential chain (see this
  section's invariant above) — dispatch-*arm order* inside a single `case` is
  not itself a lever once compiled.

  That still left a genuine per-instruction guard: `frame.ip >=
  instructions.size`, checked every iteration purely to catch a chunk running
  off its end without an explicit `Return`. Rather than paying that branch
  forever, the compiler now guarantees the condition can never hold:
  `BytecodeCompiler#append_return_sentinel` appends a `LoadNil`+`Return` to
  every compiled chunk, so (a) the last instruction is always a `Return` — no
  sequential fall-off is reachable — and (b) the instruction array has a valid
  index one past every possible `patch_jump_to_here` target, so no jump can
  land out of range either. With both fetch and guard removed, dispatch just
  starts at the fetch. Measured (min-of-8, release): **`sum-to` ~10%, `fib`
  ~6% faster; `nqueens` ~1% slower** (a code-layout artifact of the extra
  sentinel instructions). Full suite (including every `examples/*.scm`) stayed
  green, which is itself evidence the no-jump-past-end invariant holds across
  every tested program shape — a malformed chunk lacking the sentinel would
  now read out of bounds instead of raising, so keeping that invariant is the
  compiler's responsibility, not something the VM checks anymore.

- **Extending bounds-check-free access to every other compiler-controlled
  index.** Once the pattern above was established, the same argument applies
  to any array read indexed by an operand the compiler itself produced for
  that exact chunk/closure — not just registers and the instruction stream.
  Converted: `chunk.consts[instr.b]` in `LoadK` (a literal load, on the same
  hot path as register access) and `chunk.global_cache_values`/
  `global_cache_versions[instr_idx]` in `get_global_cached` (read on every
  `GetGlobal`/`CallGlobal`/`TailCallGlobal`/`ReturnGlobal` dispatch — i.e.
  every recursive call to a global function). Both are provably in range for
  the same reason `top_frame` is: the index either came from that chunk's own
  `add_const`, or (for the cache arrays) `Chunk#emit` keeps them 1:1-sized with
  `instructions`. Also converted, for consistency rather than measured gain:
  every `closure_of(frame).upvalues[idx]` read (folded into one `upvalue(frame,
  idx)` helper, replacing ~26 call sites — `GetUpval`/`SetUpval`, the `*Up`
  fusions, vector/string/bytevector-`Up` ops, call-family callee reads), plus
  the remaining `chunk.protos`/`chunk.qq_templates`/`chunk.case_dispatch_tables`
  accesses (`Closure`, `Quasiquote`, `CaseDispatch`) and the prim-op deopt
  path's builtin lookup. **Only the `LoadK`/`get_global_cached` conversions
  showed up in back-to-back measurement** (bundled with the two fetch/guard
  changes above: ~11% combined on `competition/scheme/bench/creme.scm`'s full suite); the upvalue/
  proto/qq-template/case-table sites are colder paths (they fire once per
  construct, not once per hot-loop register op) and produced **no measurable
  change** — kept anyway since they're the same provably-safe pattern and
  remove real (if cold) bounds checks, not a reverted experiment. The same
  consolidation was applied a second time later (Section 10), converting the
  handful of remaining chunk-table reads that had crept back in as unchecked
  `Array#[]?`/`Array#[]` accesses instead of the `unsafe_*` helpers.

- **Inlining the hottest prims into the dispatch loop.** The base + immediate
  integer arithmetic ops (`Add`/`Sub`/`Mul` and their `Imm` variants) and the
  tail-position `AddReturn`/`SubReturn`/`MulReturn` were reaching a wide combined
  `when` arm that called `exec_prim`, which then re-dispatched on the opcode in
  *its own* `case` and paid a method-call frame — a double dispatch on the single
  hottest class of op. These are now inlined directly as their own arms in the
  main loop, byte-for-byte matching `exec_prim`'s integer fast path and its
  `@interp.num_*` overflow/tower fallback. The rarer/heavier prim shapes
  (comparisons, all upvalue-operand variants, vector/string/bytevector access,
  `cons`/predicates) stay in `exec_prim`.

  **Invariant:** the integer arithmetic fast path now lives in *two* places — the
  inlined dispatch-loop arms and `exec_prim` — that must be kept in sync. An edit
  to arithmetic semantics has to touch both.

These two, together with the earlier work, are why `fib` and `vector-sum` are
among the fastest paths.

---

## 7. Inline caching

Two applications of the inline-caching idea from the literature (the classic
Deutsch–Schiffman / polymorphic-inline-cache lineage), each avoiding a repeated
lookup on a hot path:

- **Global reference cache.** A hot recursive call like `(fib (- n 1))`
  references the global `fib` on every invocation. `get_global_cached`
  (`src/scheme/eval/vm.cr`) caches each `GetGlobal`/`CallGlobal`/`ReturnGlobal`
  site's resolved value, keyed on the global environment's version counter. While
  nothing has redefined that name at top level, the cache hit skips the
  environment hash lookup entirely; a `define`/`set!` bumps the version and
  invalidates the cache, so redefinition stays correct. The cache is stored as
  two parallel arrays on the `Chunk` (kept 1:1 with the instruction stream), so a
  hit is a plain array index, not a hash probe.

- **Shape-guarded record accessors.** Record field accessors and mutators from
  `define-record-type` were plain `Builtin`s, so `(point-x r)` compiled to a call
  that went through the generic path: a per-call one-element args-array
  allocation (millions of short-lived heap objects in a hot loop → GC pressure)
  plus the full `apply` machinery, then a type check inside the builtin. We made
  them dedicated `Builtin` subtypes — `RecordAccessor` and `RecordMutator`
  (`src/scheme/eval/record.cr`) — that carry their target record type and field
  index *statically*, and gave `dispatch_call` a fast path that does the type
  guard and a direct field load/store inline, skipping the array allocation and
  `apply` entirely. This is the shape-guarded-accessor idea, except the "shape"
  (the record type) and the slot (the field index) ride on the accessor value
  itself, so no per-call-site cache machinery is needed. They remain first-class
  `Builtin`s (their fallback closure still works for `map`/`apply`), and an
  arity/type mismatch falls through to the generic path with identical
  error messages.

  Measured on a 10-million-call accessor loop: **0.75s → 0.50s** total, i.e. the
  per-accessor cost dropped from ~45ns to ~19ns (about −57%), with no effect on
  `bench.scm` (which uses no records).

---

## 8. Explored and rejected

Recorded so they are not re-attempted without new information. Each was
implemented or prototyped and then dropped on measurement.

- **Jump-table dispatch / arm reordering.** Restructuring the loop's `case` to
  force a real switch/jump table, and reordering arms by measured opcode
  frequency, both failed to produce a clean win — the jump-table version
  regressed `fib`/`sum-to` (indirect-branch misprediction outweighed the chain of
  well-predicted direct branches it replaced), and frequency reordering helped one
  workload while regressing another. The sequential-comparison-chain dispatch,
  with new arms appended, is what we kept.

- **Hoisting `begin/rescue` off the hot loop.** The dispatch loop wraps each
  iteration in a `begin/rescue` (needed so `guard` can catch, jump, and resume).
  We tried moving the rescue up into a thin wrapper and running a rescue-free
  inner dispatch method, on the theory that the exception scaffolding was
  pessimizing the hot loop. Result: a **consistent ~1% regression** across two
  back-to-back rounds. LLVM's exception handling is already zero-cost on the
  no-throw path, so moving the region only added a method boundary. Reverted.

- **Shrinking `Instruction` to 16 bytes.** Packing the opcode (`Int16`) and the
  first operand (`Int16`) into one 4-byte word, keeping the other three operands
  `Int32`, shrank the instruction struct from 20 to 16 bytes (−20% bytecode
  memory), safely (the first operand is always a small register/index). It was
  **throughput-neutral** on `bench.scm` — the hot loops' bytecode already fits in
  L1, so packing it denser changes nothing for them. It was a real, risk-free
  memory reduction but not a speed win; kept briefly and then reverted to keep
  the operand types uniform.

- **8-bit opcode.** With ~100 opcodes defined, the opcode fits in a byte. But
  making it 8-bit did **not** shrink the instruction at all (the saved byte is
  eaten by alignment padding before the next operand), gave no throughput change,
  and cut the enum's headroom close to overflow. No reason to do it.

- **A `case-lambda` clause-selection cache.** Caching the resolved clause per
  call site sounded like a win. A control benchmark showed clause selection costs
  **~2ns per call** — statistically indistinguishable from a plain closure call.
  Not worth any complexity.

- **Fixnum unboxing.** Already in place — see Section 4; there is nothing to
  unbox. The only remaining representational lever is NaN-boxing / pointer-tagging
  to shrink the value union from 16 bytes to 8. That is a large, invasive rewrite
  (replacing Crystal's type-safe union with a manual tagged encoding across
  hundreds of call sites, giving up compile-time type safety), and by the
  instruction-size precedent above its payoff on these hot loops is likely
  neutral. Set aside pending evidence that memory bandwidth, not compute, is the
  bottleneck.

- **Batching call-argument register reservation in the self-hosted compiler.**
  The same batched-reservation change described in Section 10 for the native
  compiler was attempted in the self-hosted compiler too, and reverted after
  surfacing a genuine, not-yet-root-caused regression under `cvm` (the general
  call-argument-compilation path silently failing to compile a call's arguments
  correctly in one narrow reentrant-compile scenario). Left unchanged pending
  further investigation — see `doc/optimization-general.md`.

- **`GC_ENABLE_INCREMENTAL=1` (Boehm's incremental/generational mode).**
  Tested alongside Section 11's GC-heap-sizing work, same 9-workload
  `competition/scheme/bench/creme.scm` suite, median of 11 runs: **+17.3%
  slower** (0.342s → 0.401s vs. the libgc default). Same root cause as
  `cvm`'s identical result (`doc/deadend-cvm.md`): incremental mode's write
  barrier trades throughput for pause *latency*, which this batch-throughput
  benchmark never measures. Per-workload, the regression again concentrates
  on the most allocation/mutation-heavy workloads (`record-test` 0.087s →
  0.112s, `build-list` 0.026s → 0.037s, `hashtable-test` 0.155s → 0.184s).
  **Not adopted.**

---

## 11. A larger default initial GC heap

Same experiment as `cvm/main.c`'s (see `doc/optimization-cvm.md`'s own
Section 8) — Crystal links the identical Boehm/bdwgc collector, read via the
stdlib's `crystal/gc/boehm.cr`, so the same lever applies: libgc grows its
heap in increments as the program allocates past what it currently holds,
and each growth is a stop-the-world pause a short program pays for several
times over its lifetime for no reason other than starting from libgc's own
conservative default.

Tested via the `GC_INITIAL_HEAP_SIZE` env var (read directly inside libgc's
own init, before `main` ever runs — no code change needed to try it), median
of 11 runs each of the same 9-workload suite, `bin/creme` run directly (not
the full `bench.scm` harness, which would also rerun 8 other language
runtimes per rep):

| config | median total | vs. libgc default |
|---|---|---|
| unset (libgc's own default) | 0.342s | — |
| `GC_INITIAL_HEAP_SIZE=64M` | 0.325s | −4.9% |
| `GC_INITIAL_HEAP_SIZE=256M` | 0.265s | **−22.6%** |
| `GC_INITIAL_HEAP_SIZE=1G` | 0.266s | −22.2% (no further win past 256M) |

Per-workload, same signature as `cvm`: `hashtable-test` 0.155s → 0.110s,
`record-test` 0.087s → 0.063s, `build-list` 0.026s → 0.019s, while
non-allocating workloads (`tak`, `fib`, `vector-sum-test`) barely move.

`src/main.cr`'s `main` now calls `LibGC.expand_hp` (a stdlib `LibGC` binding
the two functions needed here, `GC_expand_hp`/`GC_get_heap_size`, which
`crystal/gc/boehm.cr` doesn't already expose) to 256M as its first
statement, but only when `GC_INITIAL_HEAP_SIZE` isn't already set in the
environment — an explicit env var still wins, this is a default, not an
override. By the time `main` runs, Crystal's own runtime prelude has already
called `GC.init` (honoring that same env var if set), so this mirrors
exactly where `cvm/main.c` places its own equivalent call, right after
`GC_INIT()`. Same as there, `GC_expand_hp` only grows libgc's
address-space reservation, not memory committed up front, so this costs
nothing for a long-running `bin/creme` server process either.

**`GC_ENABLE_INCREMENTAL=1`, tested at the same time, is a dead end** — see
Section 8's rejected-ideas list above.

## 9. Where we end up (as of the initial write-up)

- The register bytecode VM beats the old tree-walker on every workload.
- Integer arithmetic is allocation-free; the arithmetic and vector hot loops
  (`fib`, `sum-to`, `vector-sum`) are the fastest paths, thanks to the fusion
  ops, the inlined arithmetic arms, and bounds-check-free register access.
- Global references and record field access both skip their repeated lookups via
  inline caching.

**Design invariants a future editor must respect:**

- **Dispatch arms are append-only.** Adding a `when` arm mid-chain in the VM's
  dispatch `case` slows every later arm — append new ops at the end.
- **The integer arithmetic fast path lives in two places** (the inlined
  dispatch-loop arms and `exec_prim`) that must stay in sync.
- **Every `unsafe_fetch`/`unsafe_put` in the VM relies on the index being
  compiler-controlled.** Register access is correct because the register
  allocator plus `ensure_stack_size` guarantee `base + reg` is in range;
  `chunk.consts`/`protos`/`qq_templates`/`case_dispatch_tables` and
  `closure.upvalues` reads are correct because the index came from that exact
  chunk's/closure's own `add_const`/`add_proto`/.../upvalue-resolution call;
  the instruction fetch and cache-array reads are correct because
  `Chunk#append_return_sentinel` guarantees every chunk ends in a `Return` and
  `Chunk#emit` keeps the cache arrays 1:1 with `instructions`. Don't introduce
  an access via any of these `unsafe_*` calls whose index isn't provably tied
  to one of these invariants — a chunk assembled by hand (not through
  `BytecodeCompiler`) rather than by the compiler would need to reestablish
  all of them itself.
- **No jump/patch may target past the end of a chunk's own instruction
  array.** `patch_jump_to_here` relies on this, and the end-of-chunk `Return`
  sentinel relies on it too (see Section 6) — a hand-assembled or corrupted
  chunk that broke this would read out of bounds rather than raising, now that
  the VM no longer checks per instruction.
- **Upvalues must be closed on frame reuse.** Because register slots and frame
  objects are reused across calls, any upvalue capturing a still-live register
  must be closed (copied out) the instant its frame exits, or a later call
  reusing that slot corrupts the captured value.

Further large gains from here would require a categorically different technique —
a threaded/computed-goto or JIT dispatch (not directly expressible in Crystal
today), or the value-representation rewrite in Section 8 — rather than more of the
incremental fusion/overhead-shaving that got us here. The incremental seam is
largely mined out; the remaining ideas are big, risky, and unproven on these
workloads. Section 10 below is exactly that: further incremental work found once
the seam above was thought mined out, by profiling different workloads
(callback-heavy code, backtrace construction, concurrent HTTP request handling)
than the original seven micro-benchmarks stressed.

---

## 10. Later work: callback dispatch, backtraces, and request concurrency

This section covers native-Crystal-only optimization work done after the
initial performance pass above. It's additive to Sections 3–9, not a
revision of them — the invariants stated in Section 9 still hold.

- **Pooling `VM` instances across `Interpreter#apply`'s callback bridge.**
  `apply` allocated a fresh `VM` — a 256-slot register array plus three more
  arrays — for every `BytecodeClosure`/`BytecodeCaseClosure` call routed
  through it: `map`/`for-each`/`fold`/`sort` callbacks, the mux
  request-handler dispatch, `dynamic-wind`, any builtin calling back into
  Scheme. Those `VM` objects need per-call *isolation*, not per-call
  *lifetime*. An `ObjectPool(T)` (a reusable-object pool with a warm
  minimum, unbounded growth, and slow decline — it sheds a fraction of the
  surplus that stayed idle across a decay interval, never below the
  minimum) now backs `apply`: it borrows a `VM` from the interpreter's pool
  and returns it in an `ensure`, and `VM#reset_for_reuse` restores a clean
  state cheaply (O(1) — `@stack` and the frame pool keep their capacity;
  contents are overwritten before they're read, never cleared up front).
  Safe with respect to escape continuations, since they only ever capture
  an `Int64` tag, never VM state. Measured on `for-each` over 200,000
  elements: **309ms → 25ms (about 12×)**, landing within ~1.3× of an
  inline-call loop (the residual is the `apply` bridge itself, addressed
  next). Inline-call workloads (`fib`/`tak`/`nqueens`/…) were unaffected.

- **Reusing one args array per call when a `map`/`for-each` callback is a
  closure.** `map`/`for-each` allocated a fresh `Array(SchemeValue)` for
  every element to pass into `apply`. For a closure callback that array is
  pure transport — `apply` copies it into VM registers
  (`bind_args_from_array`) before the body runs and never retains it, so
  one array can be refilled across every iteration instead. A `Builtin`
  callback might retain the array (e.g. `values` building a
  `SchemeValues`), so those keep a fresh array per call, unchanged. This
  closed the residual overhead left after VM pooling above: `for-each`
  over 200,000 elements went **25ms → 21.5ms**, reaching parity with an
  inline-call loop (21.7ms) — a closure callback through `apply` now costs
  the same as a direct call.

- **Pooling per-request child `Interpreter`s in `(creme mux)`.** The HTTP
  server allocated a fresh child `Interpreter` per incoming request instead
  of reusing one across requests. `Interpreter#acquire_child_interpreter`/
  `release_child_interpreter`/`reset_for_reuse` pool them the same way `VM`
  instances are pooled above. Measured **~25–32% higher requests/second**
  on the JSON demo endpoint under load.

- **Caching dispatch-loop frame state across iterations.** `execute`
  re-derived `frame`/`base`/`instructions` from `top_frame` at the start of
  *every* instruction, even though only a call, tail call, return, or guard
  unwind can actually change which frame is on top. These are now cached
  across iterations and only refreshed right after those specific ops.
  Measured **~5% faster on `competition/scheme/bench/creme.scm`** (mean of 8 runs). In the same
  pass, `dispatch_call`'s read of the call site's backtrace position
  (`frame.chunk.positions[frame.ip - 1]?`) — an ordinary bounds-checked,
  `Nilable`-wrapping `Array#[]?`, unlike the rest of this hot path — was
  converted to the same bounds-check-free access already established
  elsewhere, since `positions` is kept 1:1-sized with `instructions` by
  `Chunk#emit`, the same invariant `global_cache_values`/
  `global_cache_versions` already rely on. Measured **~6% faster** via a
  standalone `sum-to(100,000,000)` microbenchmark (min-of-6, comparing
  built binaries directly).

- **Immediate-index vector/string/bytevector `ref`/`set`.** Fuses a
  compile-time-literal index directly into `VecRef`/`StrRef`/`BvRef`/
  `VecSet`/`StrSet`/`BvSet` as new `*Imm` opcodes, skipping both the
  `LoadK` that would otherwise stage the index into its own register and
  the runtime index-coercion check, since the index is already a verified
  `Int32` at compile time. Applies to any fixed-position access (`(vector-ref
  v 3)`), not just generated code, though a query-compiling `#lang` dialect
  whose every field access resolves to a literal index is the heaviest
  beneficiary. In the same pass: zero-upvalue nested lambda literals are
  now memoized per enclosing closure instance, so a `(lambda () ...)`
  re-evaluated every iteration of a loop no longer reallocates; and
  `SchemeHashTable` gained a real hash-backed O(1)-average bucket lookup
  instead of a linear scan (a `GROUP BY`/`JOIN`-style workload over a large
  CSV had made the old O(n) scan dominate wall time).

- **Synthesizing backtrace frames lazily instead of pushing one on every
  call.** `dispatch_bytecode_call` used to push a real `Interpreter::Frame`
  onto `@call_stack` on every ordinary Scheme-to-Scheme call — tail or
  not — purely to support error backtraces, a rare event, paid on every
  call of every recursive function. `@call_stack` is only ever read when a
  `SchemeError` is actually constructed, so it's no longer maintained
  eagerly on this path: each pooled `CallFrame` now records its own
  `call_pos`, and `Interpreter#call_stack_snapshot` reconstructs backtrace
  entries lazily from the currently active VM's own frame pool, only when
  an error is actually raised. Builtin calls and the builtin-to-closure
  bridge in `apply` are unaffected. Measured **~14% faster on `fib(32)`**;
  bytecode output is unaffected (this is purely a VM runtime change), and
  the full backtrace-position/frame test suite passes unchanged, confirming
  the lazily-reconstructed backtraces are identical to the eagerly-pushed
  ones they replaced.

- **Batching call-argument register reservation at compile time.** Adds
  `FunctionCompiler#alloc_regs(n)`, reserving `n` contiguous registers in
  one bump instead of `n` separate `alloc_reg` calls, used in both
  call-compilation branches to replace `node.args.map { fc.alloc_reg }`
  (and the intermediate array it built) with direct arithmetic on the
  first reserved register. This is a **pure compile-time bookkeeping
  change** — `alloc_reg` never emits an instruction, it only decides which
  register number a later instruction's operand will reference — so it
  changes nothing about emitted bytecode, register numbering, or runtime
  behavior, only how the compiler computes those numbers internally.
  Confirmed via `competition/bench.scm` before/after: totals land in the same
  range either way, and the benchmark's own computed results are
  byte-identical; only the timing line differs. Worth doing anyway for the
  reduced compile-time allocation and clearer intent, not for a runtime
  win. The equivalent change attempted in the self-hosted compiler was
  reverted after surfacing an unrelated regression (Section 8).
