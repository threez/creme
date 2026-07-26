# cvm — a second, C11 backend for this project's compiled bytecode

A second backend for this project's own compiled bytecode: the Crystal
front end (Lexer → Reader → `analyze` → `BytecodeCompiler`) is unchanged and
still owns compilation. `creme --emit-cvm <file.scm> <out.cvmc>` compiles the
whole script (plus its transitively-imported pure-Scheme library bodies)
into one combined `Chunk` and serializes it (see
`src/scheme/compile/cvm_emitter.cr`) as "SCB1" — the SAME format
`src/scheme/compile/chunk_serializer.cr`/`chunk_deserializer.cr` round-trip
on the Crystal side, and the format `(creme bootstrap)`'s `load-chunk-bytes`
already reads. This directory is a from-scratch C11 VM that loads and
executes that file directly, using `Scheme::Op`'s own opcode numbering —
there's no separate cvm-specific bytecode format anymore. `creme --cvm
<file.scm>` / `creme --profile --cvm <file.scm>` do the compile-then-run
step in one command (see `src/main.cr`'s `run_via_cvm`).

**Scope**: cvm started as a narrow experiment scoped to exactly what
`bench/creme.scm` compiled down to, but has since grown to full 119/119
opcode parity with the real VM — including `guard`/`parameterize`,
`define-record-type`, `case-lambda`, multiple values, bytevectors, and
mutable strings — enough to run `competition/scheme/demo-todo/app.scm`, a
genuine long-running HTTP CRUD app using SQLite, a real HTTP server, and
several pure-Scheme libraries, end to end (see "Compatibility with `creme`"
below for exactly what's covered and the value-model/numeric-tower/
continuation gaps that remain). It is still not a general Scheme runtime —
call/cc is escape-only (no multi-shot/re-entrant continuations), and plain
fixnums are still `int64_t` with no bignum promotion on overflow (only
rationals, via GMP, are arbitrary-precision) — but the right framing today
is "a second backend implementing the language's control-flow surface
faithfully," not "a benchmark-only prototype."

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

## REPL

`cvm/repl.scm` bundles the self-hosted, Scheme-written compiler
(`modules/creme/compiler/{reader,bytecode,compiler}.sld`) and a small
read-compile-run loop, precompiled into ONE SCB1 image — after that
one-time build, an interactive session depends on nothing but this one
running cvm process; no live Crystal `creme` process is involved:

```sh
./bin/creme --emit-cvm cvm/repl.scm cvm/repl.cvmc   # one-time build
./cvm/cvm cvm/repl.cvmc                              # interactive REPL
```

This works because two things were already true before this file existed:
`cvm_global_intern` interns by name against one persistent `vm->globals`
table, so repeated chunk loads against the same `VM*` already share
bindings for free (`(define x 5)` on one line, `(display x)` on the
next); and the self-hosted compiler's `compile-source-to-bytes` already
produces exactly the SCB1 bytes cvm reads natively. The one missing piece
was a way to load-and-run a freshly-computed bytevector of those bytes
*from within an already-running cvm program* — `cvm/bootstrap.c`'s
`load-chunk-bytes` (mirroring `(creme bootstrap)`'s Crystal-side builtin
of the same name), backed by `loader.c`'s in-memory `cvm_load_from_bytes`
and `vm.c`'s reentrant `cvm_run_loaded_chunk`.

`cvm/bootstrap.c` also provides `import!` and `expand-if-macro`. cvm's
global table is already unconditionally flat, so "importing" anything
already baked into the running image (which is everything reachable at
all) has nothing left to do at cvm's own runtime level — but only/
except/prefix/rename import-set filters DO introduce genuinely new
alias names, which `import!` handles by bridging out to the self-hosted
compiler's own alias-generation logic (`import!-apply-aliases!`,
`compiler.sld`) when called as a bare procedure (see "Compiler mode"
below for the fixes this needed and the one case it's still narrower
than native Crystal on). The self-hosted compiler's own
`compile-import!`/`compile-form!` call both `import!` and
`expand-if-macro` unconditionally, so both need to exist for it to run
at all, REPL or not.

`expand-if-macro` recognizes a **`defmacro`** exported from a library
compiled straight to bytecode (Crystal-native ahead of time via
`--emit-cvm`, or this project's own self-hosted compiler) — e.g.
`sxql-select!` from `(creme sxql)`, if the image happened to bundle it: a
top-level `defmacro`'s `Op::HelperForm` (kind 4, `vm.c`) binds a genuine
`T_MACRO` value (`value.h`) under the macro's name, wrapping its raw
`(defmacro name (params...) body...)` form. `bi_expand_if_macro`
recognizes that tag and delegates the actual expansion (bind params
positionally to the call's own raw, unevaluated argument forms; compile +
run the body) to `modules/creme/compiler/compiler.sld`'s own
`defmacro-expand-form`, reached by name via `cvm_apply` — this file has
no compiler of its own to do that reentrant compile-and-run step in C,
but the self-hosted compiler is necessarily already loaded for
`expand-if-macro` to ever be called at all (it's `compiler.sld`'s own
compiled bytecode that calls it), and already has exactly this logic in
`compile-defmacro!`'s own transformer.

**Still-open, narrower limitation**: `define-syntax`/`syntax-rules`
macros are NOT covered by this — expanding one needs real pattern
matching (`sr-expand`, `compiler.sld`), unlike `defmacro`'s plain
bind-and-run-the-body semantics where there's no pattern to match at all.
A REPL session can still define and use its own `define-syntax`/
`defmacro` macros regardless (the compiler's own `macro-table` is an
ordinary mutable Scheme variable inside the loaded image, persisting
naturally across separate `load-chunk-bytes` calls in the same process),
and can now also use a **`defmacro`** exported from a flattened/
precompiled library baked into the image — just not one defined via
`define-syntax`.

Getting the self-hosted compiler to run under cvm at all also needed two
small, genuinely new capabilities cvm never had before, independent of
the REPL feature itself:
- **`(creme regex)`**, narrowed to just `regexp`/`regexp-matches?`
  (`cvm/regex.c`) — the self-hosted reader uses these for numeric-token
  classification. Backed by PCRE2 (the same regex flavor the real
  Crystal `Regex` class uses), specifically so `reader.sld`'s own
  `\A`/`\z`-anchored patterns work completely unchanged under cvm.
- **`+`/`-`/`*`/`/`/`<`/`>`/`<=`/`>=`/`=` as real global procedures**
  (`cvm/builtins.c`) — a program the *real* Crystal analyzer compiles
  never needs these as builtins (its `PRIM_OPS` table fuses a 2-arg call
  straight into an `Add`/`Sub`/etc. op), but the self-hosted compiler
  does no such fusion; anything it compiles calls these as ordinary
  global procedures. Reuse `vm.c`'s own `num_add`/`num_sub`/`num_lt`/…
  so the semantics (int/float/rational/complex promotion, overflow
  aborts) are identical to the fused fast-path ops. Also added along the
  way: `quotient`/`remainder`/`modulo` (needed by `(creme bytecode)`'s own
  integer encoding), `complex?`/`rational?`/`numerator`/`denominator`
  (needed by `(creme bytecode)`'s own datum-type dispatch when
  serializing a rational/complex constant — see "numeric tower" below),
  and `string-for-each` (needed by `(creme bytecode)`'s own string-writing
  helper).

**Scope (v1)**: one top-level form per line — no multi-line input. A
paren-balance-based line-accumulation loop is a natural follow-up, not
needed for the core deliverable.

## Compiler mode

Building on the REPL: point `cvm` at a plain `.scm` file and it compiles
and runs it directly — the target script never touches the Crystal
`creme` binary, only a small bundled "compiler driver" image (built once,
same as `repl.cvmc`) still needed Crystal to produce:

```sh
./bin/creme --emit-cvm cvm/compiler-run.scm cvm/compiler-run.cvmc   # one-time build
./cvm/cvm bench/creme.scm                                            # compiles + runs directly
```

`cvm/main.c` decides which mode to use by peeking a given file's first 4
bytes: `"SCB1"` means an already-compiled binary (today's behavior,
completely unchanged — `./cvm/cvm bench/creme.cvmc` still works exactly
as before), anything else means plain Scheme source needing compiler
mode. This is content-based, not extension-based — a `.scm` file's first
bytes (whitespace/`(`/`;`) can never coincidentally read as `"SCB1"` — so
no separate `--compile` flag is needed. In compiler mode, `main.c` stashes
the real target path (a new `cvm-target-path` builtin exposes it) and
loads+runs `cvm/compiler-run.cvmc` instead; that chunk's own driver code
(`cvm/compiler-run.scm`) reads the real target (a new `read-whole-file`
builtin — cvm's only other read capability, `read-line`, is hardwired to
stdin), compiles it, and `load-chunk-bytes`s the result — the same
mechanism the REPL already uses, just non-interactive and reading from a
file instead of stdin.

**`include`/`include-ci`**: the self-hosted compiler itself deliberately
doesn't support these (`reader.sld`'s own header comment — real support
needs a path-resolution design this project hasn't needed yet). Rather
than take that on, `cvm/compiler-run.scm` expands them itself, entirely
from already-exported toolchain primitives (`read-program`/
`compile-program`/`chunk->bytes` — no changes to `reader.sld`/
`compiler.sld`/`bytecode.sld`): parse the target into forms, recursively
splice in each top-level `(include "path" ...)`'s own parsed forms
(resolved relative to the *including* file's own directory, so a nested
include resolves against wherever its own file lives), then compile the
flattened list. This is exactly what makes `bench/creme.scm` — which
itself `(include "workloads.scm")`/`(include "workloads-demo.scm")` —
work under compiler mode at all.

Getting the self-hosted compiler to actually compile a real, non-trivial
program like `bench/creme.scm` (as opposed to the REPL's simple one-line
inputs) surfaced the rest of the pattern the REPL work had already
started: a program the *real* Crystal analyzer compiles never needs
`cadr`/`vector-ref`/`vector-set!`/`string-ref`/`string-set!`/
`bytevector-u8-ref`/`bytevector-u8-set!`/`char-downcase`/`char-upcase`/
`char<?`/`char>?`/`char<=?`/`char>=?` (or the whole rest of `(scheme
cxr)`'s `caar`..`cddddr` family) as *builtins* — the analyzer's `PRIM_OPS`
table fuses each call site straight into a `Cxr`/`VecRef`/`VecSet`/etc.
op — but the self-hosted compiler does no such fusion, so anything it
compiles needs every one of these to genuinely exist as an ordinary
global procedure too (`cvm/builtins.c`). Semantics mirror the fused ops'
own bounds checks exactly.

**Running `spec/creme`'s own test suite under compiler mode.** This
project's Scheme-native test framework (`(creme spec)`, `modules/creme/
spec.sld`) and its `spec/creme/*_spec.scm` files can run directly under
`cvm`:

```sh
make creme-spec-cvm    # rebuilds compiler-run.cvmc, then runs every spec file
./cvm/cvm spec/creme/vm_spec.scm    # or one file at a time
```

Getting there needed two more fixes beyond ordinary builtin gaps (`write`,
`write-char`, `exit`, `gensym`, `flonum->bits`/`bits->flonum`,
`string->number`'s radix arg, `+inf.0`/`-inf.0`/`+nan.0` in `write`'s own
float formatting — see "Native builtins" below):

- A target script that imports the compiler toolchain itself (`(creme
  compiler compiler)`/`(creme bytecode)`/etc. — exactly what every
  `spec/creme` file does, transitively, via `(creme compiler spec-
  helper)`) used to corrupt in-progress compilation: `compiler-run.scm`
  already bundles those libraries natively at BUILD time, but the self-
  hosted compiler's own library loader (`ensure-libraries-loaded!`,
  `compiler.sld`) had no way to know that, so it re-read and re-ran their
  source a SECOND time at cvm boot, re-executing `(define-record-type
  <chunk> ...)`/`<fcomp> ...)` and corrupting any chunk/fcomp object the
  outer, still-compiling target script already held from the original
  generation ("record accessor: expected a `<chunk>` record"). Fixed by
  exporting `mark-self-hosted-library-loaded!` and having `compiler-run.
  scm` pre-seed it for every library it itself already imports natively.
- `eval`/`open-input-string`/`read`/`eof-object` don't exist as cvm-
  native C builtins at all (see "Native builtins" above) — `compiler-
  run.scm` defines all four itself, in Scheme, reusing the self-hosted
  reader/compiler already loaded there (`eval` compiles+runs one form via
  `compile-program`/`load-chunk-bytes`; `open-input-string` parses a
  whole string upfront via `read-program`, and `read` pops one form off
  at a time) rather than adding a second parser/evaluator in C. Under
  cvm specifically there's no independent second evaluator to compare
  against anyway — this compiler is the only one cvm has any notion of.

**`call/cc`/`dynamic-wind`/`with-exception-handler`/`raise-continuable`**
are also real cvm features now, added specifically to get `spec/creme/
vm_spec.scm`'s own "dynamic-wind, call/cc, with-exception-handler" cases
passing under `cvm`:

- `call/cc`/`call-with-current-continuation` (`cvm/builtins.c`) is
  ESCAPE-ONLY (a one-shot, upward continuation, not a general
  re-enterable one — see `value.h`'s own `Continuation` doc comment):
  `setjmp` captures the point at call time; invoking the resulting
  `T_CONTINUATION` value later (`dispatch_call`/`cvm_apply` both
  recognize it directly, same as `T_PARAMETER`) drains any pending
  `dynamic-wind`/`parameterize` actions down to that point (see below)
  and `longjmp`s back, regardless of how deep the intervening C call
  stack got (nested `cvm_apply`s, e.g. a nested `for-each` callback) —
  the exact same technique `guard`'s own `GuardHandler` already used.
- `dynamic-wind` (`cvm/builtins.c`) generalizes the SAME unwind-stack
  mechanism `parameterize`'s `Op::PARAMPUSH`/`Op::PARAMPOP` already used
  (`vm.h`'s `UnwindAction`/`UnwindKind`) rather than adding a second,
  parallel mechanism: an `UNWIND_DYNAMIC_WIND` action calls its own
  `after` thunk, triggered either by normal return or by a `guard`
  handler (or a captured continuation) draining the stack past it.
- `with-exception-handler`/`raise-continuable` need no new C at all —
  both are plain Scheme, defined in `cvm/compiler-run.scm` atop
  `dynamic-wind`: a mutable handler-stack list, pushed/popped around
  `with-exception-handler`'s own thunk (via `dynamic-wind`, so an
  exception unwinding past it still restores the stack correctly), with
  `raise-continuable` popping the current handler before calling it (so
  a handler that itself raises sees the next-outer one, not itself) and
  restoring it before returning the handler's own result — an ordinary,
  non-escaping return, no continuation involved at all.

**`define-syntax`'s own runtime visibility** is also fixed: `Op::
HelperForm`'s kind 3 (`cvm/vm.c`) now binds a real `T_MACRO` value the
same way kind 4 (`defmacro`) already did, and `bi_expand_if_macro`
(`cvm/bootstrap.c`) picks the right bridge — `defmacro-expand-form` or
the new `define-syntax-expand-form` (`compiler.sld`, built on the self-
hosted compiler's own `sr-make-transformer`, its real `syntax-rules`
pattern matcher) — by checking the wrapped form's own head symbol. `cvm`
still never expands a `syntax-rules` use directly in C; it bridges out
to Scheme for that, same as it always did for `defmacro`.

Rationals and complex numbers (`compiler_numeric_tower_spec.scm`, the 7
complex-number cases in `reader_literals_spec.scm`) now work under `cvm`
too — see "Value/type model"'s `T_RATIONAL`/`T_COMPLEX` entries below for
what was added and exactly what's still NOT covered (plain fixnums are
still not arbitrary-precision).

`import!` applying an only/except/prefix/rename filter now works under
`cvm` too, including against a NATIVE library (`bootstrap_spec.scm`'s own
`(creme regex)` case) — `import!` (`cvm/bootstrap.c`'s `bi_import_bang`)
bridges a bare procedure call out to the self-hosted compiler's own
alias-generation logic (`import!-apply-aliases!`, `compiler.sld`, built
on the existing `alias-defines-for-specs`). This took two fixes:

1. `compile-import!`'s own runtime-emitted payload used to call `import!`
   BEFORE `ensure-libraries-loaded!`, firing a naively-bridged version of
   this too early — before a pure-Scheme library's own exports existed as
   real globals yet (an earlier attempt at exactly this bridge hit this
   and broke `compiler_libraries_spec.scm`'s prefix-import case, so it was
   reverted at the time). Fixed by reordering that emitted sequence (and
   its eager compile-time counterpart) to run `ensure-libraries-loaded!`
   first.
2. `library-export-alist` (the helper `prefix`/`rename` aliasing needs to
   learn what a library exports) used to only ever read a real `.sld`
   source file — no help for `(creme regex)`, a native (Crystal/cvm-
   builtin) library with none. Fixed by adding a `library-exports`
   builtin: native Crystal already tracks every registered library's own
   exports internally regardless of whether it's file- or Crystal-based
   (`SchemeLibrary#exports`, `eval/library.cr`), now exposed to Scheme via
   `(creme introspection)`; cvm has its own, much narrower
   `library-exports` (`cvm/bootstrap.c`) — a small hardcoded table
   covering just the native libraries this project's own spec suite
   actually needs aliased this way (today: `(creme regex)`), since cvm has
   no per-library grouping of its own flat global table to draw such a
   list from automatically.

One case remains — `bootstrap_spec.scm`'s "import! copies a library's
bindings into the global env" — a harmless environment artifact under
both `--self-hosted` and `cvm`, not a bug: each of these two bootstraps
already transitively imports `(creme regex)` for its own compiler's use,
so the test's own initial "is it genuinely unbound?" check is moot there
(see that file's own header comment). Not something this test suite is
trying to fix.

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

**Format note**: cvm reads "SCB1" (magic `"SCB1"`), the same format the real
Crystal VM's `ChunkSerializer`/`ChunkDeserializer` round-trip — there is no
separate cvm-specific format/opcode-numbering to keep in sync anymore. A
`.cvmc` file from before this change (the old "CVM2" format) won't load;
re-run `creme --emit-cvm` to regenerate it.

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

### Opcodes: 119 of 119 — full parity

`cvm/opcodes.h`'s enum now IS `Scheme::Op`'s own enum, in the exact same
declaration order — no separate compacted numbering to keep in lockstep by
hand anymore, and no unimplemented ops left (`OP_COUNT` = 119, all real).
Covers all
load/move/global-read/global-write ops (including top-level `set!`); the
full fused arithmetic/comparison family (`Add`/`Sub`/`Mul`/`NumLt`/`NumLe`/
`NumGt`/`NumGe`/`NumEq`/`IsEq`) with their `*Imm`/`*Up` specializations,
including every fused-branch `Test*` variant; `Cxr`, `Abs`, `CmpZero`
(`zero?`/`positive?`/`negative?`), `Not`, `IsNull`/`IsPair`; vector ops
(`VecRef`/`VecSet`/`VecLen` + `*Imm`/`*Up`); bytevector ops (`BvRef`/`BvSet`
+ `Imm`/`Up` — read AND write, backed by a real `T_BYTEVECTOR` value kind,
see "Value/type model" below); the full string family (`StrRef`/`StrSet` +
`Imm`/`Up`, read AND write — `string-set!` mutates `T_STR`'s buffer in
place, see "Value/type model" below for the aliasing invariant that makes
this safe); `Cons`; `Quasiquote` (+ its own `build_qq` in `vm.c`);
`MakePromise` (`delay`/`delay-force`, backed by a real `T_PROMISE` value
kind + a `force`/`promise?` builtin pair — see "Native builtins" below);
the full `Call`/`TailCall` family (`Call`, `TailCall`, `*Global`, `*Local`,
`*Upval`); the full `Return` family, including the bare-global/bare-upvalue
fusions (`ReturnGlobal`/`ReturnUpval`) and every arithmetic/comparison/
`eq?` tail fusion (`AddReturn`/`SubReturn`/`MulReturn`/`NumLtReturn`/
`NumLeReturn`/`NumGtReturn`/`NumGeReturn`/`NumEqReturn`/`IsEqReturn`);
`Throw`; `Closure`; `HelperForm` (now for real, not just its previous
import-only scope — see below); `HelperFormLocal`; `Destructure`
(`let-values`/`let*-values`/`define-values`, backed by a real `T_VALUES`
multi-value carrier — see "Value/type model" below; `values`/
`call-with-values` now genuinely carry more than one value, not just the
first); `MakeCaseClosure` (`case-lambda`, backed by a real
`T_CASE_CLOSURE` value kind — arity selection happens in
`dispatch_call`/`cvm_apply`, so a case-lambda called directly, via
`apply`, or via `map`/`for-each` all resolve the same way, mirroring
`BytecodeCaseClosure#select_clause` exactly); and `CaseMatch`/
`CaseDispatch` (so `case` — both the linear-scan and hash-dispatch forms
— is fully supported, along with `cond`/`when`/`unless`, which compile to
ordinary jump ops with nothing special of their own).

`define-record-type` is fully supported, both top-level (`HelperForm`
with `c=2`, binding the constructor/predicate/accessor/mutator/type
directly into the global table by name — this was previously an
undetected gap, since `HelperForm` used to unconditionally no-op
regardless of `c`) and function-body-internal (`HelperFormLocal`, a
genuinely fresh, disjoint `T_RECORD_TYPE` per *call*, not per compile —
see "Value/type model" below for the `T_RECORD`/`T_RECORD_TYPE`/
`T_RECORD_CALLABLE` value kinds this needed).

`guard` (`PushHandler`/`PopHandler`/`GuardReraise`) and `parameterize`
(`ParamPush`/`ParamPop`) are both fully supported now, closing what was by
far the largest remaining gap — see "Guard/parameterize implementation"
below for how, since neither maps onto ordinary opcode dispatch the way
everything else above does.

`call/cc`/`dynamic-wind` aren't opcodes in the real VM either — they're
Crystal-level exception-unwind mechanics in `Interpreter#apply`/`#call_cc`,
which cvm has no equivalent of at all (no continuation value), so they're
unsupported regardless of opcode coverage. This is unrelated to guard's own
unwinding (see below) — `call/cc` needs genuinely re-entrant continuations,
which is a different, harder problem `setjmp`/`longjmp` alone doesn't solve.

### Guard/parameterize implementation

Unlike every other op, `guard`'s three opcodes don't fit the ordinary
"read operands, write a register, NEXT()" shape — an error raised
arbitrarily deep (including through `cvm_apply`'s own reentrant C
recursion, e.g. inside a `map`/`for-each` callback) has to unwind straight
back to the nearest enclosing `guard`, in one step, regardless of how many
C stack frames sit in between. This VM uses `setjmp`/`longjmp` for that:

- `PushHandler` calls `setjmp` and stores the `jmp_buf` in a `GuardHandler`
  (`vm.h`) alongside the depth/condition-register/resume-ip it needs to
  restore — mirrors `vm.cr`'s own `GuardHandler` struct exactly. Its own
  `CASE` body is really two paths sharing one block: the normal path (just
  installed, `setjmp` returned 0, falls through to the guarded body) and
  the resume path (returned nonzero via a later `longjmp` — unwinds every
  pending `parameterize`/`dynamic-wind` action above the handler's own
  saved mark, closes upvalues for every discarded frame, collapses
  `vm->depth` straight back to the handler's frame, writes the condition
  into the clause-checking code's own register, and jumps there).
- `cvm_abort` (every runtime error in this VM funnels through it) checks
  a process-global "current VM" (mirrors `profiler.c`'s own
  `g_profiled_vm` pattern, since `cvm_abort`'s signature has no room for a
  `VM*` parameter across its ~100 existing call sites) — if a handler is
  installed, it builds a condition record and calls `cvm_raise_condition`
  (pop the handler, `longjmp`); otherwise it prints and `exit(1)`s exactly
  as before. `error`/`raise` (new builtins) do the same check themselves,
  building a real message+irritants condition (`error`) or raising the
  given value as-is (`raise`), so `error-object?`/`-message`/`-irritants`
  work correctly inside a `guard` clause.
- `ParamPush`/`ParamPop` push/pop an `UnwindAction` (saved parameter
  values to restore) onto a separate fixed-cap stack — drained either by
  `ParamPop` on normal exit or by a `guard` handler's own resume path when
  unwinding past it, so a `parameterize` around code that raises still
  correctly restores its parameters.

Verified against native `bin/creme` with test programs covering: `error`/
`raise` caught by `guard`, deeply nested (50-level) non-tail-call unwinds,
re-raising to an outer `guard`, `error-object?`/`-irritants`,
`parameterize` (with and without a converter), `parameterize`+`guard`
interaction (an error escaping a `parameterize`d region still restores
it), nested `parameterize`, and — the case that specifically exercises
`longjmp` unwinding through real C recursion — a `guard` around a `map`
call whose callback raises partway through.

### Native builtins and library coverage

cvm has no runtime library/import machinery (see "Deliberate cuts" below)
— it hand-registers a flat, ungrouped set of global builtins in C, spread
across seven files:

| File | Backs | Count | Notable names |
|---|---|---|---|
| `builtins.c` | most of `(scheme base)`/`(scheme cxr)`/`(scheme complex)`, a little of `(scheme char)`/`(scheme write)`/`(scheme process-context)`/`(scheme lazy)`/`(creme math)`/`(creme introspection)` | 180 | predicates, `car`/`cdr`/the full `caar`..`cddddr` family/`cons`/list ops, `map`/`for-each`/`filter`/`apply`, `string-append`/`substring`/`string-copy`/`string->number` (now with an optional radix arg, needed by `#b`/`#o`/`#x`-prefixed literals)/etc., `vector`/`vector->list`, `vector-ref`/`-set!`/`-length`, `string-ref`/`-set!`, `make-bytevector`/`bytevector`/`bytevector-length`/`bytevector?`/`-u8-ref`/`-u8-set!`, `force`/`promise?`, `error`, `raise`, `error-object?`/`-message`/`-irritants`, `make-parameter`, `read-line`, `read-whole-file`, `get-environment-variable`, `+`/`-`/`*`/`/`/`<`/`>`/`<=`/`>=`/`=` (now genuinely promoting through int/rational/float/complex — see "numeric tower" below), `quotient`/`remainder`/`modulo`, `string-for-each`, `char-downcase`/`-upcase`, `char<?`/`>?`/`<=?`/`>=?`, `write` (a real quoted/escaped external representation — `display`'s own `print_value` extended, not a second printer; `+inf.0`/`-inf.0`/`+nan.0` handled specially there too, needed once anything re-serializes a float this VM itself produced), `write-char`, `exit`, `gensym`, `flonum->bits`/`bits->flonum` (an exact IEEE754 bit-level reinterpret — needed by `(creme bytecode)`'s own SCB1 float-constant serialization, so any chunk with a float literal needed this), `dynamic-wind`, `call/cc`/`call-with-current-continuation` (escape-only — see "Compiler mode" above), `rational?`/`numerator`/`denominator` (int/rational only), `make-rectangular`/`make-polar`/`real-part`/`imag-part`/`magnitude`/`angle` (`(scheme complex)`'s complete surface — see "numeric tower" below) |
| `mux.c` | `(creme mux)` | 13 | `mux-router`, `mux-get!`/`post!`/etc., `mux-listen!`, `mux-close!` — real HTTP via vendored facil.io |
| `sql.c` | `(creme sql)` | 6 | `sql-open`, `sql-execute`, `sql-query`, `sql-scalar` — real SQLite via the C API |
| `hashtable.c` | `(creme hash-table)` (partial) | 6 | `make-hash-table`, `hash-table-set!`/`ref`/`contains?`/`delete!` — no `hash-table-keys`/`values`/`walk` yet; `hash-table-ref`'s own default arg may be a plain value OR a thunk (only applied if it's actually callable), matching native's own contract |
| `strings.c` | `(creme string)` + `(creme format)` | 16 | `string-upcase`/`downcase`/`trim`/`split`/`join`/`replace`/`pad`/etc., `format` |
| `bootstrap.c` | `(creme bootstrap)` (narrow — see "REPL"/"Compiler mode" above) + `(creme file)` (partial) | 8 | `load-chunk-bytes`, `import!`, `expand-if-macro`, `read-whole-file`, `cvm-target-path`, `file-read` (same function as `read-whole-file`, registered under both names), `file-write`, `delete-file` |
| `regex.c` | `(creme regex)` (very narrow — see "REPL" above) | 2 | `regexp`, `regexp-matches?` |

`+`/`-`/`*`/`/`/`<`/`>`/`<=`/`>=`/`=` didn't used to be builtins here — a
program the real analyzer compiles never needs them as such (its
`PRIM_OPS` table, `ast.cr`, already folds a 2-arg call to one of these
names straight into a fused op), but the self-hosted compiler doesn't do
that fusion (see "REPL" above), so they're real global procedures now
too — a 3+-arg or non-fused call to them works either way.

Every other `(scheme ...)` library (`file`, `process-context` beyond
`get-environment-variable`/`exit`, `time`, `inexact`, `repl`, `r5rs`,
`case-lambda`, `cxr`) and every other `(creme ...)` FFI library
(`bigdecimal`, `json`, `time`, `random`, `digest`, `env`, `process`,
`tui`, `rfc8439`, `http`, `prof-native`, `prof-vm`, `actor`, `raft`,
`treelist`, `csv`, `jose`) has **no** cvm-native counterpart at all — a
script that calls into one won't resolve at cvm load/run time. `(scheme
complex)` USED to be entirely unsupported (no `T_COMPLEX` value tag) but
now has real support — see "Value/type model" below and this section's
own `make-rectangular`/`make-polar`/`real-part`/`imag-part`/`magnitude`/
`angle` entry in `builtins.c`'s row above (its complete native surface,
not a subset).

Three more are *partially* covered, each only as far as this project's
own `spec/creme` test suite needed: `(creme math)` (just `flonum->bits`/
`bits->flonum`, not the rest of that FFI), `(creme introspection)` (just
`gensym`, not `macro?`/the rest), `(creme file)` (just `file-read`/
`file-write`/`delete-file`, not `file-exists?`/`file-append`/`file-lines`/
`file-size`/`current-directory`). `(scheme read)`'s `read`/
`open-input-string`/`eof-object` and `(scheme eval)`'s `eval` also have
no NATIVE (C) counterpart in this table at all, but ARE available when
running under cvm's own "compiler mode" (see below) -- `cvm/compiler-
run.scm` defines all four itself, in Scheme, reusing the self-hosted
reader/compiler already loaded there rather than adding a second parser/
evaluator in C (see that file's own comments on both).

### `.sld` pure-Scheme libraries: transparent, not special-cased

File-based libraries under `modules/creme/*.sld` (`dao`, `memoize`, `for`,
`surf`, `html`, `css`, `path`, `json-builder`, `numfmt`, `table`, `bench`,
`cli`, `extra`, `sxql`, `match`, `sort`, `pipe`, `scanner`, `ir`, `peg`, …)
have no FFI of their own — they're ordinary Scheme, compiled down to plain
ops/builtin calls like anything else. `CVMEmitter.emit` runs every
`(import ...)` for real at *emit* time (`interp.eval_import`), then
re-compiles each transitively-loaded file-based library's own body
(`Interpreter#library_body_forms_for_cvm`) along with the target script's
own forms into ONE combined chunk (library bodies first, so their globals
are defined before the script's own forms run) — so a `.sld` library "just
works" under cvm as long as everything it bottoms out in is covered by the
tables above. This is exactly how `competition/scheme/demo-todo/app.scm`'s
`(creme dao)`/`(creme memoize)`/`(creme for)`/`(creme surf)`/`(creme
html)`/`(creme css)`/`(creme path)`/`(creme json-builder)` all work end to
end with zero library-specific cvm code — only the FFI libraries they
ultimately call into (`sql`, `mux`, `string`) needed a native module.
`(creme prof)` is the one `.sld` that can't work this way — it's a pure
re-export of `prof-native`/`prof-vm`, neither of which has a cvm
counterpart.

### Value/type model

Per `value.h`'s own header comment — deliberate, not accidental:

- **Numbers**: fixnum (`int64_t`) + IEEE double + exact rational
  (`T_RATIONAL`, arbitrary-precision via GMP's `mpq_t`) + complex
  (`T_COMPLEX`, a real/imag pair, each itself int/rational/float). Plain
  fixnums are STILL fixed-width — arithmetic overflow on a `T_INT` still
  **aborts** rather than promoting to a bignum; only `T_RATIONAL`'s own
  numerator/denominator are arbitrary-precision. `+`/`-`/`*`/`/`/comparisons
  promote across this tower the same way the real interpreter does (int <
  rational < float rank, complex checked first and promoting both sides) —
  see `vm.c`'s `num_add`/`num_div`/etc. and "numeric tower" above for what
  motivated this and exactly what's still NOT covered (a bignum `T_INT`;
  `floor`/`ceiling`/`round`/`truncate` of a rational; `abs`/`zero?`/
  `positive?`/`negative?` of a complex value).
- **Representation**: a plain tagged `struct Value`, not NaN-boxed —
  chosen for debuggability over compactness.
- **Types present**: `T_NIL`, `T_BOOL`, `T_INT`, `T_FLOAT`, `T_SYM`
  (write-only — loaded into a register and discarded, never inspected at
  runtime), `T_STR` (**mutable** via `string-set!`, as of Group C — every
  `T_STR` value always owns a freshly `GC_MALLOC`'d, uniquely-owned buffer;
  the invariant that makes mutation safe is that nothing may ever alias
  another Value's buffer, a substring offset, or a C string literal
  in `.rodata` (which would segfault on the first `string-set!`) — see
  `builtins.c`'s `copy_bytes`/`bi_substring`/`bi_symbol_to_string`,
  `strings.c`'s `bi_string_trim`, and `mux.c`/`sql.c`'s `v_litstr`, all of
  which used to alias and now copy), `T_CHAR` (a codepoint, same
  representation as `T_INT`), `T_PAIR`, `T_VECTOR`, `T_BYTEVECTOR` (a
  mutable raw byte buffer — from a `#u8(...)` const, `make-bytevector`, or
  `bytevector`), `T_PROMISE` (`delay`/`delay-force`'s wrapped thunk,
  memoized on first `force` — see `builtins.c`'s `bi_force`; a
  `delay-force` thunk that itself returns another promise is NOT
  transparently re-forced through, since `delay`/`delay-force` compile to
  the exact same `MakePromise` op), `T_PORT` (output-string only — no
  input ports, no file ports), `T_CLOSURE`, `T_CASE_CLOSURE` (`case-lambda`
  — an ordered array of `Closure`s, one per clause; `dispatch_call`/
  `cvm_apply` pick the first whose arity accepts the call's argument
  count), `T_BUILTIN`, and `T_BOX` (an opaque native handle, tagged by
  `kind`: hash table, SQL connection, mux router, mux server), and
  `T_VALUES` (a genuine multiple-values carrier —
  `values` wraps 0 or 2+ args in one, a single arg is returned as itself
  unwrapped, never appears as an ordinary Scheme value anywhere else;
  unpacked by `Destructure` and `call-with-values`, see `builtins.c`'s
  `bi_values`/`bi_call_with_values`), `T_RECORD_TYPE`/`T_RECORD`/
  `T_RECORD_CALLABLE` (`define-record-type` — a type descriptor, a record
  instance (type pointer + positional fields array, type compared by
  IDENTITY not name, so distinct `define-record-type` invocations are
  always disjoint even when they share a type name), and one generated
  constructor/predicate/accessor/mutator per type respectively;
  `dispatch_call`/`cvm_apply` recognize `T_RECORD_CALLABLE` directly,
  since cvm's plain `BuiltinFn` function pointer has nowhere to stash a
  captured record type/field index the way a real closure can — see
  `vm.c`'s `call_record_callable`), and `T_PARAMETER` (`make-parameter`'s
  own value — current value + optional converter procedure, mirrors
  `SchemeParameter` exactly; calling it with 0 args returns its current
  value, same `dispatch_call`/`cvm_apply` recognition pattern as
  `T_RECORD_CALLABLE`, though `procedure?` deliberately excludes it,
  matching the real interpreter's own narrower definition), `T_CONTINUATION`
  (`call/cc`'s escape-only captured jump point — see "Compiler mode"
  above), and `T_RATIONAL`/`T_COMPLEX` (the numeric tower additions
  described just above).
- **Not present at all**: multi-shot/re-entrant continuations (only
  escape-only `T_CONTINUATION`, above), any port beyond output-string,
  first-class environments, and — unrelated to the value model itself,
  but worth naming here too — no bignum promotion for plain `T_INT`
  fixnums (see "Deliberate cuts" below).
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
  imports are already fully resolved by the Crystal compiler at *emit*
  time, and any pure-Scheme library body they need is already flattened
  into the same combined chunk (see "`.sld` pure-Scheme libraries" above);
  the C VM's global table is also pre-seeded with whatever native builtins
  the program needs. There is no R7RS library/import system *at runtime* —
  no `eval`, no dynamically loading a library cvm wasn't built with.
- Macros (`define-syntax`/`syntax-rules`/`defmacro`) are always gone by
  compile time regardless of backend — nothing cvm-specific there, for an
  ordinary precompiled program. `Op::HelperForm`'s kind==4 (top-level
  `defmacro`) is the one exception, needed for the "Compiler mode"/REPL
  scenario above: it binds a real `T_MACRO` runtime value so `expand-if-
  macro` can recognize a `defmacro` exported from a library compiled
  straight to bytecode when the self-hosted compiler runs reentrant under
  cvm — see that section's own description. `define-syntax` stays a pure
  no-op either way (no runtime pattern-matching support in this VM).

## Files

- `opcodes.h` — on-disk opcode/const-tag ids: `Scheme::Op`'s own enum
  ordinals (`src/scheme/compile/opcode.cr`) and SCB1's `TAG_*`/`CDK_*`/`QQ_*`
  constants (`chunk_serializer.cr`), not a separate cvm-specific numbering.
- `value.h` — the tagged `Value` struct and heap object types.
- `vm.h` — `Chunk`/`Frame`/`Closure`/`Upvalue`/`VM` struct definitions.
- `loader.c` — deserializes an SCB1 file OR in-memory byte buffer (one
  combined `Chunk`, no multi-chunk envelope), then resolves global names.
- `vm.c` — the dispatch loop, call/upvalue machinery, global table,
  guard/parameterize unwind machinery (`cvm_abort`/`cvm_raise_condition`).
- `builtins.c` — the R7RS-base-ish builtin surface (see table above).
- `mux.c`/`mux.h` — `(creme mux)`, a real HTTP server via facil.io.
- `sql.c`/`sql.h` — `(creme sql)`, real SQLite via the C API.
- `hashtable.c`/`hashtable.h` — `(creme hash-table)`, via facil.io's `fiobj_hash`.
- `strings.c`/`strings.h` — `(creme string)`/`(creme format)`.
- `bootstrap.c`/`bootstrap.h` — `load-chunk-bytes`/`import!`/
  `expand-if-macro`, see "REPL" above.
- `regex.c`/`regex.h` — `regexp`/`regexp-matches?` via PCRE2, see "REPL" above.
- `repl.scm` — the REPL driver script, precompiled into `repl.cvmc`.
- `compiler-run.scm` — the compiler-mode driver script (see "Compiler
  mode" above), precompiled into `compiler-run.cvmc`.
- `profiler.c`/`profiler.h` — the `--profile` samplers, see "Profiling" above.
- `main.c` — entry point: load and run the one combined chunk.
