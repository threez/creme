# Embedding creme in Crystal

creme is also an embeddable Crystal library — useful for templating, rule
engines, or dataset filtering inside a host application, with sandboxing and
execution limits available.

## As a Crystal library

```yaml
dependencies:
  creme:
    github: threez/creme
```

```crystal
require "creme"

# auto_import_base: false — a script must (import (scheme base) ...)
# itself, matching strict R7RS; this is what src/main.cr uses for both
# file and piped-stdin execution. Omit it (or pass true) for a REPL-style
# session where (scheme base)/(scheme write) should already be in scope.
interp = Creme::Interpreter.new(auto_import_base: false)
Creme.run_source(interp, "(import (scheme base)) (+ 1 2)")
Creme.run_file(interp, "script.scm")
```

`Creme.run_source`/`Creme.run_file` are pure library entry points with no
STDOUT/STDERR/process-exit side effects. The rest of this guide covers the
additional building blocks: injecting host data, reading results back as native
Crystal types, registering host callbacks, sandboxing, and execution limits.

## Injecting host data and isolating calls

`run_source`/`run_file` take optional `bindings`/`parent` arguments, for running
one warm `Interpreter` many times — once per dataset row, rule evaluation, or
template render — without state leaking between calls:

```crystal
interp = Creme::Interpreter.new

rows.each do |row|
  bindings = {"name" => Creme.to_scheme(row.name), "age" => Creme.to_scheme(row.age)} of String => Creme::SchemeValue
  result = Creme.run_source(interp, "(> age 18)", bindings: bindings)
  puts Creme.truthy?(result)
end
```

- Neither given: evaluates against `interp.global`, same as always — a script's own top-level `define`s persist for later calls (handy for a REPL-style session).
- `bindings` given: evaluates against a fresh, isolated child of `interp.global` (or of `parent`, if also given), seeded with the bindings and discarded after the call — nothing leaks into `interp.global` or a later call, even an empty `{}` counts as "isolate this call."
- `parent` given alone: evaluates directly against that env.
- Both given: a fresh child of `parent`, seeded with `bindings` — register expensive callbacks once on a reusable `parent` env (see below), then reuse it as the chain root for many cheap, isolated calls.

## Reading results back as native Crystal data

`Creme.to_scheme`/`Creme.from_scheme` convert between `Creme::SchemeValue` and
plain Crystal data (`Nil`, `Bool`, `Int64`, `Float64`, `String`, `Array`,
`Hash(String, _)` — aliased as `Creme::Convertible`), so a rule/filter/template's
result can be read back without touching `SchemeValue` at all:

```crystal
result = Creme.run_source(interp, "(filter active? people)", bindings: bindings)
Creme.from_scheme(result) # => Array/Hash/String/Int64/Float64/Bool/nil, recursively
```

`Array`s convert to/from `SchemeVector`s; `Hash(String, _)`s convert to/from
alists (`(key . value)` pairs, matching the `json`/`sql` module convention) —
duplicate alist keys resolve first-occurrence-wins, matching `assoc`. `NIL`
converts to Crystal `nil` (matching `json-read`'s existing `null`/`NIL`
convention) — use `Creme.list_to_a` directly instead when a value is known to be
list-shaped and an empty result should read as `[]`.

## Registering host callbacks

`Env#define_fn` registers a Crystal callback as a callable Scheme procedure:

```crystal
interp.global.define_fn("lookup-tax-rate", 1, 1) do |args|
  Creme.to_scheme(tax_table[args[0].as(Creme::SchemeStr).value])
end
```

Callbacks are ordinary `SchemeValue`s (`Builtin`s), so they can also go straight
into a per-call `bindings` hash instead of `interp.global`, without a separate
API.

## Loading file-based libraries

`library_search_path` (an `Array(String)` of directories, empty by default) is
where `(import (a b c))` looks for an `a/b/c.sld` file when `(a b c)` isn't a
Crystal-native library — the mechanism `(creme sxql)` itself uses
(`modules/creme/sxql.sld`):

```crystal
interp = Creme::Interpreter.new(library_search_path: ["./modules"])
```

A `.sld` file must contain exactly one top-level `(define-library (name ...) ...)`
form whose name matches the path it was found at.

## Sandboxing untrusted rule/template content

For rule/template content from a less-trusted source (stored in a database,
editable by end users), `Interpreter.sandboxed` gives safe-by-default
construction — deny-all library imports, a finite step budget, captured (not
real) stdout — so a host doesn't need to remember every knob:

```crystal
interp = Creme::Interpreter.sandboxed(allowed_libraries: ["scheme base", "creme string", "scheme inexact"])
Creme.run_source(interp, %[(import (scheme base) (creme string)) (string-upcase "hi")])
```

`Interpreter.new` itself defaults to today's unrestricted behavior
(`allowed_libraries: nil`) for backward compatibility — use `.sandboxed` when
embedding content you don't fully trust. `allowed_libraries` restricts
`(import ...)` by space-joined library name (e.g. `"creme sql"` for `(creme sql)`,
`"scheme base"` for `(scheme base)`) — note that `"scheme base"` itself is not
implicitly allowed, so guest code needs it listed explicitly if it's expected to
`(import (scheme base))`. `.sandboxed` defaults `auto_import_base: false` (unlike
`Interpreter.new`), so guest code gets nothing for free, including
`(scheme base)`/`(scheme write)` — every binding it uses must come from an
`(import ...)` it's actually allowed to make; pass `auto_import_base: true` to
`.sandboxed` to opt back into pre-binding those two (still bypassing
`allowed_libraries`, since that binding happens at construction, before any
script runs). `interp.available_libraries` lists every library name the
interpreter currently knows about, for building a deny-list
(`interp.available_libraries - ["creme process", "creme file", "creme sql", "creme env"]`).
`interp.stdout` (an `IO`) redirects/captures/suppresses
`display`/`write`/`newline`/`print`/`println` output — swap in an `IO::Memory`
per render to capture a template's printed output, or just to keep guest code
from writing to the host process's real stdout.

## Execution limits

`max_eval_depth` (existing) bounds non-tail recursion; `max_steps` additionally
bounds every trampoline step, closing the one gap `max_eval_depth` doesn't cover
— an infinite *tail*-recursive script. Both raise
`Creme::SchemeExecutionLimitError` (a `SchemeRuntimeError` subclass) when
exceeded, distinguishable from an ordinary bug in the guest code:

```crystal
interp = Creme::Interpreter.new(max_steps: 100_000)
```

`(exit ...)` raises a catchable `Creme::SchemeExit` rather than terminating the
host process — `src/main.cr` (the `creme` CLI) is the only place that translates
it back into a real process exit.

> **Note:** This is `import`-gating (via `allowed_libraries`), output redirection,
> and a step budget — not OS-level sandboxing. There's no CPU/memory ceiling
> beyond `max_steps`, and no protection against concurrent use of one
> `Interpreter` from multiple fibers (construct one per fiber instead). See the
> README's **Known caveats** for the full list.
