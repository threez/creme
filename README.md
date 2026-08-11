# creme

A Scheme interpreter, written in Crystal. It follows R7RS-small and adds a large,
practical extension library. The interpreter library is the `creme` shard; the
CLI/REPL executable is also called `creme`. A companion self-hosting C11 bytecode
VM, **icecreme**, runs the same language.

📖 **[Documentation](doc/README.md)** — introduction, guides, library reference,
and the codebase map. New here? Start with the
[Introduction](doc/guide/introduction.md).

## Features

- REPL and script execution, or embed the interpreter as a library
- An R7RS `define-library`/`import` library system (see the [Libraries reference](doc/guide/libraries.md)) — the interactive REPL auto-imports `(scheme base)` and `(scheme write)` for zero-friction live typing; scripts (files or piped stdin) follow strict R7RS and must `(import ...)` everything they use, same as a `define-library` body
- Tail-call optimized eval/apply loop, closures, `let`/`let*`/`letrec`/named-`let`/`let-values`/`let*-values`, `do`, `case`/`case-lambda`, `cond-expand`, `defmacro`, `define-syntax`/`syntax-rules` (hygienic — see [Known caveats](#known-caveats) for the one narrow residual gap), `let-syntax`/`letrec-syntax`
- `define-record-type`, `delay`/`delay-force`/`force`, `parameterize`, `dynamic-wind`
- A full R7RS exception system: `guard`, `raise`/`raise-continuable`/`with-exception-handler`, `error`/`error-object?`/`error-object-message`/`error-object-irritants`, `file-error?`/`read-error?`
- `values`/`call-with-values`/`define-values`
- `call/cc`/`call-with-current-continuation` — **escape continuations only**, not full R7RS multi-shot continuations (see [Known caveats](#known-caveats))
- A full numeric tower including complex numbers: exact integers, exact rationals (`SchemeRational`, auto-reducing, e.g. `(/ 1 3)` is exact `1/3`), inexact floats, and complex numbers (`SchemeComplex`, reader literal syntax like `3+4i`/`2i`/`-i`, plus `(scheme complex)`'s `make-rectangular`/`make-polar`/`real-part`/`imag-part`/`magnitude`/`angle`) — with `exact?`/`inexact?`/`exact->inexact`/`inexact->exact`/`exact-integer?`/`rational?`/`numerator`/`denominator`/`gcd`/`lcm`/`nan?`/`infinite?`/`finite?`/`square` — see [Known caveats](#known-caveats) for what's deliberately out of scope
- Bytevectors: `#u8(...)` reader literal syntax, `bytevector`/`make-bytevector`/`bytevector-u8-ref`/`bytevector-u8-set!`/`bytevector-copy`/`bytevector-append`, byte-oriented ports (`open-input-bytevector`, `open-output-bytevector`, `read-u8`/`write-u8`), `utf8->string`/`string->utf8`
- Quoting: `quote`, `` ` `` quasiquote, `,` unquote, `,@` unquote-splicing
- Comments: `;` line comments, `#| ... |#` nestable block comments, `#;` datum comments

## Quick start

```sh
shards install
shards build
./bin/creme path/to/script.scm     # run a script
./bin/creme                        # start the REPL (Ctrl-D or (exit) to quit)
```

Building requires Crystal ≥ 1.19.0 and the system SQLite3, OpenSSL, and libyaml
libraries. See [Getting started](doc/guide/getting-started.md) for prerequisites,
the REPL, and piped input; the [Language tour](doc/guide/language-tour.md) for the
language by example; and the [CLI reference](doc/guide/cli-reference.md) for every
flag. To embed creme in a Crystal application, see
[Embedding](doc/guide/embedding.md).

## Documentation

- [Introduction](doc/guide/introduction.md) — what creme is, the two backends, project scope
- [Getting started](doc/guide/getting-started.md) — build, run, REPL
- [Language tour](doc/guide/language-tour.md) — the language by example
- [Libraries](doc/guide/libraries.md) — the full standard-library surface
- [CLI reference](doc/guide/cli-reference.md) — every subcommand and flag
- [Embedding](doc/guide/embedding.md) — using creme as a Crystal library
- [icecreme](doc/guide/icecreme.md) — the self-hosting C VM
- [Repository structure](doc/guide/repository-structure.md) — a map of the codebase

The full index, including maintainer/internals notes, is in
[`doc/README.md`](doc/README.md).

## Known caveats

- `(define ...)` as a script's last top-level form returns the defined *symbol*, not its value — end a script with an explicit expression if you need its value back.
- `Creme.from_scheme` never returns a bare Crystal `nil` from anything except `NIL` itself.
- `max_steps` resets per top-level form (per `run_source`/`run_file`/`apply` call), not once for an entire multi-form script.
- This is `import`-gating (via `allowed_libraries`), output redirection, and a step budget — not OS-level sandboxing. There's no CPU/memory ceiling beyond `max_steps`, and no protection against concurrent use of one `Interpreter` from multiple fibers (construct one per fiber instead).
- `define-syntax`/`syntax-rules` is hygienic: a template-introduced binding (e.g. a `swap!` macro's own `tmp`) is alpha-renamed so it can never capture (or be captured by) a use-site identifier of the same name. A macro's own reference to a special form or another macro also can't be hijacked by a use-site local of the same name, on both backends. A macro's own reference to an ordinary *global procedure* gets the same protection under the native Crystal interpreter, but not under icecreme/the self-hosted compiler (which has no compile-time global-binding registry to check against safely — see `modules/creme/compiler/compiler.sld`'s own `sr-apply-hygiene` comment) — a real, narrow asymmetry between the two backends, not a bug. The one gap on both backends: a macro that free-references an identifier meant to resolve as a *local variable enclosing its own definition* (not a global) can still be captured by a use-site local of that name — genuinely rare in practice (a macro almost always either introduces its own bindings or references globals/special forms/other macros). `defmacro` is unaffected by any of this — it's a separate, deliberately-manual fexpr mechanism (its "template" is arbitrary evaluated code, not a pattern/template pair) where authors who need capture-avoidance should still `gensym` identifiers by hand.
- `parameterize` and `guard` cannot tail-call out of their body in the final position — both need to run cleanup (restoring parameter values, or letting the `rescue` boundary close) before returning to the caller, so the body's last form is evaluated as an ordinary (non-tail) call.
- `guard` never catches `SchemeExecutionLimitError` (the `max_eval_depth`/`max_steps` budget) — it's a host-configured ceiling, not a guest-catchable condition, so a script can't swallow it and keep running past its own budget. `(exit ...)`'s `SchemeExit` is likewise never caught, for the same host-vs-guest reason.
- **Exact/exact division now produces an exact rational, not a float** — `(/ 1 3)` returns `1/3`, not `0.3333333333333333` as in earlier versions. This is the correct R7RS behavior (exact arithmetic stays exact), but it's a breaking change if a script or test relied on the old inexact fallback. Use `exact->inexact` (or `inexact`) to force a float when you specifically want one.
- `call/cc`/`call-with-current-continuation` implement **escape continuations only**, via a Crystal exception unwind — not full R7RS multi-shot/re-entrant continuations. A captured continuation can be invoked at most once, and only while its originating `call/cc` call is still on the (real) call stack (i.e. before `call/cc` has returned normally). This covers non-local exit, early return, and `guard`-style unwinding — the large majority of real-world call/cc use — but not `amb`-style backtracking or re-entrant/restartable generators. Invoking a continuation after its `call/cc` has already returned raises `SchemeRuntimeError` ("continuation invoked outside its dynamic extent") rather than resuming.
- `dynamic-wind` runs its before/after thunks correctly around normal return, an error, or a call/cc escape (including escaping past multiple nested `dynamic-wind` frames, innermost-first). What it does **not** do, matching the escape-only `call/cc` limitation above: re-fire `before` when a continuation captured *inside* a `dynamic-wind` call is invoked to re-enter it from *outside*, after that `dynamic-wind` call has already returned — true re-entrant continuations would be required for that, and invoking such a continuation instead raises the same "continuation invoked outside its dynamic extent" error rather than behaving incorrectly.
- `angle`/`make-polar` on complex numbers always produce an inexact (float) result — `angle` is `atan2`, `make-polar` needs `cos`/`sin` of an arbitrary angle, and neither π nor a general trigonometric value has an exact rational representation in this tower. (Complex division and `magnitude` *do* stay exact for exact-integer-component operands, e.g. `(magnitude (make-rectangular 3 4))` is exact `5`, not `5.0`.)

## Development

```sh
shards install                 # install dependencies (also vendors ameba for linting)
crystal spec                   # run the test suite
crystal tool format --check    # check formatting
lib/ameba/bin/ameba            # lint
```

`make` wraps these as `fmt`/`fmtcheck`/`spec`/`lint`/`fix`. Building requires the
system SQLite3 library (already present on macOS; `apt install libsqlite3-dev` on
Debian/Ubuntu), since the `sql` module links against it. The `jose` module links
against system OpenSSL (via the `jose`/`ed25519` shards) — already present on
macOS with no extra setup; `apt install libssl-dev` on Debian/Ubuntu if missing.
The `yaml` module links against system libyaml (via Crystal's own bundled `YAML`
stdlib module) — already present on macOS with no extra setup;
`apt install libyaml-dev` on Debian/Ubuntu if missing. `icecreme` links libyaml
directly too (see `icecreme/README.md`), so this is a build-time dependency for
both backends. See the [Repository structure](doc/guide/repository-structure.md)
guide for a map of the source tree.

## License

MIT, see [LICENSE](LICENSE). © Vincent Landgraf.
