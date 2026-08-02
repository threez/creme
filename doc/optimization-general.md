# The performance journey — shared across both backends

This project has two independent implementations of the same bytecode
format: the native Crystal compiler/VM (`src/scheme/`) and `cvm`, a
standalone C11 VM with its own self-hosted Scheme-to-bytecode compiler
(`modules/creme/compiler/compiler.sld`, `cvm/`). This document covers
optimization work that is genuinely cross-cutting — a technique designed,
or later ported, to apply to both compilers and/or both VM backends — and
portable library-level optimizations that benefit every backend equally
because they're plain Scheme.

Two sibling documents cover backend-specific work:
- `doc/optimization-crystal.md` — the native Crystal VM/interpreter only.
- `doc/optimization-cvm.md` — the standalone C11 VM and its own compiler
  only.

---

## 1. Import-gating native builtin registration

Native builtins (the Crystal-/C-implemented procedures backing every
`(creme <family>)`/`(scheme base)` library) were registered
unconditionally in both runtimes, regardless of what a program actually
imported — every program paid the setup cost of every native family that
exists, whether or not it ever used one.

Both runtimes now gate registration on what's actually imported:
- **cvm**: `builtins.c`'s single monolithic registration function was
  split into one function per library family. The compiled bytecode
  format (SCB1) gained a "required families" metadata section, and
  `cvm/main.c` only calls the registration functions for families a given
  program's compiled chunk actually needs. The self-hosted compiler
  tracks and emits the same metadata when it compiles a program on the
  fly, so a raw `.scm` file run directly through `cvm/cvm` benefits too,
  not just an ahead-of-time `.cvmc`.
- **Crystal**: native libraries are now lazily constructed on first
  import instead of eagerly at interpreter startup, except `(scheme
  base)`/`(scheme write)`, which stay eager since nearly every program
  imports them anyway. The `--emit-cvm` chunk emitter collects the
  transitive set of builtin families a program's compiled bytecode
  actually reaches and serializes that same required-families metadata
  into the `.cvmc`, so a native-compiled-then-cvm-run program carries the
  same information cvm's own compiler produces directly.

Startup cost now scales with what a program imports, not with how many
native builtin families this project happens to ship.

---

## 2. Counted-loop fusion: `ForPrep`/`ForLoop`

A `let`-loop or `do` loop with a simple counted shape — one variable
stepped by a compile-time-constant integer, tested against a
loop-invariant bound — used to desugar into a real closure, called via
`TailCall` every iteration. `TailCall` was already O(1)-space (frame and
register-window reuse, no stack growth — see
`doc/optimization-crystal.md`'s Section 3), but it still paid
per-iteration argument re-binding and callee-dispatch overhead that a
plain counted loop doesn't need, the same way Lua's bytecode compiles a
numeric `for` loop to a dedicated `FORPREP`/`FORLOOP` instruction pair
(pure register increment + backward jump) instead of a closure call.

`Op::ForPrep`/`Op::ForLoop` (inclusive-of-limit semantics, matching Lua's
own `FORLOOP` convention) were added to the shared opcode set, along with
a compiler-side recognizer that pattern-matches this "simple counted
loop" shape: one constant-step counter, a loop-invariant bound, no
lambda literals anywhere in the body, and the loop's own name referenced
nowhere but its one tail self-call. Every condition is a hard
requirement — the moment any of them fails, the recognizer falls back to
the existing closure-based path unchanged, so this is a strict subset of
loop shapes that gets the fast path, not a best-effort heuristic. All
counted-loop sites in the standard micro-benchmark suite compile to
`ForPrep`/`ForLoop` instead of a nested closure; total benchmark time
dropped noticeably for both the native Crystal VM and cvm.

This landed first in the native compiler and both VM backends together
(the new opcodes needed real implementations in both `src/scheme/eval/
vm.cr` and `cvm/vm.c` to be usable at all, regardless of which compiler
emits them). The self-hosted compiler is a genuinely separate
implementation — it compiles from raw s-expressions, with no typed AST
the way the native compiler's `Node` hierarchy provides — so porting the
recognizer to it was a second, later step: reproducing the same
recognized-shape and safety conditions operating directly on s-expression
lists instead of typed nodes. Confirmed to produce output identical to
the native compiler's across the large-loop, cross-referencing-
accumulator, mutually-referencing-accumulator, no-accumulator, `do`-loop,
and lambda-escape-safety-fallback cases.

A further refinement — skipping the temporary register and `Move` for a
counted-loop accumulator variable nothing downstream ever reads again —
was applied to the native compiler's own lowering of this same shape.

---

## 3. Self-hosted compiler parity: fused tail-position variable reads

The native compiler's tail-position variable-read codegen (`(f n)`'s
final `n`, or a global/upvalue in tail position) returns straight from a
local's own register, or via `ReturnUpval`/`ReturnGlobal`, skipping a
register write entirely. The self-hosted compiler always emitted
`Move`/`GetUpval`/`GetGlobal` followed by a separate `Return` instead,
and never emitted `ReturnUpval`/`ReturnGlobal` at all — a real
extra-instruction cost on every tail-position variable reference (for
example, a recursive function's own base-case return), not a cosmetic
difference. Fixed to mirror the native compiler's codegen exactly.

---

## 4. Counted-loop fusion for self-recursive global functions

The counted-loop fusion in Section 2 only ever fired from a `let`-loop or
`do`, never from a plain self-recursive `(define (f params...) body)` —
so a function like a tail-recursive accumulating loop written as an
ordinary top-level definition stayed on the closure-call path even though
it has the exact same recognizable shape.

Extending the fusion to a global self-recursion is unsafe without extra
care: a `let`-loop's own name is always a local binding that nothing
outside the loop can reach, but a top-level `define`'s name is a mutable
global — a naive register-only loop would stop honoring a mid-loop
`(set! f ...)` or re-`define` of the function it's supposedly still
executing. Two new opcodes make this safe: `ForLoopGuardedInc`/
`ForLoopGuardedDec` (the step is now implicit in which of the two opcodes
is used, freeing the operand that would otherwise hold a general step
value to instead hold a reference to the global being recursed into) and
`TestGlobalIdentity`. Every iteration re-checks, by pointer identity, that
the global is still bound to the exact closure that's currently
executing, and deopts — falls through to a real, unfused recompilation of
the original `if` — the instant it isn't. No new per-call state is
needed to make this work.

Implemented in both VM backends and both compilers, sharing a
refactored-out shape-recognizer with the existing `let`-loop/`do` fusion
in the native compiler. Porting this to the self-hosted compiler exposed
an unrelated, pre-existing bug there: it always named a closure `"lambda"`
instead of the name it was being `define`d under, so a self-recursive
call could never be recognized by name at all — fixed as a prerequisite,
since without it the new recognizer could never find a match to fuse in
the self-hosted compiler.

Measured on a large tail-recursive accumulation: roughly **2.3× faster**
under the native VM and **3× faster** under cvm. Verified against the
disabled-optimization baseline specifically for the mid-loop-redefinition
case, confirming the deopt path produces identical results to the
unfused baseline when a self-recursive function redefines itself (or is
`set!` to something else entirely) partway through a long-running loop.

---

## 5. Portable library-level optimizations

These aren't compiler or VM changes — they're changes to plain,
portable `.sld` Scheme library code (plus, in one case, a thin native
driver layer). They benefit both the native interpreter and cvm equally,
since the same library source runs unmodified under either.

- **Rendering a DAO's static queries once instead of per call.** A DAO's
  read/delete-by-id queries have a fixed SQL shape, but every call was
  rebuilding the query-builder's internal representation and re-walking
  it from scratch to render SQL — repeated on every request in an HTTP
  demo application's GET path, since listing rows and counting them both
  build the same `SELECT`. The query-defining macro now renders each
  static query's SQL string once, at macro-expansion time, binding it to
  a per-table constant; the generated accessor methods run that cached
  SQL string directly instead of re-rendering it. Only queries whose SQL
  shape genuinely varies per call (an `INSERT`/`UPDATE` whose column set
  depends on the values passed) stay on the per-call rendering path.
  Measured **~34% more HTML requests/second and ~16% more JSON
  requests/second** on the demo application; the query-builder's own row-
  conversion function dropped out of the interpreter's hot-path profile
  entirely.

- **Sharing per-query column-name/keyword keys across result rows.**
  Converting a query result set to Scheme values was rebuilding
  per-column metadata for every row, even though a result set's column
  names are identical across all of its rows: the driver allocated a
  fresh string for each column name on every row, and the query builder
  then rebuilt a keyword symbol per cell (via string concatenation plus
  re-interning) on every row too. Both now build their column-name/
  keyword keys once per query, from the first row, and reuse those same
  key objects across every subsequent row instead of rebuilding them.
  Measured **~5–6% faster** converting a large (20,000-row) result set;
  modest because the remaining per-cell cost — the row's own list
  construction plus each value's own conversion — is inherent to the row
  shape, not something this change touches.

- **Caching a per-column keyword-symbol reconstruction.** A DAO field
  accessor was rebuilding a fresh keyword symbol from its underlying
  column name on every single field read, for a fixed, small set of
  column names that never change per table. Caches the derived keyword
  per column in a hash table instead of re-deriving it every time, and
  switches the corresponding alist lookup to use identity comparison
  instead of a general equality comparison, since the row's own keys are
  always already-interned symbols. Measured honestly: this made no
  measurable difference to end-to-end request throughput on the
  application it was profiled against, because that application's
  bottleneck turned out to be socket I/O, not the Scheme-level compute
  this change targets. Kept anyway, since it's a genuine reduction in
  per-call work independent of any one benchmark's particular bottleneck.

- **Rewriting a hand-rolled per-character escape loop as one native
  substitution pass.** A JSON string-escaping routine walked its input
  one character at a time in Scheme, allocating a fresh single-character
  string for every character and building the escaped result via
  `reverse`+`append`. Profiling an isolated JSON-rendering microbenchmark
  (SQL fetch + row access + JSON serialization, no HTTP/networking
  involved) showed this loop dominating both the VM's own instruction-level
  profile and, via the GC pressure all those single-character allocations
  created, the bulk of native sample time too. Rewritten to build its
  substitution table once, statically, and perform the escape as a single
  native find-and-replace pass over the whole string instead of a
  Scheme-level character loop — the same fix an HTML-escaping routine
  elsewhere in this codebase had already received for the identical
  reason. Measured via a calibrated fixed-time-window iteration count:
  roughly **2.7× more iterations** completed in the same window after the
  rewrite.
