# icecreme — a second, C11 backend for this project's compiled bytecode

A second backend for this project's own compiled bytecode: the Crystal
front end (Lexer → Reader → `analyze` → `BytecodeCompiler`) is unchanged and
still owns compilation. `creme --emit-icecreme <file.scm> <out.ice>` compiles the
whole script (plus its transitively-imported pure-Scheme library bodies)
into one combined `Chunk` and serializes it (see
`src/creme/compile/creme_emitter.cr`) as "ICE1" — the SAME format
`src/creme/compile/chunk_serializer.cr`/`chunk_deserializer.cr` round-trip
on the Crystal side, and the format `(creme bootstrap)`'s `load-chunk-bytes`
already reads. This directory is a from-scratch C11 VM that loads and
executes that file directly, using `Creme::Op`'s own opcode numbering —
there's no separate icecreme-specific bytecode format anymore. `creme --icecreme
<file.scm>` / `creme --profile --icecreme <file.scm>` do the compile-then-run
step in one command (see `src/main.cr`'s `run_via_cvm`).

**Scope**: icecreme started as a narrow experiment scoped to exactly what
`competition/scheme/bench/creme.scm` compiled down to, but has since grown to full 119/119
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

**Stability**: see `STABILITY.md` for what's guaranteed to keep working
across a release (the ICE1 bytecode format's version-checked read
compatibility, the base builtin set, the CLI contract) versus what's
still explicitly in flux (internal struct layout, no stable C ABI yet).

## Building and running

```sh
cd icecreme && make
cd .. && ./bin/creme --emit-icecreme competition/scheme/bench/creme.scm /tmp/creme.ice
./icecreme/icecreme /tmp/creme.ice
```

Output should match a normal `./bin/creme competition/scheme/bench/creme.scm` run's numeric
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
interpreter runs, compiled and served via icecreme instead:

```sh
./bin/creme --emit-icecreme competition/scheme/demo-todo/app.scm /tmp/app.ice
PORT=4599 ./icecreme/icecreme /tmp/app.ice &
curl http://127.0.0.1:4599/                                # HTML page
curl -H "Accept: application/json" http://127.0.0.1:4599/   # JSON API
curl -X POST -d "title=Buy milk" http://127.0.0.1:4599/todos
```

## REPL

`icecreme/repl.scm` is now a two-line shim (`(import (creme repl)) (run-repl)`)
over `modules/creme/repl.sld`, the same shared REPL loop the native
Crystal interpreter and `--self-hosted` mode also delegate to. Run it as
plain Scheme SOURCE, directly, via `./icecreme/icecreme`:

```sh
./icecreme/icecreme icecreme/repl.scm   # interactive (or piped) REPL, no precompile step
```

This must NOT be precompiled ahead of time via `--emit-icecreme` into a
standalone `.ice` — `(creme repl)` relies on the portable `(scheme
read)`/`(scheme eval)`/`(interaction-environment)`, and icecreme has no native
C builtins for those. The only place they're backed at all is "Compiler
mode" below: when `icecreme/icecreme` is pointed at raw `.scm` source, it loads the
bundled self-hosted compiler (`icecreme/compiler-run.ice`) first, and that
compiler defines `read`/`eval`/`interaction-environment` itself as part of
its own toolchain setup before compiling-and-running the target script.
An ahead-of-time `--emit-icecreme` build of `repl.scm` skips that bridge
entirely, so a precompiled `repl.ice` crashes the moment a form is
submitted (`unbound variable: read`) — always invoke `repl.scm` straight
from source, the same way `spec/creme/*.scm` files already do.

This works because two things were already true before this file existed:
`creme_global_intern` interns by name against one persistent `vm->globals`
table, so repeated chunk loads against the same `VM*` already share
bindings for free (`(define x 5)` on one line, `(display x)` on the
next); and the self-hosted compiler's `compile-source-to-bytes` already
produces exactly the ICE1 bytes icecreme reads natively. The one missing piece
was a way to load-and-run a freshly-computed bytevector of those bytes
*from within an already-running icecreme program* — `icecreme/bootstrap.c`'s
`load-chunk-bytes` (mirroring `(creme bootstrap)`'s Crystal-side builtin
of the same name), backed by `loader.c`'s in-memory `creme_load_from_bytes`
and `vm.c`'s reentrant `creme_run_loaded_chunk`.

`icecreme/bootstrap.c` also provides `import!` and `expand-if-macro`. icecreme's
global table is already unconditionally flat, so "importing" anything
already baked into the running image (which is everything reachable at
all) has nothing left to do at icecreme's own runtime level — but only/
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
`--emit-icecreme`, or this project's own self-hosted compiler) — e.g.
`sxql-select!` from `(creme sxql)`, if the image happened to bundle it: a
top-level `defmacro`'s `Op::HelperForm` (kind 4, `vm.c`) binds a genuine
`T_MACRO` value (`value.h`) under the macro's name, wrapping its raw
`(defmacro name (params...) body...)` form. `bi_expand_if_macro`
recognizes that tag and delegates the actual expansion (bind params
positionally to the call's own raw, unevaluated argument forms; compile +
run the body) to `modules/creme/compiler/compiler.sld`'s own
`defmacro-expand-form`, reached by name via `creme_apply` — this file has
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

Getting the self-hosted compiler to run under icecreme at all also needed two
small, genuinely new capabilities icecreme never had before, independent of
the REPL feature itself:
- **`(creme regex)`**, narrowed to just `regexp`/`regexp-matches?`
  (`icecreme/regex.c`) — the self-hosted reader uses these for numeric-token
  classification. Backed by PCRE2 (the same regex flavor the real
  Crystal `Regex` class uses), specifically so `reader.sld`'s own
  `\A`/`\z`-anchored patterns work completely unchanged under icecreme.
- **`+`/`-`/`*`/`/`/`<`/`>`/`<=`/`>=`/`=` as real global procedures**
  (`icecreme/builtins.c`) — a program the *real* Crystal analyzer compiles
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

This is what the REPL above actually runs on: point `icecreme` at a plain
`.scm` file and it compiles and runs it directly — the target script
never touches the Crystal `creme` binary, only a small bundled "compiler
driver" image (built once, still needed Crystal to produce):

```sh
./bin/creme --emit-icecreme icecreme/compiler-run.scm icecreme/compiler-run.ice   # one-time build
./icecreme/icecreme competition/scheme/bench/creme.scm                                            # compiles + runs directly
```

`icecreme/main.c` decides which mode to use by peeking a given file's first 4
bytes: `"ICE1"` means an already-compiled binary (today's behavior,
completely unchanged — `./icecreme/icecreme competition/scheme/bench/creme.ice` still works exactly
as before), anything else means plain Scheme source needing compiler
mode. This is content-based, not extension-based — a `.scm` file's first
bytes (whitespace/`(`/`;`) can never coincidentally read as `"ICE1"` — so
no separate `--compile` flag is needed. In compiler mode, `main.c` stashes
the real target path (a new `icecreme-target-path` builtin exposes it) and
loads+runs `icecreme/compiler-run.ice` instead; that chunk's own driver code
(`icecreme/compiler-run.scm`) reads the real target (a new `read-whole-file`
builtin — icecreme's only other read capability, `read-line`, is hardwired to
stdin), compiles it, and `load-chunk-bytes`s the result — the same
mechanism the REPL already uses, just non-interactive and reading from a
file instead of stdin.

**`include`/`include-ci`**: the self-hosted compiler itself deliberately
doesn't support these (`reader.sld`'s own header comment — real support
needs a path-resolution design this project hasn't needed yet). Rather
than take that on, `icecreme/compiler-run.scm` expands them itself, entirely
from already-exported toolchain primitives (`read-program`/
`compile-program`/`chunk->bytes` — no changes to `reader.sld`/
`compiler.sld`/`bytecode.sld`): parse the target into forms, recursively
splice in each top-level `(include "path" ...)`'s own parsed forms
(resolved relative to the *including* file's own directory, so a nested
include resolves against wherever its own file lives), then compile the
flattened list. This is exactly what makes `competition/scheme/bench/creme.scm` — which
itself `(include "workloads.scm")`/`(include "workloads-demo.scm")` —
work under compiler mode at all.

Getting the self-hosted compiler to actually compile a real, non-trivial
program like `competition/scheme/bench/creme.scm` (as opposed to the REPL's simple one-line
inputs) surfaced the rest of the pattern the REPL work had already
started: a program the *real* Crystal analyzer compiles never needs
`cadr`/`vector-ref`/`vector-set!`/`string-ref`/`string-set!`/
`bytevector-u8-ref`/`bytevector-u8-set!`/`char-downcase`/`char-upcase`/
`char<?`/`char>?`/`char<=?`/`char>=?` (or the whole rest of `(scheme
cxr)`'s `caar`..`cddddr` family) as *builtins* — the analyzer's `PRIM_OPS`
table fuses each call site straight into a `Cxr`/`VecRef`/`VecSet`/etc.
op — but the self-hosted compiler does no such fusion, so anything it
compiles needs every one of these to genuinely exist as an ordinary
global procedure too (`icecreme/builtins.c`). Semantics mirror the fused ops'
own bounds checks exactly.

**Running `spec/creme`'s own test suite under compiler mode.** This
project's Scheme-native test framework (`(creme spec)`, `modules/creme/
spec.sld`) and its `spec/creme/*_spec.scm` files can run directly under
`icecreme`:

```sh
make creme-spec-icecreme    # rebuilds compiler-run.ice, then runs every spec file
./icecreme/icecreme spec/creme/vm_spec.scm    # or one file at a time
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
  source a SECOND time at icecreme boot, re-executing `(define-record-type
  <chunk> ...)`/`<fcomp> ...)` and corrupting any chunk/fcomp object the
  outer, still-compiling target script already held from the original
  generation ("record accessor: expected a `<chunk>` record"). Fixed by
  exporting `mark-self-hosted-library-loaded!` and having `compiler-run.
  scm` pre-seed it for every library it itself already imports natively.
- `eval`/`open-input-string`/`read`/`eof-object` don't exist as icecreme-
  native C builtins at all (see "Native builtins" above) — `compiler-
  run.scm` defines all four itself, in Scheme, reusing the self-hosted
  reader/compiler already loaded there (`eval` compiles+runs one form via
  `compile-program`/`load-chunk-bytes`; `open-input-string` parses a
  whole string upfront via `read-program`, and `read` pops one form off
  at a time) rather than adding a second parser/evaluator in C. Under
  icecreme specifically there's no independent second evaluator to compare
  against anyway — this compiler is the only one icecreme has any notion of.

**`call/cc`/`dynamic-wind`/`with-exception-handler`/`raise-continuable`**
are also real icecreme features now, added specifically to get `spec/creme/
vm_spec.scm`'s own "dynamic-wind, call/cc, with-exception-handler" cases
passing under `icecreme`:

- `call/cc`/`call-with-current-continuation` (`icecreme/builtins.c`) is
  ESCAPE-ONLY (a one-shot, upward continuation, not a general
  re-enterable one — see `value.h`'s own `Continuation` doc comment):
  `setjmp` captures the point at call time; invoking the resulting
  `T_CONTINUATION` value later (`dispatch_call`/`creme_apply` both
  recognize it directly, same as `T_PARAMETER`) drains any pending
  `dynamic-wind`/`parameterize` actions down to that point (see below)
  and `longjmp`s back, regardless of how deep the intervening C call
  stack got (nested `creme_apply`s, e.g. a nested `for-each` callback) —
  the exact same technique `guard`'s own `GuardHandler` already used.
- `dynamic-wind` (`icecreme/builtins.c`) generalizes the SAME unwind-stack
  mechanism `parameterize`'s `Op::PARAMPUSH`/`Op::PARAMPOP` already used
  (`vm.h`'s `UnwindAction`/`UnwindKind`) rather than adding a second,
  parallel mechanism: an `UNWIND_DYNAMIC_WIND` action calls its own
  `after` thunk, triggered either by normal return or by a `guard`
  handler (or a captured continuation) draining the stack past it.
- `with-exception-handler`/`raise-continuable`/`raise` are genuine
  icecreme-native C builtins now (`icecreme/builtins.c`), backed by a real
  VM-wide handler stack (`vm->exc_handlers`, `vm.h`) — they used to be
  plain Scheme, defined only in `icecreme/compiler-run.scm` atop
  `dynamic-wind` (a mutable handler-stack list), which meant they only
  ever worked when a script ran through icecreme's own "compiler mode"
  (below); a precompiled `--emit-icecreme` program calling
  `with-exception-handler` hit "unbound variable". `with-exception-
  handler` pushes `handler` onto `vm->exc_handlers` and registers a
  dedicated `UNWIND_EXC_HANDLER` unwind action (`vm.h`'s own
  `UnwindAction`/`UnwindKind`, alongside `UNWIND_PARAMS`/
  `UNWIND_DYNAMIC_WIND`) that restores `vm->n_exc_handlers` to an
  absolute remembered mark — not just "pop one", the way a naive
  `dynamic-wind`-based `after` thunk would, since that breaks if
  `raise-continuable`'s own temporary pop-call-pushback around the
  handler is still in flight when a captured continuation or another
  raised exception escapes past this frame (a `dynamic-wind`-shaped fix
  would double-pop in that case). `raise-continuable` pops the current
  handler before calling it (so a handler that itself raises sees the
  next-outer one, not itself), then pushes it back before returning the
  handler's own result. Plain (non-continuable) `raise` used to drive
  ONLY the C-level `guard`/`GuardHandler` longjmp stack, never
  consulting an installed `with-exception-handler` at all — a genuine
  R7RS-correctness gap, now fixed alongside this: `raise` tries the
  current handler first (same pop/call/push-back as `raise-continuable`)
  and only falls through to the `guard`/top-level unwind if that handler
  returns normally (which has nowhere for its value to go on a
  non-continuable raise). `icecreme/compiler-run.scm` no longer redefines any
  of these — doing so would just shadow the new C builtins via its own
  top-level `define` (icecreme's flat global table lets a later `define`
  overwrite an earlier binding by name), silently reverting compiler-mode
  scripts to the old, narrower behavior.

**A pure-Scheme library's own `include`/`include-ci`/`cond-expand`
declarations, and a bare import-set's own export-rename, now work under
`icecreme` too.** `modules/creme/compiler/compiler.sld`'s own
`ensure-library-loaded!` — the self-hosted compiler's library loader,
and the ONLY thing actually loading a pure-Scheme library's body under
`icecreme` (native Crystal's own real `import!` does the equivalent work
directly at runtime, which is why none of this ever showed up as a gap
under plain `./bin/creme`/`--self-hosted`, despite both running this
exact same `compiler.sld`) — used to recognize only literal `import`/
`begin` clauses in a library's own body, silently ignoring `include`/
`include-ci`/`cond-expand` declarations entirely. `process-library-
clause!` now handles all four uniformly (a `cond-expand` clause's own
matched declarations re-dispatch through this SAME function, so nested
`import`/`begin`/`include`/`cond-expand` inside it all just work, not
just one declaration kind); `include-ci` also fold-cases the included
source first (`ascii-foldcase-string` — ASCII-only, and folds the whole
source blindly rather than skipping string/char literal contents the
way a real `#!fold-case` reader would, an honest simplification given
this compiler has no `(scheme char)` `string-foldcase` to reach for
here). Separately, `import-set-alias-defines`'s own `else` branch (a
bare, non-only/except/prefix/rename import-set — i.e. plain `(import
(some-lib))`) used to generate no aliases at all, so a library's own
`(export (rename internal external))` never actually bound `external`
as a global under icecreme's self-hosted-loader-only path; it now consults
`library-export-alist` (already correctly parsing this) the same way
the `prefix`/`rename` cases already did. Still NOT attempted: a
*top-level* `(import ...)` declaration's own only/except/prefix/rename
filters genuinely restricting visibility for the whole importing
program (as opposed to just aliasing an additional name), and a
library body genuinely seeing only what it explicitly imports — both
still blocked on icecreme's single, whole-program-wide flat global table
having no notion of "this program's own visible names" distinct from
"every name any library anywhere has ever defined". (`environment`'s
*own* only/except/prefix/rename import-sets are a different, narrower
case — see "environment/eval" below — and now genuinely restrict
visibility within the fresh environment they build, since that's a
genuinely separate global table, not the whole program's own.) See
`spec/creme/r7rs/ch05_program_structure_spec.scm`'s own header comment
for the one remaining case this affects.

**`define-syntax`'s own runtime visibility** is also fixed: `Op::
HelperForm`'s kind 3 (`icecreme/vm.c`) now binds a real `T_MACRO` value the
same way kind 4 (`defmacro`) already did, and `bi_expand_if_macro`
(`icecreme/bootstrap.c`) picks the right bridge — `defmacro-expand-form` or
the new `define-syntax-expand-form` (`compiler.sld`, built on the self-
hosted compiler's own `sr-make-transformer`, its real `syntax-rules`
pattern matcher) — by checking the wrapped form's own head symbol. `icecreme`
still never expands a `syntax-rules` use directly in C; it bridges out
to Scheme for that, same as it always did for `defmacro`.

**`include`/`include-ci` now also work in ordinary body position** (inside
a `let`/`lambda`/library `begin` body, not just at a script's own top
level or a library declaration — see the previous entry for that
narrower, declaration-only case). `compiler.sld`'s `flatten-begins` (the
same pass that already spliced a nested `(begin ...)` form's contents in
place) gained an `include`/`include-ci` case calling a new
`expand-include-form`, which resolves the included path against
`current-compiling-file` (a new mutable var, save/restored around
`compile-program`'s now-optional 2nd argument — the file path being
compiled, threaded through from both `icecreme/compiler-run.scm` and
`src/main.cr`'s native `--self-hosted` entry points) so nested includes
resolve relative to wherever their own file lives, exactly mirroring the
existing top-level/library-declaration include logic. This needed real
file-reading, so `(creme file)` was added to `compiler.sld`'s own
`(import ...)` list and `expand-include-form`/the library-declaration
`include` branch (previous entry) both call `file-read` (portable,
available under native/self-hosted/icecreme alike) instead of the icecreme-only
`read-whole-file`.

**Regression this surfaced, and why it's fixed by keeping `file-read` and
`read-whole-file` deliberately separate**: `try-read-whole-file` (the
helper `ensure-library-loaded!` uses to check whether a library name has
a real `.sld` file on disk, falling back to `record-required-native-
family!` when it doesn't) originally called `read-whole-file` — genuinely
working under `icecreme` (a real native builtin there), but ALWAYS silently
failing under native/`--self-hosted` (unbound there, caught by
`try-read-whole-file`'s own `guard`), which is exactly why native/self-
hosted never reentrant-recompiles an ordinary library's body via THIS
compiler — it relies entirely on native Crystal's own real `import!`
having already defined everything for real (see the previous entry's own
"only thing actually loading a pure-Scheme library's body under `icecreme`"
aside). Switching `try-read-whole-file` to the newly-portable `file-read`
made it genuinely succeed under native/self-hosted too, for the first
time — which sounds like a strict improvement, but instead made
`ensure-library-loaded!` actually attempt to independently reentrant-
recompile every library a self-hosted program imports, including
foundational ones like `(scheme base)` (which does have a real `.sld` on
disk, `modules/scheme/base.sld`) and libraries with compile-time-executed
`defmacro` bodies like `(creme sxql)` — surfacing a real, previously-
unexercised bug where `(creme sxql)`'s `defmacro sxql-select!` (whose
transformer body calls `sxql-compile-tree` when a use of `sxql-select!`
is expanded, not when the macro is defined) ended up unbound
(`differential_examples_spec.cr`'s "22-sxql-report-builder.scm natively
vs. self-hosted-compiled" case). Fixed by keeping the two call sites
separate by design: `try-read-whole-file` still uses `read-whole-file`
(preserving native/self-hosted's original, load-bearing "never reentrant-
recompile, trust native's own import" behavior), while `expand-include-
form` and the library-declaration `include` branch use `file-read`
instead — both are narrow, deliberately-invoked paths (only reached when
a script/library genuinely uses `include`/`include-ci`), so this doesn't
reintroduce the reentrant-recompilation problem for ordinary libraries
that never use `include` at all.

Rationals and complex numbers (`compiler_numeric_tower_spec.scm`, the 7
complex-number cases in `reader_literals_spec.scm`) now work under `icecreme`
too — see "Value/type model"'s `T_RATIONAL`/`T_COMPLEX` entries below for
what was added and exactly what's still NOT covered (plain fixnums are
still not arbitrary-precision).

`import!` applying an only/except/prefix/rename filter now works under
`icecreme` too, including against a NATIVE library (`bootstrap_spec.scm`'s own
`(creme regex)` case) — `import!` (`icecreme/bootstrap.c`'s `bi_import_bang`)
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
   source file — no help for `(creme regex)`, a native (Crystal/icecreme-
   builtin) library with none. Fixed by adding a `library-exports`
   builtin: native Crystal already tracks every registered library's own
   exports internally regardless of whether it's file- or Crystal-based
   (`SchemeLibrary#exports`, `eval/library.cr`), now exposed to Scheme via
   `(creme introspection)`; icecreme has its own, much narrower
   `library-exports` (`icecreme/bootstrap.c`) — a small hardcoded table
   covering just the native libraries this project's own spec suite
   actually needs aliased this way (today: `(creme regex)`), since icecreme has
   no per-library grouping of its own flat global table to draw such a
   list from automatically.

One case remains — `bootstrap_spec.scm`'s "import! copies a library's
bindings into the global env" — a harmless environment artifact under
both `--self-hosted` and `icecreme`, not a bug: each of these two bootstraps
already transitively imports `(creme regex)` for its own compiler's use,
so the test's own initial "is it genuinely unbound?" check is moot there
(see that file's own header comment). Not something this test suite is
trying to fix.

## Embedding

`make -C icecreme lib` builds `libcreme.a`, a static library an external C
program can link against instead of shelling out to the `icecreme` binary —
`examples/libcream/` is a complete, minimal worked example (a host program
registering its own native function and native value as Scheme globals,
then running a plain `.scm` script that uses them). `#include
<icecreme/creme.h>` pulls in the whole public surface (`vm.h`/`value.h`,
`embed.h`'s embedding-convenience API below, `builtin_families.h`, and every
per-family header) in one line.

Minimal call sequence:

```c
#include <icecreme/creme.h>

/* ... define any native functions of your own here, e.g.: */
static Value my_native_fn(VM *vm, Value *args, int nargs) { /* ... */ }

int main(void) {
  creme_runtime_init();                 /* GC_INIT + GMP-via-GC + oom handler,
                                            once per process */
  VM *vm = creme_alloc_vm(0, 0);        /* 0, 0 = default stack/frame caps */
  creme_set_current_vm(vm);

  creme_register_all_builtins(vm);      /* every family this build knows
                                            about; or creme_peek_required_
                                            families + creme_register_
                                            required_builtins for just what
                                            a specific known script needs */

  creme_register_builtin(vm, "my-native-fn", my_native_fn);
  creme_register_global(vm, "my-constant", creme_cstr_value("some value"));

  creme_run_scheme_file(vm, "script.scm");   /* compiles + runs directly,
                                                 via the compiler bundled
                                                 into libcreme.a — no
                                                 --emit-icecreme step, no
                                                 .ice file needed */
  return 0;
}
```

`embed.h` also declares a set of `static inline` value/argument helpers for
writing a native function's own body — `creme_arg_int`/`creme_arg_double`/
`creme_arg_bool`/`creme_arg_cstr`/`creme_arg_bytes`/`creme_arg_vector`
(extract+validate argument N, aborting by name on arity/type mismatch —
`creme_arg_cstr` returns a NUL-terminated copy for handing to a C API,
`creme_arg_bytes` the raw `(pointer, length)` slice with no copy, for
read-only use), `creme_cstr_value`/`creme_bytes_value`/`creme_format_value`
(build a fresh Scheme string from a C string/raw byte slice/`printf`-style
format respectively, no manual length-counting), `creme_list_length`/
`creme_list_to_values`/`creme_list_from_values`/`creme_vector_from_values`
(convert a Scheme list/vector to/from a plain C array of `Value`s), and
`creme_list(vm, a, b, c, ...)` (a macro building a fixed, statically-known
list in one call — `creme_list(vm, a, b, c)` instead of nested
`creme_cons(vm, a, creme_cons(vm, b, creme_cons(vm, c, v_nil())))` — the
element count comes from `sizeof` on a `(Value[]){...}` compound literal,
not a sentinel value or separate count argument, and is safe even when an
argument has side effects, since `sizeof`'s operand is never evaluated
for a non-VLA type). Also `creme_str_lit`/`creme_sym_lit` (zero-copy
`T_STR`/`T_SYM` wraps for a genuine static string literal only — several
`.c` files each hand-rolled this identically before these existed),
`creme_raw_cons` (one cons pair via a raw `GC_MALLOC`, no `VM*` needed —
for a context with none in scope, unlike `creme_cons`/`creme_list*`
above), `creme_alist_pair` (one `(key . value)` alist entry, combine with
`creme_list` to build a whole alist in one expression), and
`creme_bytevector_wrap`/`creme_bytevector_value` (the `Bytevector`
equivalents of `v_str`'s own zero-copy wrap and `creme_bytes_value`'s
copy, respectively — a `Bytevector`, unlike a `T_STR`, needs its own
small struct allocated even for a zero-copy wrap), `creme_arg_blob`
(extracts argument N as a `T_STR` OR `T_BYTEVECTOR`'s raw bytes,
whichever it is — for a builtin accepting a "blob" interchangeably, e.g.
a key that's often raw binary straight from `(creme secure-random)`),
and `creme_dupn` (copies a raw `(pointer, length)` slice into a fresh,
NUL-terminated C string — `creme_arg_cstr`'s own underlying copy, exposed
directly for building a C string out of something that ISN'T argument N
of the current call, e.g. a substring or a struct field). None of these
add anything to `libcreme.a` itself (pure `static inline`/macro, free to
compile away) — icecreme's own
`bi_*` builtins use them directly too, not
just an external embedder — see each one's own doc comment in `embed.h`, and
`examples/libcream/host_demo.c`'s `host_welcome` for a real (2-line) use.

**Boxed-type convenience helpers** (hash-table/treelist/bigdecimal/regex/
sql/actor-ref): each type's own payload struct (`CremeHashTable`/
`RRBNode`/`BigDecimal`/`pcre2_code`/`sqlite3`/`ActorRef`) is private to the
one `.c` file that defines it, so `embed.h` can't reach into any of them
directly — instead, a small generic primitive, `creme_call_global(vm,
name, args, nargs)`, looks up any Scheme-level procedure by name and
applies it (the same lookup-and-call sequence `(hash-table-set! ...)`
itself goes through, just issued from C), and every boxed-type helper
below is built on it: `creme_hash_table_new`/`_set`/`_get`/`_contains`/
`_delete`/`_length`, `creme_treelist_from_values`/`_length`/`_ref`/
`_to_values`, `creme_bigdecimal_from_cstr`/`_from_int`/`_add`/`_sub`/
`_mul`/`_div`/`_to_value`, `creme_regexp_compile`/`_matches`,
`creme_sql_open`/`_close`/`_execute`/`_query`/`_scalar`, and
`creme_actor_send`/`_ref_id`, plus a `creme_<type>_p` tag-check predicate
for each. These cover each type's CORE operations, not full parity with
its whole Scheme-level surface (e.g. treelist has ~60 procedures) — call
`creme_call_global` directly by name for anything beyond what's listed.
Since every one of these only ever calls a name, they work identically
regardless of which `CREME_WITH_<NAME>` macros a build was compiled with
(see "Trimming dependencies" below) — calling e.g. `creme_sql_open`
against a build with `CREME_WITH_SQL=0` just aborts at runtime with a
clear "unbound global" message, the same degrade-gracefully behavior any
other compiled-out family already has.

`creme_run_repl(vm)` drops into an interactive stdin/stdout REPL, by
compiling-and-running `icecreme/repl.scm` (the 2-line `(creme repl)` shim)
through the same bundled-compiler mechanism as `creme_run_scheme_file` —
see the "REPL" section above for why this must always run as source
through the compiler-mode path rather than a separately precompiled
`.ice` (`(creme repl)` needs `read`/`eval`/`interaction-environment`, only
ever backed by the self-hosted compiler's own toolchain setup). For a
precompiled `.ice` file instead of raw source, skip `creme_run_scheme_file`
and call the lower-level `creme_load`/`creme_run_chunk` directly (same
pair the CLI binary itself uses).

**`creme_run_scheme_file`'s `scm_path` is resolved relative to the process's
own current working directory, not the script's own directory or the host
binary's location** — the self-hosted compiler it runs looks up every
library the script imports (`(scheme base)`, etc.) via a repo-root-relative
path (`modules/scheme/*.sld`), the same assumption `icecreme`'s own CLI
already makes everywhere (`main.c`'s `CREME_COMPILER_DRIVER_PATH`, every
`spec/creme/*_spec.scm`). A host embedding this from outside the repo needs
either to run with the repo root as its CWD, or to vendor `modules/` (and
pass a matching relative `scm_path`) alongside its own binary. See
`examples/libcream/`'s own README for a concrete worked example of the
"run from the repo root" case.

A script can call/reference a host-registered name with no special
declaration on the Scheme side — `analyze_var`/`resolve_globals` resolve
any free identifier to an ordinary by-name global reference regardless of
whether anything is bound to it yet, so `(host-greet "world")` compiles and
runs exactly like calling any other global, as long as `host-greet` was
registered (in either order relative to `creme_load`/`creme_load_from_bytes`,
just before the chunk actually runs).

### Trimming dependencies: `CREME_WITH_<NAME>` build flags

`libcreme.a` defaults to the same full dependency set (Boehm GC, PCRE2,
GMP, OpenSSL libcrypto/libssl, libffi, libyaml, sqlite3) the `icecreme`
binary itself links, but 18 native builtin families — each living in its
own `.c` file with a real external-library or standalone-`.o` footprint —
can be compiled out individually via `icecreme/builtin_config.h`'s
`CREME_WITH_<NAME>` macros, passed as Make variables:

| Macro | File | External dependency dropped when off |
|---|---|---|
| `CREME_WITH_SQL` | sql.c | sqlite3 |
| `CREME_WITH_HTTP` | http.c | libssl (+ shares libcrypto) |
| `CREME_WITH_CIPHER` | cipher.c | shares libcrypto |
| `CREME_WITH_PKEY` | pkey.c | shares libcrypto |
| `CREME_WITH_X509` | x509.c | shares libcrypto |
| `CREME_WITH_DIGEST` | digest.c | shares libcrypto |
| `CREME_WITH_SECURE_RANDOM` | secure_random.c | shares libcrypto |
| `CREME_WITH_ACTOR` | actor.c | shares libcrypto |
| `CREME_WITH_FFI` | creme_ffi.c | libffi, dlopen |
| `CREME_WITH_YAML` | yaml.c | libyaml |
| `CREME_WITH_MUX` | mux.c | none extra |
| `CREME_WITH_CSV` | csv.c | none extra |
| `CREME_WITH_TREELIST` | treelist.c | none extra |
| `CREME_WITH_JSON` | json.c | none extra |
| `CREME_WITH_BIGDECIMAL` | bigdecimal.c | none extra |
| `CREME_WITH_TERM` | term.c | none extra |
| `CREME_WITH_PROCESS` | process.c | none extra |
| `CREME_WITH_STRING` | strings.c | none extra |

Each defaults to `1` (included) — `make -C icecreme lib CREME_WITH_SQL=0
CREME_WITH_HTTP=0 ...` drops the listed families entirely: their `.c`
files compile down to an empty translation unit (the external header,
e.g. `<sqlite3.h>`, is never even processed, so its `-dev` package needn't
be installed), and their row disappears from `builtin_families.c`'s
family table, so the linker never pulls in the associated library either.
A script that still `(import (creme sql))` against a build compiled
without it degrades exactly like requesting any other unimplemented
family — silently skipped at registration time, then a normal "unbound
variable" abort the moment it's actually called (see
`builtin_families.c`'s own comment).

Two tiers are **not** gateable this way: 8 zero-external-dependency
families (`cxr`, `complex`, `char`, `process-context`, `math`,
`introspection`, `file`, `env`) live as small function groups inside the
one always-compiled `builtins.c` monolith and stay always-on (nothing to
save by gating them); and 4 families (`regex`, `hash-table`, `bootstrap`,
`lazy`) plus the always-on `base`/`write` pair are hard dependencies of
the self-hosted compiler bundled into `libcreme.a` itself, needed by every
`creme_run_scheme_file`/`creme_run_repl` embedder regardless of what their
own target script imports.

`examples/libcream/` demonstrates the minimal case — its own `Makefile`
builds `libcreme.a` with all 18 gateable families off, since
`host_demo.scm` only needs `(scheme base)`/`(scheme write)`/`(creme
hash-table)` (the last of which is always-on regardless), and trims its
own `LDLIBS` to match (just libm/pthread/GC/GMP/PCRE2 — see that
directory's own README for the `ldd`-confirmed result).

`libcreme.a` is one monolithic archive regardless of which families are
included — a consumer needs the same link-flag set at their own link
stage (static archives carry no transitive flags): see `examples/libcream/
Makefile` for the concrete, working (trimmed) recipe, or `icecreme/
Makefile`'s own `LDLIBS`/pkg-config lines for the canonical, always-
up-to-date full list.

## Profiling

`icecreme --profile <file.ice>` runs the program under two independent samplers
and prints a hot-spot table for each — the same idea as `creme --profile
table <file.scm>`'s `(creme prof-vm)`/`(creme prof-native)` pair (see
src/main.cr's `handle_profile`), ported to this VM's own execution model:

- **Hot Scheme functions** (`icecreme/profiler.c`'s `creme_profiler_tick`, hooked
  into `vm.c`'s dispatch loop at every instruction fetch): a cooperative,
  jittered-interval instruction counter — mirrors
  `src/creme/eval/interpreter.cr`'s `tick_sample` exactly, one sample every
  ~200 instructions on average. Each sample is a `(chunk, instruction index)`
  pair, symbolized as the chunk's own name, `file:line` (via a source line
  now stored per instruction in the `.ice` format — see below), and the
  opcode mnemonic.
- **Hot C frames** (`creme_profiler_start_native`/`_stop_native`): a
  `SIGPROF`+`ITIMER_PROF` sampler capturing a raw `backtrace(3)` every ~1ms,
  symbolized via `dladdr(3)` once the run finishes. Unlike `creme`'s own
  native sampler, this one is **not** expected to show much per-Scheme-
  function detail: `icecreme` runs Scheme-level calls through its own explicit
  `Frame` array (see "Call/upvalue mechanics" below), not C recursion, so a
  C-stack sample mostly reflects genuine C time — GC, builtins, and
  `creme_dispatch`'s own loop — rather than which Scheme function was running.
  It's still useful for catching real C-level cost (e.g. a slow builtin, or
  GC pressure) that the VM-level sampler can't see at all.

Both samplers run for the whole program and cost nothing when `--profile`
isn't passed (guarded by a single `if (vm->profiler.enabled)` check per
instruction, and the `SIGPROF` timer is only installed for the duration of
a profiled run).

**Format note**: icecreme reads "ICE1" (magic `"ICE1"`), the same format the real
Crystal VM's `ChunkSerializer`/`ChunkDeserializer` round-trip — there is no
separate icecreme-specific format/opcode-numbering to keep in sync anymore. A
`.ice` file from before this change (the old "CVM2" format) won't load;
re-run `creme --emit-icecreme` to regenerate it.

## Compatibility with `creme` (the Crystal interpreter)

icecreme executes the exact same compiled bytecode `creme` does — there's no
separate compiler, no separate language surface — but it implements a
strict *subset* of the real VM's opcodes, builtins, and value model. A
script fails to `--emit-icecreme` (or aborts at icecreme runtime) the moment it needs
something outside that subset — there is no partial/degraded fallback path.
This section is the actual, current boundary — regenerate it by re-running
the checks below rather than trusting it blindly if this file feels old
again.

### Opcodes: 119 of 119 — full parity

`icecreme/opcodes.h`'s enum now IS `Creme::Op`'s own enum, in the exact same
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
`dispatch_call`/`creme_apply`, so a case-lambda called directly, via
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
which icecreme has no equivalent of at all (no continuation value), so they're
unsupported regardless of opcode coverage. This is unrelated to guard's own
unwinding (see below) — `call/cc` needs genuinely re-entrant continuations,
which is a different, harder problem `setjmp`/`longjmp` alone doesn't solve.

### Guard/parameterize implementation

Unlike every other op, `guard`'s three opcodes don't fit the ordinary
"read operands, write a register, NEXT()" shape — an error raised
arbitrarily deep (including through `creme_apply`'s own reentrant C
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
- `creme_abort` (every runtime error in this VM funnels through it) checks
  a process-global "current VM" (mirrors `profiler.c`'s own
  `g_profiled_vm` pattern, since `creme_abort`'s signature has no room for a
  `VM*` parameter across its ~100 existing call sites) — if a handler is
  installed, it builds a condition record and calls `creme_raise_condition`
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

icecreme has no runtime library/import machinery (see "Deliberate cuts" below)
— it hand-registers a flat, ungrouped set of global builtins in C, spread
across these files:

| File | Backs | Count | Notable names |
|---|---|---|---|
| `builtins.c` | most of `(scheme base)`/`(scheme cxr)`/`(scheme complex)`, a little of `(scheme char)`/`(scheme write)`/`(scheme process-context)`/`(scheme lazy)`, all of `(creme math)`/`(creme introspection)`/`(creme time)` | 190+ | predicates, `car`/`cdr`/`set-car!`/`set-cdr!`/the full `caar`..`cddddr` family/`cons`/list ops, `map`/`for-each`/`filter`/`apply`, `string-append`/`substring`/`string-copy`/`string->number` (now with an optional radix arg, needed by `#b`/`#o`/`#x`-prefixed literals)/etc., `vector`/`vector->list`, `vector-ref`/`-set!`/`-length`, `string-ref`/`-set!`, `make-bytevector`/`bytevector`/`bytevector-length`/`bytevector?`/`-u8-ref`/`-u8-set!`, `force`/`promise?`, `error`, `raise`, `error-object?`/`-message`/`-irritants`, `make-parameter`, `read-line`, `read-whole-file`, `get-environment-variable`, `set-environment-variable!` (`(creme env)`'s own mutator, not just R7RS's read-only `get-environment-variable` — needed so an icecreme-run process can pass a flag down to a subprocess it spawns via `process-run`, which inherits environ automatically), `+`/`-`/`*`/`/`/`<`/`>`/`<=`/`>=`/`=` (now genuinely promoting through int/rational/float/complex — see "numeric tower" below), `quotient`/`remainder`/`modulo`, `string-for-each`, `char-downcase`/`-upcase`, `char<?`/`>?`/`<=?`/`>=?`, `write` (a real quoted/escaped external representation — `display`'s own `print_value` extended, not a second printer; `+inf.0`/`-inf.0`/`+nan.0` handled specially there too, needed once anything re-serializes a float this VM itself produced), `write-char`, `exit`, `gensym`, `flonum->bits`/`bits->flonum` (an exact IEEE754 bit-level reinterpret — needed by `(creme bytecode)`'s own ICE1 float-constant serialization, so any chunk with a float literal needed this), `dynamic-wind`, `call/cc`/`call-with-current-continuation` (escape-only — see "Compiler mode" above), `rational?`/`numerator`/`denominator` (int/rational only), `make-rectangular`/`make-polar`/`real-part`/`imag-part`/`magnitude`/`angle` (`(scheme complex)`'s complete surface — see "numeric tower" below), `open-input-file`/`open-output-file`/`open-binary-input-file`/`open-binary-output-file`/`call-with-input-file`/`call-with-output-file`/`with-input-from-file`/`with-output-to-file`/`file-exists?` (`(scheme file)`'s R7RS port surface, plus `(creme file)`'s own `file-append`/`file-lines`/`file-size`/`current-directory` — see this section's own note further down on the two `with-*` builtins specifically) |
| `mux.c` | `(creme mux)` | 13 | `mux-router`, `mux-get!`/`post!`/etc., `mux-listen!`, `mux-close!` — real HTTP via poll(2) + picohttpparser; `mux-listen!`'s "pool" option picks inline dispatch (`#f`, the default) or a growable SO_REUSEPORT worker pool (`#t`/an integer max) with no cross-thread handoff |
| `sql.c` | `(creme sql)` | 6 | `sql-open`, `sql-execute`, `sql-query`, `sql-scalar` — real SQLite via the C API |
| `hashtable.c` | `(creme hash-table)` (full — every name the `.sld` re-exports) | 9 | `make-hash-table`, `hash-table-set!`/`ref`/`contains?`/`delete!`/`keys`/`values`/`->alist` — `hash-table-ref`'s own default arg may be a plain value OR a thunk (only applied if it's actually callable), matching native's own contract |
| `strings.c` | `(creme string)` + `(creme format)` | 16 | `string-upcase`/`downcase`/`trim`/`split`/`join`/`replace`/`pad`/etc., `format` |
| `bootstrap.c` | `(creme bootstrap)` (narrow — see "REPL"/"Compiler mode" above) + a slice of `(scheme file)`/`(creme file)` | 8 | `load-chunk-bytes`, `import!`, `expand-if-macro`, `read-whole-file`, `icecreme-target-path`, `file-read` (same function as `read-whole-file`, registered under both names), `file-write`, `delete-file` — the rest of `(scheme file)`/`(creme file)` (now a full port) lives in `builtins.c`'s own row above |
| `regex.c` | `(creme regex)` (very narrow — see "REPL" above) | 2 | `regexp`, `regexp-matches?` |
| `process.c` | `(creme process)` (narrow — `process-run` and `sleep-ms!`) | 2 | `process-run` — real POSIX fork/pipe/execvp/waitpid, matching native Crystal's exact `(cmd args) -> (stdout stderr exit-code success?)` contract; exists so spec/creme/main_spec.scm (the one entry point for running every spec/creme spec file and reporting one combined total) spawns each spec file as its own genuinely separate OS process the same way whether it's driven natively or reentrantly under `./icecreme/icecreme spec/creme/main_spec.scm` itself. `sleep-ms!` — real `nanosleep(2)` on an exact non-negative integer count of milliseconds, matching native's own `sleep-ms!` contract; icecreme had no timer primitive of any kind before this, needed by `(creme raft-scheme)`'s election/heartbeat tickers (an icecreme actor is a real OS thread, so blocking here only blocks that one actor, same as native's fiber-yielding `sleep!` never blocking the whole process) |
| `digest.c` | `(creme digest)` | 10 | `digest-md5`/`-sha1`/`-sha256`/`-sha384`/`-sha512` (hex digest strings, via OpenSSL's `EVP_Digest` — reuses the `-lcrypto` link already added for `(creme actor)`'s own HMAC handshake), `hmac-sha256`/`-sha384`/`-sha512` (via OpenSSL's `HMAC()`, the exact one-shot call `actor.c`'s own handshake already uses), `base64-encode`/`-decode` (a small hand-rolled codec — OpenSSL's own `EVP_EncodeBlock`/`DecodeBlock` don't raise cleanly on invalid input the way native's own `Base64.decode_string` does) |
| `secure_random.c` | `(creme secure-random)` | 3 | `secure-random-bytes`/`-hex`/`-base64` — OpenSSL's `RAND_bytes` (the same OS-entropy CSPRNG `actor.c`'s own handshake nonces already use), deliberately separate from `(creme random)`'s plain splitmix64 PRNG (`builtins.c`); hex/base64 encoding are small hand-rolled encode-only loops, matching `digest.c`'s own per-file self-contained style |
| `cipher.c` | `(creme cipher)` | 4 | `aes-256-gcm-encrypt`/`-decrypt`/`-random-key`/`-random-nonce` — the full OpenSSL EVP AEAD sequence (`EVP_CIPHER_CTX_ctrl` for GCM IV length/tag get/set) driven directly in C, where it's simply part of `<openssl/evp.h>` (unlike native, which has to reopen Crystal's own `OpenSSL::LibCrypto` binding to reach the one entry point its high-level `OpenSSL::Cipher` wrapper never exposes); deliberately scoped to AES-256-GCM only, matching `(creme rfc8439)`'s own AEAD-first, single-algorithm cut |
| `pkey.c` | `(creme pkey)` | 11 | `rsa-generate-key`/`ec-generate-key`/`pkey?`/`-private?`/`-type`/`-public-key`/`->pem`/`pem->pkey`/`pkey-sign`/`-verify`/`rsa-encrypt`/`-decrypt` — the full EVP_PKEY/RSA/EC_KEY/PEM C API driven directly, where (unlike native, which has to reopen Crystal's own `OpenSSL::LibCrypto` binding since that stdlib has no `OpenSSL::PKey` class hierarchy at all) it's simply part of `<openssl/evp.h>`/`<openssl/rsa.h>`/`<openssl/ec.h>`/`<openssl/pem.h>`; a `BOX_KIND_PKEY` handle holds the key's own PEM text, never a live native key pointer, reconstructing a transient one per operation |
| `x509.c` | `(creme x509)` | 11 | `x509-self-signed-certificate`/`-create-csr`/`-sign-csr`/`-cert->pem`/`pem->x509-cert`/`-cert-subject`/`-issuer`/`-public-key`/`-not-before`/`-not-after`/`-verify-chain` — the full X509/X509_REQ/X509_STORE C API, `not-before`/`-after` converted from `ASN1_TIME` to epoch seconds via a self-contained civil-calendar calculation (Howard Hinnant's `days_from_civil`) rather than `timegm(3)`, whose declaration/feature-test-macro requirements vary across glibc/musl/BSD libc; every self-signed cert gets a `basicConstraints CA:TRUE` extension via `X509V3_EXT_nconf_nid`, required for `x509-verify-chain` to accept it as a trust anchor at all |
| `json.c` | `(creme json)` | 2 | `json-read`/`json-write` — a small hand-rolled recursive-descent JSON parser/writer; matches native's own conventions exactly (array → vector, object → alist of `(string . value)` pairs usable with `assoc`/`cdr`/`car`, an empty object conflates with JSON null) |
| `yaml.c` | `(creme yaml)` | 2 | `yaml-read`/`yaml-write` — unlike `json.c` above, wraps libyaml directly rather than hand-rolling a parser/emitter (a full YAML 1.1 implementation would be a much bigger lift than JSON's recursive descent); matches native's own conventions (mapping → alist, sequence → vector, an empty mapping conflates with YAML null) and its own libyaml-backed `YAML::Any`/`YAML::Builder` output closely, down to plain-scalar core-schema type resolution (bool words, `0x`/`0o`/octal/underscored ints, `.inf`/`.nan`) — one deliberate narrow divergence: a mapping KEY is always kept as its literal scalar text here, never run through that same typed resolution the way a value is on the native side (see the file's own header comment) |
| `bigdecimal.c` | `(creme bigdecimal)` | 14 | `bigdecimal-add`/`-sub`/`-mul`/`-div`/`-neg`/`-compare`/`=?`/`<?`/`>?`/`-zero?`, `string->bigdecimal`/`integer->bigdecimal`/`bigdecimal->string`/`bigdecimal?` — a standalone boxed decimal type (like native, never hooked into the numeric tower), backed by an integer mantissa + a decimal scale on top of GMP's `mpz_t` (Java-`BigDecimal`-style, exact by construction — deliberately NOT GMP's own `mpf_t`, which is arbitrary-precision BINARY float, not exact base-10 decimal) |
| `http.c` | `(creme http)` | 7 | `http-get`/`-head`/`-delete`/`-post`/`-put`/`-patch`/`-request` — an HTTP/1.1 CLIENT, raw `getaddrinfo`/`connect`/`read`/`write` (the same pattern `(creme actor)`'s own `dial()` uses); always sends `Connection: close` and drains the response until the peer closes the socket, decoding a chunked `Transfer-Encoding` body as a second pass if the server ever sends one. HTTPS/TLS is real (libssl, linked alongside the libcrypto this project already had for `(creme actor)`'s HMAC handshake and `(creme digest)`) — always full certificate + hostname verification (`SSL_VERIFY_PEER` against the system trust store, plus `SSL_set1_host`; no flag anywhere disables either), no separate opt-in needed, an `https://` URL just works |
| `csv.c` | `(creme csv)` | 8 | `csv-read`/`-write`/`-read-headers`/`-write-headers` (bulk) and `csv-reader-open`/`-read!`/`-writer-open`/`-row!` (streaming, over a Port) — a self-contained RFC4180-ish parser/writer, not a port of native's own chunked-IO-optimized implementation |
| `treelist.c` | `(creme treelist)` | — | a full RRB (Relaxed Radix Balanced) tree, matching native's own structure-sharing behavior, not just an array-backed stand-in |
| `actor.c` | `(creme actor)` | — | real OS-thread actors, multiple `'local` nodes, and real `'tcp`/`'unix` distribution with an HMAC-SHA256 handshake — see the fuller description just below this table, and `actor.c`'s own header comment |

`+`/`-`/`*`/`/`/`<`/`>`/`<=`/`>=`/`=` didn't used to be builtins here — a
program the real analyzer compiles never needs them as such (its
`PRIM_OPS` table, `ast.cr`, already folds a 2-arg call to one of these
names straight into a fused op), but the self-hosted compiler doesn't do
that fusion (see "REPL" above), so they're real global procedures now
too — a 3+-arg or non-fused call to them works either way.

`(scheme inexact)`, `(scheme case-lambda)`, `(scheme repl)`, and
`(scheme r5rs)` all turn out to ALREADY work fully under icecreme — with no
new C code at all — once actually checked (they were previously
mis-listed below as unported): `(scheme inexact)`'s entire surface
(`sin`/`cos`/`tan`/`asin`/`acos`/`atan`/`exp`/`log`/`sqrt`/`nan?`/
`infinite?`/`finite?`) is already in `builtins.c`'s own table above;
`case-lambda` is a compiler-recognized special form, and icecreme's own
`T_CASE_CLOSURE`/`CaseClosure` dispatch already handles it (see
`spec/creme/vm_spec.scm`'s own case-lambda case); `(scheme repl)`'s
`interaction-environment` and `(scheme r5rs)`'s `null-environment`/
`scheme-report-environment`, plus `(scheme eval)`'s `environment`/
`eval`'s 2-arg form, are now genuinely isolated per environment — see
"environment/eval" below for the full design (this used to say they
were all trivial, non-isolating stubs; no longer true). `spec/creme/
inexact_spec.scm` and `spec/creme/environments_spec.scm` both already
cover this.
`(creme random)` was similarly already fully ported straight into
`builtins.c` (`random-real`/`-integer`/`-seed!`/`-choice`/`-shuffle`, a
splitmix64 generator — deliberately NOT bit-for-bit compatible with
Crystal's own PCG-based `Random`, see `spec/creme/random_spec.scm`'s own
header comment) but had likewise been left off this list.

Every other `(scheme ...)` library (`process-context` beyond
`get-environment-variable`/`exit`, `cxr`) and every other `(creme ...)`
FFI library (`tui`, `rfc8439`, `prof-native`, `prof-vm`, `raft`, `jose`)
has **no** icecreme-native counterpart at all — a script that calls into one
won't resolve at icecreme load/run time. (`(creme process)` is now a partial
exception — `process-run` and `sleep-ms!`, see `process.c`'s own row
above.) `raft` here means the FFI *binding* over the `threez/raft.cr`
shard specifically (`(creme raft)`/`(creme raft-machine)`) — that one
genuinely has no icecreme counterpart. `(creme raft-scheme)` is a separate,
from-scratch, pure-Scheme Raft implementation (actors + SQLite, no FFI)
that DOES run under icecreme — see `modules/creme/raft-scheme/core.scm`'s own
header comment and `spec/creme/raft_scheme_spec.scm`.
`(creme time)` is now a FULL port (`builtins.c`): `current-time`/
`time-difference` already existed (see the header comment right above
`bi_current_time`); `time-add`/`time-year`/`time-month`/`time-day`/
`time-hour`/`time-minute`/`time-second`/`time->string`/`string->time`
are new, all reading/writing a Unix-epoch-seconds float as UTC via
`gmtime_r`, `strftime`/`strptime` (the format strings this project's own
spec suite uses — `%Y-%m-%d %H:%M:%S` etc. — are already
strftime-compatible, so no separate directive-translation layer was
needed), and a hand-rolled `days_from_civil`/`tm_to_epoch_utc` pair (a
portable `timegm(3)` stand-in — glibc and FreeBSD/Darwin libc gate the
real `timegm` behind different, mutually-incompatible feature-test
macros, and `strptime`'s own `_XOPEN_SOURCE` requirement on glibc rules
out satisfying both with one `#define`).

`(creme actor)` (`actor.c`) is now a FULL port — real OS-thread actors
(one pthread + one independent copied-globals VM per `spawn`, not a
green-thread scheduler; see `actor.c`'s own header comment for why),
`spawn`/`send!`/`receive!`/`self`/`monitor`/`register!`/`whereis`/
`actor-ref-id`/`down?`/`down-ref`/`down-reason`, multiple independent
`start-node 'local` "nodes" in one process, and real
`start-node 'tcp`/`'unix` distribution with a byte-identical HMAC-SHA256
handshake + `[type:u8][length:u32 BE][body]` frame format to native —
the one deliberate deviation from native is the wire *payload* encoding,
a minimal native datum reader/writer built for this (matching native's
own `("@record" "<type>" field...)`/`"@ref:<uri>"` shape, not
byte-identical text, since icecreme has no native C-level Scheme reader to
reuse) — icecreme-to-icecreme distribution works correctly, exact wire interop
with a real native Crystal node is not a goal of this port. See
`spec/creme/actor_spec.scm` for the full local/`'local`-node/TCP/Unix
coverage. `(scheme complex)` USED to be entirely
unsupported (no `T_COMPLEX` value tag) but now has real support — see
"Value/type model" below and this section's own `make-rectangular`/
`make-polar`/`real-part`/`imag-part`/`magnitude`/
`angle` entry in `builtins.c`'s row above (its complete native surface,
not a subset).

`(creme math)` and `(creme introspection)` are now both FULL ports:
`(creme math)`'s complete surface (`sin`/`cos`/`tan`/`asin`/`acos`/
`atan`/`atan2`/`exp`/`log`/`log2`/`log10`/`pow`/`hypot`/`pi`/`e`, plus
`flonum->bits`/`bits->flonum`) is already in `builtins.c`'s own table
above; `(creme introspection)`'s `macro?` (recognizes icecreme's own
`T_MACRO` tag) and `record-fields` (generic positional reflection over
any `define-record-type` instance's `SchemeRecord` — no per-type
dispatch, same as native) are new, alongside the pre-existing `gensym`/
`runtime`/`bound-names`/`library-exports`. `(scheme file)`/`(creme file)`
is now a FULL port, split across `bootstrap.c` (`file-read`/`file-write`/
`delete-file`) and `builtins.c` (`file-exists?`/`open-input-file`/
`open-output-file`/`open-binary-input-file`/`open-binary-output-file`/
`call-with-input-file`/`call-with-output-file`/`with-input-from-file`/
`with-output-to-file`/`file-append`/`file-lines`/`file-size`/
`current-directory`) -- `with-input-from-file`/`with-output-to-file`
needed a genuinely new piece first: `(current-input-port)`/`(current-
output-port)` used to be hardcoded, non-redirectable sentinels (every
port-defaulting builtin read straight through them), then (in a later
pass) a mutable-but-plain per-thread C global indirection; they're now
genuine `T_PARAMETER` values (`vm->current_output_param`/
`vm->current_input_param`, one pair per VM instance — see `vm.h`'s own
VM-struct doc comment and `builtins.c`'s `creme_init_current_ports`), so
`parameterize` can genuinely retarget them (this used to abort with
"parameterize: expected a parameter object"). Every port-defaulting
builtin still reads through the SAME two names it always did
(`g_current_output_port`/`g_current_input_port`), now macros expanding
to `vm->current_output_param->value.as.port`/the input equivalent, so
no other call site needed to change. `with-input-from-file`/
`with-output-to-file` reuse the SAME dynamic-wind unwind-stack mechanism
`dynamic-wind` itself uses (see `bi_with_input_from_file`'s own comment)
so the previous port is restored even if the redirected thunk escapes
via an error. An actor spawn (`creme_new_child_vm`) gives its own VM a
FRESH pair rather than inheriting the parent's via that function's own
wholesale `globals` memcpy — sharing one Parameter across actor threads
would let one actor's `parameterize`/`with-output-to-file` redirect a
sibling's default port, a genuine cross-thread bug, not just wrong
scoping. `(scheme
read)`'s `read`/
`open-input-string`/`eof-object` and `(scheme eval)`'s `eval` also have
no NATIVE (C) counterpart in this table at all, but ARE available when
running under icecreme's own "compiler mode" (see below) -- `icecreme/compiler-
run.scm` defines all four itself, in Scheme, reusing the self-hosted
reader/compiler already loaded there rather than adding a second parser/
evaluator in C (see that file's own comments on both).

A batch of smaller R7RS-completeness fixes landed together (`builtins.c`
unless noted): `eqv?`/`equal?` now compare floats by bit pattern, not
`==`, so `(eqv? 0.0 -0.0)` is correctly `#f` (`vm.c`'s `creme_eqv`);
`equal?` now terminates on circular structure (an ancestor-tracking
`EqualSeen` stack, same idea as `guard`'s own unwind mechanism, just for
comparison instead of control flow) and has a real byte-compare case
for bytevectors (previously pointer-identity only, via the `eqv?`
fallback); `number->string`'s optional radix argument (2–36, exact
integers only, matching native) is honored instead of silently ignored;
`error-object-message` returns the bare message instead of
message-plus-irritants concatenated; `read-error?`/`file-error?` exist
as honest always-`#f` stubs (icecreme has one unified condition shape, not
native's distinct read-error/file-error record types); `list-set!`/
`list-copy`/`make-list`/`square`/`make-promise` are new, and `member`/
`assoc` accept an optional 3rd comparison-predicate argument;
`vector->list` accepts optional start/end args; `write` now emits
`|...|`-escaped symbols the same way native does (`needs_pipe_escape?`,
mirrored from `values.cr`); `write-simple` is `write` under another
name (its contract — never emit datum labels — is exactly what `write`
already does), while `write-shared` is a genuine, independent two-pass
implementation (`write_value_shared`/`share_mark`) that detects
sharing/cycles via a whole-traversal seen-set and emits real `#n=`/`#n#`
datum labels — deliberately NOT an alias to `write`, which would
infinite-loop on a circular argument since `write_value`'s own `T_PAIR`
case has no cycle guard; `flush-output-port` is a real `fflush(3)` for
the two buffered-`FILE*`-backed port kinds (stdout, output files) and a
no-op for the synchronous-buffer `PORT_KIND_OUTPUT_STRING`; `read-string`
mirrors native's own `IO#read_fully?`-based all-or-nothing contract (all
`k` characters available or an eof-object — not R7RS's more literal
"up to k, or as many as available" wording, matched to native instead
of diverging from it on this edge case).

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
works" under icecreme as long as everything it bottoms out in is covered by the
tables above. This is exactly how `competition/scheme/demo-todo/app.scm`'s
`(creme dao)`/`(creme memoize)`/`(creme for)`/`(creme surf)`/`(creme
html)`/`(creme css)`/`(creme path)`/`(creme json-builder)` all work end to
end with zero library-specific icecreme code — only the FFI libraries they
ultimately call into (`sql`, `mux`, `string`) needed a native module.
`(creme prof)` is the one `.sld` that can't work this way — it's a pure
re-export of `prof-native`/`prof-vm`, neither of which has an icecreme
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
  `creme_apply` pick the first whose arity accepts the call's argument
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
  `dispatch_call`/`creme_apply` recognize `T_RECORD_CALLABLE` directly,
  since icecreme's plain `BuiltinFn` function pointer has nowhere to stash a
  captured record type/field index the way a real closure can — see
  `vm.c`'s `call_record_callable`), and `T_PARAMETER` (`make-parameter`'s
  own value — current value + optional converter procedure, mirrors
  `SchemeParameter` exactly; calling it with 0 args returns its current
  value, same `dispatch_call`/`creme_apply` recognition pattern as
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

Even where opcodes overlap, icecreme's *execution model* deliberately mirrors
`src/creme/eval/vm.cr`, not just its instruction set: one shared,
fixed-capacity register stack + explicit call-frame array (a trampolined
dispatch loop, not C recursion); non-tail `Call` pushes a new register
window, `TailCall*` reuses the current frame's window in place; upvalues
are open (pointing directly into the stack) while their owning frame is
live, and close (copy out) when it returns. This is why the native
profiler mostly can't see per-Scheme-function detail (see "Profiling"
above) — Scheme-level calls never become real C stack frames.

### Datum labels (`#n=`/`#n#`) in a precompiled `--emit-icecreme` program

A quoted literal using R7RS's datum-label syntax (`'#0=(1 2 . #0#)`, a
genuine cycle, or `'(#0=(a b) #0#)`, non-cyclic sharing) now round-trips
correctly through `--emit-icecreme` + `icecreme` — both the compiled-literal
identity (`eq?`-preserving, not just structurally-equal duplicates) and,
for a genuine cycle, without hanging. This spans three files:

- **`src/creme/compile/chunk_serializer.cr`**: `write_datum` used to
  recurse unconditionally over a literal's own pair/vector structure —
  a genuinely circular one would never terminate, a real (previously
  undiscovered) crash/hang bug, not just "unsupported". Now does a
  cheap first pass (`count_datum_visits`, an ancestor-tracking walk —
  the same technique `creme_equal`/`write_value_shared` already use, just
  ported to Crystal) counting how many times each distinct pair/vector
  pointer (by `object_id`, genuine reference identity) is reached;
  anything reached ≥2 times — whether via a real cycle or separate,
  non-cyclic sharing — gets a new `TAG_LABEL_DEF`/`TAG_LABEL_REF` wire
  tag pair (13/14) the same way `write-shared`'s own `#n=`/`#n#`
  notation works: `TAG_LABEL_DEF` precedes that value's own ordinary
  tag+bytes the FIRST time it's written, `TAG_LABEL_REF` stands alone
  for every later encounter. An ordinary, unshared literal serializes to
  byte-identical output as before — these tags are strictly additive.
- **`icecreme/loader.c`**: `read_datum` (renamed to `read_datum_rec` for the
  recursive path, with a thin `read_datum` wrapper that resets the
  per-top-level-datum label table — R7RS: "a datum label's scope is
  only the outermost datum it appears in") now recognizes both new
  tags. `TAG_PAIR`/`TAG_VECTOR`'s own container is registered under its
  label BEFORE its car/cdr/items are read — the same placeholder-then-
  patch order the code already used for building the container itself,
  so a `TAG_LABEL_REF` appearing inside that same container's own
  contents (a genuine cycle) correctly resolves to the already-
  allocated pointer instead of needing a second pass.
- **Two genuinely separate, incidental bugs found and fixed along the
  way** (both pre-existing, both independent of datum labels
  specifically — reachable by any runtime-built cycle too, e.g. via
  `set-cdr!`/`vector-set!`, not just a literal): native Crystal's own
  `Cons`/`SchemeVector#write_seq` (`src/creme/value/values.cr`) had no
  cycle guard at all and hung forever printing a circular value —
  triggered unconditionally by `emit_load_literal`'s own profiler-
  sample tagging (`bytecode_compiler.cr`) for EVERY compiled literal,
  meaning a circular literal hung at compile time in plain `./bin/creme`
  too, before ever reaching `--emit-icecreme`'s own serializer. Fixed with an
  ancestor-tracking guard (`Creme.write_seq_ancestor?`/
  `mark_write_seq_ancestor`/`unmark_write_seq_ancestor`, module-scoped
  rather than per-`SchemeBaseValue`-including-class, so a cycle spanning
  both a pair AND a vector is still caught). Separately,
  `Creme.proper_list?` (`src/creme/helpers.cr`, backing `list?`) also
  had no cycle guard — R7RS requires `list?` to return `#f` (not hang)
  on a circular list — fixed with Floyd's tortoise-and-hare. `icecreme`'s own
  `list?` builtin (`icecreme/builtins.c`) had the identical bug, fixed the
  same way.

**icecreme's own RUNTIME `read`** (compiler-mode/REPL only, backed by the
self-hosted `modules/creme/compiler/reader.sld`) USED to be a separate
gap from the wire-format work above — it couldn't parse `#n=`/`#n#`
syntax at all, a deliberate, deferred non-goal per that file's own
header comment. Now fixed there too (`parse-datum-label`, a mutable
`current-datum-labels` alist reset once per TOP-LEVEL datum — R7RS: "a
datum label's scope is only the outermost datum it appears in" — by a
new `read-toplevel-datum` wrapper only `read-program`'s own loop calls,
never nested/recursive `read-datum` calls, so labels stay visible
across an entire outermost datum's own nested structure but not across
separate top-level forms): genuine cycles through PAIRS use the same
placeholder-then-patch idea as the C loader (a fresh, empty pair bound
to the label BEFORE recursing into its own contents, `set-car!`/
`set-cdr!`-patched to match once known); a labeled non-pair datum
(symbol/number/string/vector/...) is simply bound to its own value
directly, since none of those can participate in a genuine cycle
through themselves the way a pair's own car/cdr can — except a vector,
which specifically means a self-referential VECTOR literal
(`#0=#(#0#)`) is the one remaining unsupported case (no test in this
project's own spec suite needs one). Since this reader is shared by
both `--self-hosted` and `icecreme/icecreme`, the fix applies to both.

### `environment`/`eval`'s 2-arg form/`null-environment`: real per-environment isolation

`(scheme eval)`'s `environment`/`eval` (2-arg form) and `(scheme r5rs)`'s
`null-environment` used to be non-isolating stubs — `eval` ignored
whatever environment specifier it was given entirely, always
evaluating against the one real global table, since icecreme's `VM` struct
has exactly one flat `globals[]` array. They're now genuinely isolated,
without touching that flat-table architecture for the *whole running
program* at all: an "environment" is just a genuinely separate,
completely independent `VM` (`creme_new_empty_vm`, `vm.c`) — no call
stack/frames actually used, just its own `globals[]` — wrapped as an
opaque `T_BOX(BOX_KIND_ENVIRONMENT)` value so Scheme can hold and pass
it around. Three new `icecreme/bootstrap.c` builtins expose this:
`make-environment` (a fresh, empty one), `environment-copy-global!`
(copies a name's current value from the CALLING vm into a target
environment's own table under a possibly-different name — a quiet
no-op, not an abort, if the source name isn't bound at all, since a
library's own export list can legitimately include a *syntax* keyword
like `and`/`or` that icecreme never binds as a global to begin with — those
are handled by the compiler directly, independent of environment), and
`load-chunk-bytes-into` (loads+runs compiled bytecode against a GIVEN
environment's table instead of always the currently-running one — what
makes `eval`'s 2-arg form actually target the right place).
`icecreme/compiler-run.scm` builds on these:

- `(environment import-set ...)`: a fresh, empty environment populated
  by copying exactly each import-set's own resolved bindings —
  `modules/creme/compiler/compiler.sld`'s new
  `import-set-resolved-bindings` (reusing the already-existing
  `library-export-alist`) computes the real only/except/prefix/rename
  resolution, a genuine filter/rename over a library's own export
  alist — distinct from (and more complete than) `import-set-alias-
  defines`, which only ever computed the handful of *extra* aliases a
  top-level `(import ...)` needs beyond what native `import!`/
  `ensure-libraries-loaded!` already brings in for free.
- `(null-environment version)`: `make-environment` with nothing
  imported at all. Correctly "only syntax, no procedures" for free —
  icecreme has no global bindings for special forms in the first place (they
  compile directly, independent of any environment), so an empty table
  already IS exactly that.
- `(scheme-report-environment version)`/`(interaction-environment)`:
  both wrap the CURRENTLY RUNNING vm directly (`current-environment`,
  `icecreme/bootstrap.c`) rather than building a fresh one — deliberately
  mirroring native's own equally-deliberate non-isolation for these two
  specifically (`r5rs.cr`'s own comment: "wraps `@base_env`... not any
  Scheme-defined additions").
- `eval`'s 2-arg form: `load-chunk-bytes-into` the given environment
  instead of `load-chunk-bytes` into the current one. Compiling the
  form itself is unaffected either way (`compile-program` produces
  plain bytecode bytes, independent of any VM); only the LOAD step,
  resolving `GetGlobal`/`DefGlobal` operands, needs to know which table
  to target.

One easy trap avoided: `creme_register_required_builtins` (`main.c`)
always registers the full base+write builtin set the FIRST time it's
called for a given VM, regardless of what's actually needed — correct
for the one real top-level VM (which always needs `base`/`write`
eventually anyway) but exactly wrong for a fresh environment VM, which
`load-chunk-bytes-into` also runs through: `creme_new_empty_vm` pre-marks
its own VM as `base_write_registered` already-done, so an environment
never silently regains `+`/every other base builtin the instant
anything is `eval`'d into it.

**Fused opcodes and `except`/`only`, fixed**: fused opcodes (`+`/`-`/`*`/
`car`/`cdr`/... in CALL position — `Add`/`Sub`/`Cxr`/etc, baked in at
compile time identically regardless of backend) never consult ANY
environment's global table at all — only a bare (non-called) reference
to one of these names does a real lookup. So excluding e.g. `+` from an
environment used to leave `(eval '+ env)` correctly failing while
`(eval '(+ 1 2) env)` still silently worked there, since the fused `Add`
opcode never checked which environment it was running in. Fixed without
giving up fusion generally: a new `environment-bound?` builtin
(`icecreme/bootstrap.c`, mirrors `environment-copy-global!`'s own bound check)
lets `eval` (`icecreme/compiler-run.scm`) ask, for the specific target
environment, which of `compiler.sld`'s `fusable-prim-names` it actually
lacks; `eval` then calls the newly-exported `mark-redefined!` for each
such name — the SAME mechanism `compiler.sld` already uses to stop
fusing a primitive a top-level `(define + ...)` has shadowed — for the
duration of compiling just that one form (`dynamic-wind`-protected, then
`unmark-redefined!` reverts it), forcing an ordinary `GetGlobal`+`Call`
that genuinely fails against that environment, same as a bare reference
already did. Cxr names (`cadr`, etc.) aren't covered — they're a
pattern-recognized family, not enumerable from a fixed table — but
`fused-prim-table`'s ~24 named entries (`+`/`-`/`*`/comparisons/`cons`/
`vector-ref`/`vector-set!`/... ) all are. See `spec/creme/r7rs/
ch05_program_structure_spec.scm`'s own "except" case, now passing
unconditionally, and its own header comment.

**A library body genuinely seeing only what it explicitly imports,
fixed — without a separate VM per library.** icecreme's global table is one
flat, whole-program-wide `globals[]` array with no runtime notion of
"which library owns this name" at all — every top-level `define`,
whether from the user's own script or any imported library's `(begin
...)` body, lands in the exact same namespace. The obvious-looking fix
— give every library its own VM (icecreme already has the machinery,
`creme_new_empty_vm`/`make-environment`, built for `environment`/`eval`)
— was tried in design and **rejected**: icecreme bakes every `GetGlobal`/
`DefGlobal` operand into a raw array index into one *specific* VM's
table, once, at chunk-load time (`resolve_globals`, `loader.c`). A
library's own closure (say, `sxql-run` calling sibling helper
`sxql-yield`, both defined in the same library) is permanently tied to
whichever VM it was loaded against; if that closure were later
*exported* and called from a *different* VM's dispatch context (the
importer's own VM), its internal `GetGlobal` for `sxql-yield` would
resolve against the **caller's** table, not the one it was actually
compiled against — silently misresolving. Native Crystal's `Env`
doesn't have this problem because a closure carries its own defining
`Env` *by reference* (parent-chained lookup, resolved by name at call
time); icecreme's baked-integer-index model has no equivalent notion of "this
closure's home globals table," and giving it one would mean threading a
per-frame "which VM do my global ops resolve against" tag through the
calling convention itself — a deep, invasive dispatch-loop change, out
of scope here.

Fixed instead purely at **compile time**, in the self-hosted compiler
(`modules/creme/compiler/compiler.sld`), keeping icecreme's runtime
completely unchanged (one flat table, ordinary `GetGlobal`/`DefGlobal`,
no new VM struct, no new C builtins at all): when `ensure-library-
loaded!` compiles a library's own body, it first computes that
library's own visible-name set — its own top-level defines (a small
dedicated recognizer, `top-level-form-names`, covering `define`/
`define-values`/`define-record-type`/`define-syntax`/`defmacro`; NOT
the existing `expand-definition-form`/`record-type->define-forms`,
which desugar `define-record-type` into an internal, vector-based fake-
record shape for `hoist-internal-defines`' own letrec* folding and
critically don't generate a binding for the type name itself, unlike a
REAL top-level `define-record-type`, which binds type/ctor/pred/
accessors/mutators all as real globals per `vm.c`'s
`build_record_bindings`) UNION'd with the external names its own
`import` clauses actually resolve (`import-set-resolved-bindings`,
already real only/except/prefix/rename resolution, reused unchanged
from `environment`'s own machinery — this only needs a dependency's
*declared* export list, not for it to already be loaded, so it runs
independently of `ensure-libraries-loaded!` actually loading anything).
`current-library-visible-names`/`current-library-mangle-prefix`
(mutable, `#f` by default — ordinary top-level/REPL/script compiles are
completely unaffected) are bound for the duration of compiling that
library's own clauses (`dynamic-wind`-protected, so a mid-library
compile error can't leave state clobbered): `compile-var-ref!`'s new
`global-ref-name` helper emits an ordinary `GetGlobal` for a name in the
visible set, or a `GetGlobal` against a **mangled name** (`"<library
path>:<name>"`, guaranteed never genuinely bound) otherwise — so the
library's own body still compiles and *loads* successfully (matching
native's own observed behavior: a library loads fine even referencing
something it can't see), and only *calling* through to the excluded
name raises "unbound variable", at the R7RS-mandated moment, not a
moment earlier.

One subtlety that cost real debugging time: `compile-var-ref!` is NOT
the only place a bare global name gets compiled — `resolve-callee`
(feeding the fused-callee `CallGlobal`/`TailCallGlobal` opcodes used for
an ordinary, non-primitive-fused function call in callee position) has
its own, separate `chunk-add-const!` call and was missed on the first
pass; a call to an excluded name kept silently working via this second
path even after `compile-var-ref!` was fixed, until `resolve-callee`
was routed through the same `global-ref-name` helper. Fused *primitive*
opcodes (`+`/`-`/`car`/... in call position) needed the exact same
`mark-redefined!`/`unmark-redefined!` gating `eval`'s own `except`/
`only` fix uses (above), applied now per-library-compile instead of
per-eval-call: every `fusable-prim-names` entry not in the library's own
visible set is temporarily marked "redefined" for the duration of
compiling that library, so `(+ 1 2)` inside an unauthorized library body
also correctly falls back to the (now-mangled) `GetGlobal`+`Call` path
instead of silently fusing.

Deliberately NOT attempted: a library body's own `prefix`/`rename`
import-set being usable *by its renamed name* inside that same
library's own body (`import-set-alias-defines`'s aliasing-`define`
generation is only ever invoked from a top-level `(import ...)`/
`import!`, not from `process-library-clause!`'s own `import` case — a
separate, narrower, not-currently-spec-tested gap noticed during this
investigation); and restricting the **top-level program's own** import
visibility (as opposed to a library body's) — a much higher-blast-
radius case (would affect every existing script, not just library
bodies), left for a future, dedicated pass.

**Importing an unknown library name now raises, too** (previously a
silent no-op under icecreme specifically — README's old "Deliberate cuts"
wording, "no eval, no dynamically loading a library icecreme wasn't built
with"). `ensure-library-loaded!`'s native-fallback branch (no `.sld`
file found) now checks whether the name has the `(creme builtin
<family>)` shape every genuine native pseudo-library uses — every real
`(scheme ...)`/`(creme ...)` library this project ships has a real
`.sld` wrapper file, so a name with neither a `.sld` file nor this shape
is genuinely unknown, raising `"import: unknown library"` instead of
silently doing nothing. This check only fires when `(global-bound?
'read-whole-file)` — i.e. genuinely running under icecreme, where "no `.sld`"
reliably means "no such file exists." Under native/`--self-hosted`,
`read-whole-file` is *always* unbound regardless of whether a real
`.sld` exists (the whole reason `try-read-whole-file`/`file-read` are
kept deliberately separate, see the `include`/`file-read` entry above),
so "no src" there carries no information about whether a name is real —
without this guard, the check would have wrongly rejected perfectly
ordinary libraries like `(scheme base)` whenever a spec (e.g.
`compiler_libraries_spec.scm`'s `should-match-native?` cases) compiles a
quoted program reentrant under native Crystal itself; native's own real
`import!` already raises this exact error correctly, by a completely
different path.

## Known bugs (genuine defects, not deliberate cuts)

- **FIXED — was NOT an icecreme-specific bug, but affected every program icecreme
  runs (icecreme always executes self-hosted-compiled bytecode) — found
  while porting `(creme actor)`:** a body with a `define` following a
  preceding plain (non-`define`) expression could evaluate that
  `define`'s own initializer BEFORE the preceding expression ran, if the
  initializer's correctness depended on a side effect that expression
  had on shared/global mutable state:
  ```scheme
  (define worker 42)
  (register! worker)        ; sets some global registry
  (define found (lookup))   ; should see register!'s effect -- didn't
  ```
  `found` used to end up holding whatever `(lookup)` would have
  returned BEFORE `register!` ran. Reproduced with no shard/library
  dependency at all (a bare top-level `set!`/global-variable pair)
  under `./bin/creme --self-hosted` too, and did NOT reproduce under
  plain `./bin/creme` (the native Crystal compiler) — confirming this
  was a bug in the **self-hosted Scheme compiler itself**
  (`modules/creme/compiler/compiler.sld`'s `hoist-internal-defines`),
  not in icecreme's C dispatch loop; it just also affected icecreme since icecreme
  always runs self-hosted-compiled bytecode. This body shape is
  *permitted* here (see the "definition after expression" pending case
  in the Crystal-side spec suite) — the bug was that it didn't evaluate
  in source order regardless, not the permissiveness itself. Also
  affected a body with just ONE such `define` (not requiring two, as
  originally suspected while investigating via `(creme actor)`): a
  single `(define worker (spawn ...))` placed right after a preceding
  side-effecting expression (`(start-node ...)`, reassigning the
  calling actor's own current node) had its initializer's `spawn` run
  before `start-node`'s reassignment took effect — the spawned actor
  silently inherited the wrong node, and every message sent to it via
  its registered name vanished with no error.

  **Root cause**: `hoist-internal-defines` folded a body's own internal
  defines into a `letrec*` by bucketing forms into two SEPARATE lists —
  all `define`s (became `letrec*`'s own bindings, evaluated as a block
  BEFORE the body) and everything else (became the body, run after) —
  silently losing the true interleaved source order whenever a body
  mixed defines and plain expressions. **Fix**: keep `letrec*` only for
  what it's actually needed for — pre-declaring every defined name
  (bound to an unspecified placeholder) so a lambda defined earlier in
  the body can still forward-reference one defined later (ordinary
  mutual recursion, e.g. `even?`/`odd?`) — and replace each `define`,
  IN PLACE, in the body's own original order, with an ordinary `set!`
  to its already-declared name (exactly what a `define` actually does
  once its name already has a location to assign into). Every non-
  define form is left untouched, so the full interleaved sequence now
  evaluates in exactly the order the source wrote it in, while forward-
  reference visibility for mutual recursion is unaffected. See
  `spec/creme/r7rs/ch07_formal_syntax_spec.scm`'s own "evaluates a
  body's own definitions and expressions in source order" case (the
  real regression test for this — it was previously only worked around,
  never actually tested, throughout `spec/creme/actor_spec.scm`, whose
  own workaround comments this fix makes optional but doesn't require
  reverting).

## Deliberate cuts (not bugs — see comments at each site)

- **Fixed-capacity register stack and frame array for a given VM's whole
  lifetime**, never reallocated once built — because an *open* upvalue
  holds a raw `Value *` into the stack, and growing via `realloc` would
  silently invalidate every such pointer. Generous fixed caps sidestep the
  whole problem rather than solving it generally. The CAP itself is now
  embedder-configurable, though, not a hardcoded constant baked into the
  VM struct's own layout: `creme_alloc_vm(stack_cap, frames_cap)` (`vm.c`)
  is the one place every VM gets built (the main script's own top-level
  VM, a spawned actor's child VM, an `environment`/`eval` target), and any
  of them can be given a tighter or looser limit than
  `CREME_DEFAULT_STACK_CAP`/`CREME_DEFAULT_FRAMES_CAP` (`vm.h`) — the running
  `icecreme` binary itself exposes this today via the `ICECREME_STACK_CAP`/
  `ICECREME_FRAMES_CAP` environment variables (`main.c`), ahead of a real
  embedding API that would pass these values in directly.
- **Global resolution is ahead-of-time and unconditional**: `loader.c`
  rewrites every `GetGlobal`/`DefGlobal`/`CallGlobal`/`TailCallGlobal`
  operand from a const-pool symbol index to a direct index into the VM's
  global table, once, at load time — no per-call version check like the
  Crystal VM's inline cache. Sound only because this is one static, closed
  program with no `eval`/redefinition at runtime.
- **Most fused-op deopt paths are real fallbacks now, not hard aborts.**
  `Cxr`/`Abs`/`CmpZero` (`zero?`/`positive?`/`negative?`) fall back to the
  real accessor/builtin when their fast path's precondition fails (non-pair
  `cxr`, non-fixnum `abs`, non-fixnum comparison), exactly like the Crystal
  VM's own `unary_prim_deopt` — resolving the shared `d` operand's const-
  pool reference to either an already-resolved `T_BUILTIN` (native-compiled
  bytecode) or a bound global looked up by name (self-hosted-compiled
  bytecode) and calling it. Still-open, narrower gap: the immediate-
  arithmetic family's fused ops (`AddImm`/`SubImm`/`MulImm`) still hard-
  abort on a non-fixnum operand instead of deopting to the real `+`/`-`/`*`
  (which would itself promote to float/rational for that case) — not
  reachable by anything this project's own spec suite or bench exercises,
  same footnote the overflow case below carries.
- **`HelperForm`** (the top-level `(import ...)`) is a runtime no-op —
  imports are already fully resolved by the Crystal compiler at *emit*
  time, and any pure-Scheme library body they need is already flattened
  into the same combined chunk (see "`.sld` pure-Scheme libraries" above);
  the C VM's global table is also pre-seeded with whatever native builtins
  the program needs. There is no R7RS library/import system *at runtime* —
  no `eval`, no dynamically loading a library icecreme wasn't built with.
- Macros (`define-syntax`/`syntax-rules`/`defmacro`) are always gone by
  compile time regardless of backend — nothing icecreme-specific there, for an
  ordinary precompiled program. `Op::HelperForm`'s kind==3 (top-level
  `define-syntax`) and kind==4 (top-level `defmacro`) are both exceptions,
  needed for the "Compiler mode"/REPL scenario above: each binds a real
  `T_MACRO` runtime value so `expand-if-macro` can recognize a
  `define-syntax`/`defmacro` exported from a library compiled straight to
  bytecode when the self-hosted compiler runs reentrant under icecreme — see
  that section's own description. Neither kind does any runtime
  pattern-matching itself (this VM has no such machinery in C);
  `bi_expand_if_macro` (`bootstrap.c`) bridges both kinds out to the
  already-loaded self-hosted compiler's own `defmacro-expand-form`/
  `define-syntax-expand-form` (`compiler.sld`), which do the real
  expansion work — so a `syntax-rules` macro, including one exported
  across a library boundary, works the same as a `defmacro` here, not as a
  no-op.

## Files

- `opcodes.h` — on-disk opcode/const-tag ids: `Creme::Op`'s own enum
  ordinals (`src/creme/compile/opcode.cr`) and ICE1's `TAG_*`/`CDK_*`/`QQ_*`
  constants (`chunk_serializer.cr`), not a separate icecreme-specific numbering.
- `value.h` — the tagged `Value` struct and heap object types.
- `vm.h` — `Chunk`/`Frame`/`Closure`/`Upvalue`/`VM` struct definitions.
- `loader.c` — deserializes an ICE1 file OR in-memory byte buffer (one
  combined `Chunk`, no multi-chunk envelope), then resolves global names.
- `vm.c` — the dispatch loop, call/upvalue machinery, global table,
  guard/parameterize unwind machinery (`creme_abort`/`creme_raise_condition`).
- `builtins.c` — the R7RS-base-ish builtin surface (see table above).
- `mux.c`/`mux.h` — `(creme mux)`, a real HTTP server via poll(2) + picohttpparser. Dispatch is either inline (one thread, `mux-listen!`'s "pool" option `#f`, the default) or a growable pool of fully independent SO_REUSEPORT worker threads (`#t`/an integer max), each with its own child VM and no cross-thread handoff at all — the pool grows/shrinks with load between a permanent floor and that max.
- `sql.c`/`sql.h` — `(creme sql)`, real SQLite via the C API.
- `hashtable.c`/`hashtable.h` — `(creme hash-table)`, via Verstable.
- `strings.c`/`strings.h` — `(creme string)`/`(creme format)`.
- `bootstrap.c`/`bootstrap.h` — `load-chunk-bytes`/`import!`/
  `expand-if-macro`, see "REPL" above.
- `regex.c`/`regex.h` — `regexp`/`regexp-matches?` via PCRE2, see "REPL" above.
- `process.c`/`process.h` — `(creme process)`'s `process-run` (POSIX
  fork/pipe/execvp/waitpid) and `sleep-ms!` (`nanosleep`) — see "Native
  builtins and library coverage" above.
- `repl.scm` — the REPL driver script; a thin shim over `(creme repl)`
  (`modules/creme/repl.sld`), run directly as source (`./icecreme/icecreme
  icecreme/repl.scm`, see "REPL" above) — never precompiled via `--emit-icecreme`.
- `compiler-run.scm` — the compiler-mode driver script (see "Compiler
  mode" above), precompiled into `compiler-run.ice`.
- `profiler.c`/`profiler.h` — the `--profile` samplers, see "Profiling" above.
- `builtin_families.c`/`builtin_families.h` — the required-families→
  register-function table and `creme_register_required_builtins`/
  `creme_register_all_builtins`, extracted out of `main.c` (which also
  defines `main()`) so this logic can link into `libcreme.a` too — see
  "Embedding" above.
- `embed.c`/`embed.h` — the embedding-convenience API (`creme_runtime_init`,
  `creme_register_global`, `creme_run_repl`, `creme_run_scheme_file`) and
  the bin2c-embedded self-hosted-compiler bytecode it uses — library-only,
  not part of the CLI binary. See "Embedding" above.
- `creme.h` — the public umbrella header a `libcreme.a` consumer includes.
- `tools/bin2c.c` — tiny build-time helper turning a compiled `.ice` file
  into a `.c` source defining a `const unsigned char[]`/length pair; used
  to bundle `compiler-run.ice` into `embed.c`'s embedded byte array at
  library-build time.
- `main.c` — entry point: load and run the one combined chunk.
