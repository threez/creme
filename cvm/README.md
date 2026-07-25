# cvm — a second, C11 backend for this project's compiled bytecode

A second backend for this project's own compiled bytecode: the Crystal
front end (Lexer → Reader → `analyze` → `BytecodeCompiler`) is unchanged and
still owns compilation. `creme --emit-cvm <file.scm> <out.cvmc>` serializes
the resulting `Chunk` tree (see `src/scheme/compile/cvm_serializer.cr`) to a
small binary format; this directory is a from-scratch C11 VM that loads and
executes that file. `creme --cvm <file.scm>` / `creme --profile --cvm
<file.scm>` do the compile-then-run step in one command (see `src/main.cr`'s
`run_via_cvm`).

**Scope**: cvm started as a narrow experiment scoped to exactly what
`bench/creme.scm` compiled down to, but has since grown a substantial (if
still deliberately incomplete) chunk of the real opcode/builtin surface —
enough to run `competition/scheme/demo-todo/app.scm`, a genuine long-running
HTTP CRUD app using SQLite, a real HTTP server, and several pure-Scheme
libraries, end to end (see "Compatibility with `creme`" below for exactly
what is and isn't covered). It is still not a general Scheme runtime — no
continuations, no `guard`/`parameterize`, no bignum, no bytevectors — but the
right framing today is "a second backend implementing most of the language,"
not "a benchmark-only prototype."

## Building and running

```sh
cd cvm && make
cd .. && ./bin/creme --emit-cvm bench/creme.scm /tmp/creme.cvmc
./cvm/cvm /tmp/creme.cvmc
```

Output should match a normal `./bin/creme bench/creme.scm` run's numeric
results exactly (timings will naturally differ):

```
fib(27) = 196418  (...)
sum-to(2000000) = 2000001000000  (...)
build-list(200000) length+reverse = 200000  (...)
vector-sum-test(500000) = 249999500000  (...)
string-build-test(4000) length = 4000  (...)
tak(18,12,6) = 7  (...)
nqueens(9) = 352  (...)
total = ...s
```

A larger, real-world example — the same HTTP CRUD app the Crystal
interpreter runs, compiled and served via cvm instead:

```sh
./bin/creme --emit-cvm competition/scheme/demo-todo/app.scm /tmp/app.cvmc
PORT=4599 ./cvm/cvm /tmp/app.cvmc &
curl http://127.0.0.1:4599/                                # HTML page
curl -H "Accept: application/json" http://127.0.0.1:4599/   # JSON API
curl -X POST -d "title=Buy milk" http://127.0.0.1:4599/todos
```

## Profiling

`cvm --profile <file.cvmc>` runs the program under two independent samplers
and prints a hot-spot table for each — the same idea as `creme --profile
table <file.scm>`'s `(creme prof-vm)`/`(creme prof-native)` pair (see
src/main.cr's `handle_profile`), ported to this VM's own execution model:

- **Hot Scheme functions** (`cvm/profiler.c`'s `cvm_profiler_tick`, hooked
  into `vm.c`'s dispatch loop at every instruction fetch): a cooperative,
  jittered-interval instruction counter — mirrors
  `src/scheme/eval/interpreter.cr`'s `tick_sample` exactly, one sample every
  ~200 instructions on average. Each sample is a `(chunk, instruction index)`
  pair, symbolized as the chunk's own name, `file:line` (via a source line
  now stored per instruction in the `.cvmc` format — see below), and the
  opcode mnemonic.
- **Hot C frames** (`cvm_profiler_start_native`/`_stop_native`): a
  `SIGPROF`+`ITIMER_PROF` sampler capturing a raw `backtrace(3)` every ~1ms,
  symbolized via `dladdr(3)` once the run finishes. Unlike `creme`'s own
  native sampler, this one is **not** expected to show much per-Scheme-
  function detail: `cvm` runs Scheme-level calls through its own explicit
  `Frame` array (see "Call/upvalue mechanics" below), not C recursion, so a
  C-stack sample mostly reflects genuine C time — GC, builtins, and
  `cvm_dispatch`'s own loop — rather than which Scheme function was running.
  It's still useful for catching real C-level cost (e.g. a slow builtin, or
  GC pressure) that the VM-level sampler can't see at all.

Both samplers run for the whole program and cost nothing when `--profile`
isn't passed (guarded by a single `if (vm->profiler.enabled)` check per
instruction, and the `SIGPROF` timer is only installed for the duration of
a profiled run).

**Format note**: adding per-instruction source lines required a `.cvmc`
format bump (`"CVM1"` → `"CVM2"`, in `cvm_serializer.cr`/`cvm/loader.c`) — a
file emitted by an older `creme` build won't load; re-run `creme --emit-cvm`
to regenerate it.

facil.io (vendored — see the mux/sql/string/format sections below) prints a
single bare `\n` to **stderr** at process exit unconditionally, via its own
`__attribute__((destructor))` cleanup (`fio_lib_destroy` in `fio.c`) — this
fires even if nothing in a given program ever touches an HTTP/FIOBJ
feature, simply because facil.io is linked into every build. It's
stdout-only output that matters for correctness (verified byte-for-byte
against the real interpreter); don't mistake this trailing stderr newline
for a bug when comparing `2>&1`-merged output.

## Compatibility with `creme` (the Crystal interpreter)

cvm executes the exact same compiled bytecode `creme` does — there's no
separate compiler, no separate language surface — but it implements a
strict *subset* of the real VM's opcodes, builtins, and value model. A
script fails to `--emit-cvm` (or aborts at cvm runtime) the moment it needs
something outside that subset — there is no partial/degraded fallback path.
This section is the actual, current boundary — regenerate it by re-running
the checks below rather than trusting it blindly if this file feels old
again.

### Opcodes: 84 of the real 119

`cvm/opcodes.h`'s `OP_COUNT` (kept in sync with
`cvm_serializer.cr`'s `OP_IDS`, not `Scheme::Op`'s own enum ordinals)
currently covers: all load/move/global-read ops; the full fused
arithmetic/comparison family (`Add`/`Sub`/`Mul`/`NumLt`/`NumLe`/`NumGt`/
`NumGe`/`NumEq`/`IsEq`) with their `*Imm`/`*Up` specializations; `Cxr`,
`Abs`, `Not`, `IsNull`/`IsPair`; vector ops (`VecRef`/`VecSet`/`VecLen` +
`*Imm`/`*Up`); the string *read* side only (`StrRef`/`StrRefImm`/
`StrRefUp`); `Cons`; `Quasiquote` (+ its own `build_qq` in `vm.c`); the full
`Call`/`TailCall` family (`Call`, `TailCall`, `*Global`, `*Local`,
`*Upval`); the arithmetic `*Return` fusions (`AddReturn`/`SubReturn`/
`MulReturn`); `Closure`; `HelperForm`; the fused-branch `Test*` family; and
`CaseMatch`/`CaseDispatch` (so `case` — both the linear-scan and
hash-dispatch forms — is fully supported, along with `cond`/`when`/`unless`,
which compile to ordinary jump ops with nothing special of their own).

**Not implemented** (present in `Scheme::Op`, absent from cvm):

| Missing | Means no... |
|---|---|
| `SetGlobal` | top-level `(set! some-global ...)` |
| `Bv*` (`BvRef`/`BvSet` + `Imm`/`Up`) | bytevectors at all |
| `StrSet`/`StrSetImm`/`StrSetUp` | mutable strings (`string-set!`) |
| `NumLtReturn`/`NumLeReturn`/`NumGtReturn`/`NumGeReturn`/`NumEqReturn`/`IsEqReturn` | tail-position comparison fusion (only the arithmetic trio is fused) |
| `CmpZero` | fused `zero?`/`positive?`/`negative?` fast path |
| `TestIsEqUp` | one fused-branch corner (rest of `Test*Up` family is present) |
| `Throw` | a deferred-to-runtime malformed-form error |
| `MakeCaseClosure` | `case-lambda` |
| `Destructure` | `let-values`/`let*-values`/`define-values` |
| `ParamPush`/`ParamPop` | `parameterize` |
| `PushHandler`/`PopHandler`/`GuardReraise` | `guard` |
| `MakePromise` | `delay`/`delay-force`/`force` |
| `HelperFormLocal` | a body-internal `define-record-type` |

`call/cc`/`dynamic-wind` aren't opcodes in the real VM either — they're
Crystal-level exception-unwind mechanics in `Interpreter#apply`/`#call_cc`,
which cvm has no equivalent of at all (no continuation value, no unwind
machinery), so they're unsupported regardless of opcode coverage.

### Native builtins and library coverage

cvm has no runtime library/import machinery (see "Deliberate cuts" below)
— it hand-registers a flat, ungrouped set of global builtins in C, spread
across five files:

| File | Backs | Count | Notable names |
|---|---|---|---|
| `builtins.c` | most of `(scheme base)`, a little of `(scheme char)`/`(scheme write)`/`(scheme process-context)` | 88 | predicates, `car`/`cdr`/`cons`/list ops, `map`/`for-each`/`filter`/`apply`, `string-append`/`substring`/`string->number`/etc., `vector`/`vector->list`, `error`, `read-line`, `get-environment-variable` |
| `mux.c` | `(creme mux)` | 13 | `mux-router`, `mux-get!`/`post!`/etc., `mux-listen!`, `mux-close!` — real HTTP via vendored facil.io |
| `sql.c` | `(creme sql)` | 6 | `sql-open`, `sql-execute`, `sql-query`, `sql-scalar` — real SQLite via the C API |
| `hashtable.c` | `(creme hash-table)` (partial) | 6 | `make-hash-table`, `hash-table-set!`/`ref`/`contains?`/`delete!` — no `hash-table-keys`/`values`/`walk` yet |
| `strings.c` | `(creme string)` + `(creme format)` | 16 | `string-upcase`/`downcase`/`trim`/`split`/`join`/`replace`/`pad`/etc., `format` |

`+`/`-`/`*`/`/`/`<`/`>`/`<=`/`>=`/`=` are never builtins here — the
analyzer's own `PRIM_OPS` table (`ast.cr`) already folds a 2-arg call to one
of these names straight into a fused op, so no builtin registration is
needed for the common case; a 3+-arg or non-fused call to them isn't
supported.

Every other `(scheme ...)` library (`file`, `process-context` beyond
`get-environment-variable`, `time`, `complex`, `inexact`, `lazy`, `read`,
`eval`, `repl`, `r5rs`, `case-lambda`, `cxr`) and every other `(creme ...)`
FFI library (`bigdecimal`, `math`, `regex`, `json`, `file`, `time`,
`random`, `digest`, `env`, `process`, `tui`, `rfc8439`, `http`,
`prof-native`, `prof-vm`, `introspection`, `actor`, `raft`, `treelist`,
`csv`, `jose`, `reader`) has **no** cvm-native counterpart at all — a
script that calls into one won't resolve at cvm load/run time.

### `.sld` pure-Scheme libraries: transparent, not special-cased

File-based libraries under `modules/creme/*.sld` (`dao`, `memoize`, `for`,
`surf`, `html`, `css`, `path`, `json-builder`, `numfmt`, `table`, `bench`,
`cli`, `extra`, `sxql`, `match`, `sort`, `pipe`, `scanner`, `ir`, `peg`, …)
have no FFI of their own — they're ordinary Scheme, compiled down to plain
ops/builtin calls like anything else. `CVMSerializer.emit` runs every
`(import ...)` for real at *serialize* time (`interp.eval_import`), then
re-compiles each transitively-loaded file-based library's own body
(`Interpreter#library_body_forms_for_cvm`) into its own chunk, written
*before* the target script's chunks — so a `.sld` library "just works"
under cvm as long as everything it bottoms out in is covered by the tables
above. This is exactly how `competition/scheme/demo-todo/app.scm`'s
`(creme dao)`/`(creme memoize)`/`(creme for)`/`(creme surf)`/`(creme
html)`/`(creme css)`/`(creme path)`/`(creme json-builder)` all work end to
end with zero library-specific cvm code — only the FFI libraries they
ultimately call into (`sql`, `mux`, `string`) needed a native module.
`(creme prof)` is the one `.sld` that can't work this way — it's a pure
re-export of `prof-native`/`prof-vm`, neither of which has a cvm
counterpart.

### Value/type model

Per `value.h`'s own header comment — deliberate, not accidental:

- **Numbers**: fixnum (`int64_t`) + IEEE double only. No bignum, rational,
  or complex; arithmetic overflow **aborts** rather than promoting.
- **Representation**: a plain tagged `struct Value`, not NaN-boxed —
  chosen for debuggability over compactness.
- **Types present**: `T_NIL`, `T_BOOL`, `T_INT`, `T_FLOAT`, `T_SYM`
  (write-only — loaded into a register and discarded, never inspected at
  runtime), `T_STR` (immutable), `T_CHAR` (a codepoint, same representation
  as `T_INT`), `T_PAIR`, `T_VECTOR`, `T_PORT` (output-string only — no
  input ports, no file ports), `T_CLOSURE`, `T_BUILTIN`, and `T_BOX` (an
  opaque native handle, tagged by `kind`: hash table, SQL connection, mux
  router, mux server).
- **Not present at all**: bytevectors, records (`define-record-type`),
  continuations, promises (`delay`/`force`), any port beyond
  output-string, first-class environments, parameters
  (`make-parameter`/`parameterize`). `values`/`call-with-values` exist as
  builtins but don't carry a true multiple-values encoding — good enough
  for the common single-value case, not a real multi-value channel.
- **GC**: every heap allocation (pairs, vectors, closures, upvalues,
  output-string port buffers, hash tables, the program's own `Chunk` tree)
  goes through Boehm GC (`GC_MALLOC`/`GC_REALLOC` — the same collector
  Crystal itself uses), so a long-running program (an HTTP server) doesn't
  grow unbounded.

### Call/upvalue mechanics

Even where opcodes overlap, cvm's *execution model* deliberately mirrors
`src/scheme/eval/vm.cr`, not just its instruction set: one shared,
fixed-capacity register stack + explicit call-frame array (a trampolined
dispatch loop, not C recursion); non-tail `Call` pushes a new register
window, `TailCall*` reuses the current frame's window in place; upvalues
are open (pointing directly into the stack) while their owning frame is
live, and close (copy out) when it returns. This is why the native
profiler mostly can't see per-Scheme-function detail (see "Profiling"
above) — Scheme-level calls never become real C stack frames.

## Deliberate cuts (not bugs — see comments at each site)

- **Fixed-capacity register stack and frame array** (`CVM_STACK_CAP`,
  `CVM_FRAMES_CAP` in `vm.h`), never reallocated during execution — because
  an *open* upvalue holds a raw `Value *` into the stack, and growing via
  `realloc` would silently invalidate every such pointer. Generous fixed
  caps sidestep the whole problem rather than solving it generally.
- **Global resolution is ahead-of-time and unconditional**: `loader.c`
  rewrites every `GetGlobal`/`DefGlobal`/`CallGlobal`/`TailCallGlobal`
  operand from a const-pool symbol index to a direct index into the VM's
  global table, once, at load time — no per-call version check like the
  Crystal VM's inline cache. Sound only because this is one static, closed
  program with no `eval`/redefinition at runtime.
- **Fused-op deopt paths are hard aborts, not real fallbacks.** The Crystal
  VM's `Cxr`/`Abs`/`NumEq`/etc. fall back to the real builtin when their fast
  path's precondition fails (non-pair `cxr`, non-fixnum `abs`, ...); this VM
  just aborts with a message instead.
- **`HelperForm`** (the top-level `(import ...)`) is a runtime no-op —
  imports are already fully resolved by the Crystal compiler at *serialize*
  time (see "`.sld` pure-Scheme libraries" above), and the C VM's global
  table is pre-seeded with whatever native builtins the program needs. There
  is no R7RS library/import system *at runtime* — no `eval`, no dynamically
  loading a library cvm wasn't built with.
- Macros (`define-syntax`/`syntax-rules`/`defmacro`) are always gone by
  compile time regardless of backend — nothing cvm-specific there.

## Files

- `opcodes.h` — on-disk opcode/const-tag ids (kept in sync with
  `cvm_serializer.cr`'s `OP_IDS` table, not `Scheme::Op`'s own enum).
- `value.h` — the tagged `Value` struct and heap object types.
- `vm.h` — `Chunk`/`Frame`/`Closure`/`Upvalue`/`VM` struct definitions.
- `loader.c` — deserializes a `.cvmc` file, then resolves global names.
- `vm.c` — the dispatch loop, call/upvalue machinery, global table.
- `builtins.c` — the R7RS-base-ish builtin surface (see table above).
- `mux.c`/`mux.h` — `(creme mux)`, a real HTTP server via facil.io.
- `sql.c`/`sql.h` — `(creme sql)`, real SQLite via the C API.
- `hashtable.c`/`hashtable.h` — `(creme hash-table)`, via facil.io's `fiobj_hash`.
- `strings.c`/`strings.h` — `(creme string)`/`(creme format)`.
- `profiler.c`/`profiler.h` — the `--profile` samplers, see "Profiling" above.
- `main.c` — entry point: load, then run each top-level chunk in order.
