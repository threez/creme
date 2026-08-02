# Performance baseline

Benchmark: `competition/bench/workloads.scm` (fib, tail-recursive sum, list build/reverse/length, vector fill/sum, string-append loop), run via `make bench` — which also produces a cross-language comparison table against Racket, Ruby, and a native-Crystal reference floor (see `competition/` and its README-style comments in `competition/bench.scm`).

## Environment

- Commit: `589260a` (make it R7RS Scheme compliant)
- Crystal: 1.20.3 (2026-07-02)
- Racket: 9.2 [cs]
- Machine: Darwin arm64 (Apple Silicon)
- `creme` built via `shards build --release --no-debug`
- Racket run with `#lang r7rs` (the `r7rs` package isn't installed by default on minimal-racket; installed via `raco pkg install --auto r7rs`)

## Results

| Workload | creme | Racket (r7rs) | Racket faster by |
|---|---|---|---|
| fib(27) | 0.252s | 0.0011s | ~225x |
| sum-to(2,000,000) | 0.860s | 0.0025s | ~344x |
| build-list(200,000) + reverse + length | 0.118s | 0.0080s | ~15x |
| vector-sum-test(500,000) | 0.723s | 0.0025s | ~294x |
| string-build-test(4,000) | 0.0035s | 0.0031s | ~1.1x |
| **total** | **1.957s** | **0.017s** | **~112x** |

## Notes

- Racket's `#lang r7rs` runs on Chez Scheme's native-compiling backend, so this is an interpreter-vs-JIT/AOT comparison, not an apples-to-apples "both tree-walking" one.
- `string-build-test` is the one workload where `creme` is near parity with Racket — everything else (deep recursion, tight tail loops, vector ops) shows the gap where Racket's compiled runtime dominates a tree-walking interpreter.
- Re-run with: `shards build --release --no-debug` (builds `bin/creme`), optionally `crystal build --release bench/bench.cr -o bin/bench_cr` (for the native-Crystal column), then `make bench` — a run-only target that assumes both are already built. It prints creme's own numbers plus a combined table against Racket (`bench/racket.scm`), Ruby (`bench/bench.rb`), and native Crystal; any of those three fall back to `n/a` if the toolchain/binary isn't available rather than failing the run.

## Profiling (2026-07-14)

Sampled the release binary (`sample <pid>`, 6s @ 1ms) on a heavy workload (`fib 33` + `sum-to 30,000,000`).

**Finding: the interpreter is allocation-bound.** At baseline, **~49% of samples (2399/4880) were inside `libgc`** — garbage collection, not evaluation. The whole eval loop inlines into `eval`/`eval_core`; there is no hot *builtin*. The GC pressure comes from what every function call allocates:

- an `Env` object, **plus two fresh arrays** (`@names`, `@values`) — 3 heap allocations per call frame;
- the args `Array` built during argument evaluation;
- a fresh `SchemeInt` box for every integer arithmetic result (`checked_int_op` / `Scheme.num_binop`).

`Env` (578), `Array` (740) and `SchemeInt` boxing were the dominant allocators.

### Optimization applied: share-names / adopt-values call frames

`Env` gained a fast call-frame constructor (`Env.new(parent, names, values)`) used by `make_call_env` in `interpreter.cr`. Instead of allocating two fresh arrays and copying each binding in (the old `Env.new(parent)` + per-param `define` path), a lambda frame now:

- **shares the callee's parameter-name array by reference** (it's immutable and identical on every call), copy-on-write if a body-internal `define` ever adds a new binding;
- **adopts the freshly-built args array directly as its value store** (in `eval_core`, where `args` is a disposable local) — zero extra allocation and no per-param linear-scan `define`.

A param-bearing call frame drops from 3 allocations to 1 (just the `Env` object; the args array is now the value store rather than waste).

Result: **GC share roughly halved (49% → ~25%)**; bench `total` improved ~5–6% (min-of-15: 1.91s → 1.80s). Full spec suite green in release mode (the only two failures — a one-ULP `(exp 1)` float-format difference and rfc8439's aarch64 NEON path — are pre-existing and identical on the baseline commit).

### Optimization applied: empty-frame sentinel storage

A freshly-created non-root frame no longer allocates its own `@names`/`@values` arrays — it starts out pointing at a single shared read-only pair of empty sentinel arrays (`Env::EMPTY_NAMES`/`EMPTY_VALUES`), and the first `define` that actually stores a binding swaps in freshly-owned arrays. A frame that binds nothing — `(let () body)`, a no-arg thunk body with no internal `define`, an empty nested scope — then costs just the `Env` object.

Design note (measure, don't assume): a first attempt made the storage nil-until-write, which forced an extra nil-branch into the *ultra-hot* `lookup_local`/`has_local?` read path and cost ~1% on the standard bench (N=25 interleaved) — a bad trade for a rare-case win. The sentinel version keeps those read paths byte-identical to owning a real (empty) array — `index`/`includes?` on an empty array is a trivial no-op — so there's no hot-path cost.

Result: **standard bench at parity** (−0.8% median, within noise), **empty-scope-heavy code ~6% faster** (a micro-bench doing 3 nested empty `let`s × 5M iterations: 4.83s → 4.55s). Spec suite green in release mode. This is a narrow lever — typical code rarely stacks empty scopes — but it's correctness-neutral and free on the common path.

### Optimization applied: value-type structs for immutable scalars

This is the "unbox the scalars" lever, realized via Crystal's type system rather than manual bit-tagging. `abstract class SchemeValue` became `module SchemeBaseValue` (the shared `to_display`/`to_write`/`*_string` surface) plus `alias SchemeValue = <union of all 38 concrete value types>` — because Crystal cannot mix `struct` and `class` in one inheritance hierarchy. Keeping the name `SchemeValue` left all ~1100 `: SchemeValue`/`Array(SchemeValue)` annotations untouched; the union of all-reference members is still an 8-byte pointer slot (Phase A, behavior/layout identical, specs green).

Then the immutable, value-compared scalars were flipped `class`→`struct` so they live **inline** in their container (`Array(SchemeValue)` slot, `Cons.car`, env value store) instead of heap-boxing per result. `(+ acc n)` no longer allocates two `SchemeInt`s per iteration. A mixed struct/class union is a ~16-byte tagged slot (so `Cons` grows 16→32 bytes — the tradeoff).

Kept (measured net-positive, release, interleaved A/B):
- **`SchemeInt` struct: int-heavy −10.1% median, list-heavy −5.75%** (fewer int allocations outweigh the wider `Cons`).
- **`SchemeFloat` struct: float-heavy −10.2% median**, int-heavy flat.

Skipped (evaluated, no measurable win — the staged "keep only net-positive" rule filtering):
- `SchemeChar`: a wash even on pure char-list allocation (the doubled `Cons` size cancels the saved char box).
- `SchemeSym`: already interned (shared), so no per-use allocation to remove.
- `SchemeBool`/`SchemeNil`: pure singletons (`TRUE`/`FALSE`/`NIL`) — never allocate.

The two `Reference#same?` fallbacks in `helpers.cr` (`scheme_eqv?`/`scheme_equal?`) were guarded with `b.is_a?(Reference)` (a value-type `b` can't be the same object as a reference `a`); a few spec identity assertions on now-value types moved `be`→`eq`. `SchemeStr` stays a class (mutated in place by `string-set!`/`fill!`/`copy!`).

### Remaining headroom (not yet done)

- After the above, `Array` (the args/value store) and the `Env` object are near the structural floor for a per-call frame that actually binds parameters.
- Manual **tagged fixnums** (pack the integer into the value word so the slot stays 8 bytes instead of the union's 16) would avoid the doubled-`Cons` cost the struct approach pays, and is what would make Char/Sym flips pay off too — but it needs unsafe pointer tagging and rewriting every accessor. The struct conversion above captured most of the integer/float win without that.
