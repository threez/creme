# lisp.cr

A Scheme-flavored Lisp interpreter, written in Crystal. The interpreter library is the `lisp` shard; the CLI/REPL executable is called `crisp`.

## Features

- REPL and script execution, or embed the interpreter as a library
- Tail-call optimized eval/apply loop, closures, `let`/`let*`/`letrec`, `defmacro`
- Quoting: `quote`, `` ` `` quasiquote, `,` unquote, `,@` unquote-splicing
- A lazily-loaded standard library, `(require 'name)`-style, covering JSON, regex, SQLite, a SQL statement builder DSL, arbitrary-precision decimals, hashing, time, and more (see below)

## Installation

### As a standalone CLI

```sh
shards install
shards build
./bin/crisp path/to/script.lisp
```

### As a Crystal library

```yaml
dependencies:
  lisp:
    github: threez/lisp
```

```crystal
require "lisp"

interp = LISP::Interpreter.new
LISP.run_source(interp, "(+ 1 2)")
LISP.run_file(interp, "script.lisp")
```

`LISP.run_source`/`LISP.run_file` are pure library entry points with no STDOUT/STDERR/process-exit side effects. See [Embedding](#embedding) below for injecting host data, reading results back as native Crystal types, registering host callbacks, sandboxing, and execution limits.

## Usage

```sh
crisp                 # interactive REPL (Ctrl-D or (exit) to quit)
crisp script.lisp     # execute a script
crisp --help          # usage
```

Piping input to `crisp` (non-interactive stdin) reads and evaluates a whole program instead of starting the REPL.

## Language tour

```lisp
(define (fact n) (if (<= n 1) 1 (* n (fact (- n 1)))))
(fact 10) ; => 3628800

; closures
(define (make-counter)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(list (c) (c) (c)) ; => (1 2 3)

; higher-order functions
(map (lambda (x) (* x x)) '(1 2 3 4))     ; => (1 4 9 16)
(filter (lambda (x) (> x 2)) '(1 2 3 4))  ; => (3 4)
(reduce + 0 '(1 2 3 4 5))                 ; => 15

; cond / else
(define (sign x)
  (cond ((> x 0) 'positive) ((< x 0) 'negative) (else 'zero)))

; quasiquote
`(1 ,(+ 1 1) ,@(list 3 4)) ; => (1 2 3 4)
```

Booleans are `#t`/`#f`, the empty list/nil is `()`, predicates end in `?` (`even?`, `null?`), mutators end in `!` (`set!`, `set-car!`). There's no `defun`/`loop`/`dotimes` — use the `(define (name args...) body)` sugar and `map`/`filter`/`for-each`/`foldl`/`foldr`/`reduce`, or recursion.

See `examples/` for complete, runnable programs (numbered by topic), and `examples/demo.lisp` for a quick tour of the core language.

## Standard library modules

Each module is loaded on demand with `(require 'name)`, after which its functions are called as `name:function`:

- **`bigdecimal`** — arbitrary-precision decimal arithmetic (`parse`, `add`/`sub`/`mul`/`div`, `compare`, `to-string`, ...)
- **`digest`** — `md5`, `sha1`, `sha256`, `base64-encode`, `base64-decode`
- **`env`** — process environment variables (`get`, `set!`, `delete!`, `has?`, `all`)
- **`file`** — filesystem I/O (`read`, `write`, `append`, `exists?`, `delete`, `lines`, `size`)
- **`json`** — `parse`/`stringify` (JSON arrays decode to vectors, objects to alists)
- **`math`** — transcendental functions (`sin`, `cos`, `log`, `pow`, `atan2`, `hypot`, ...) and `pi`/`e`
- **`process`** — run external commands (`run`, `args`)
- **`random`** — `float`, `int`, `seed`, `choice`, `shuffle`
- **`regex`** — compiled patterns (`compile`, `match?`, `match`, `find-all`, `replace`, `replace-all`, `split`)
- **`sql`** — SQLite access (`open`, `close`, `execute`, `query`, `scalar`) — file-backed or `:memory:`
- **`sxql`** — SQL statement builder DSL (`select`/`insert-into`/`update`/`delete-from`, `where`/`join`/`group-by`/..., DDL, `yield` to render SQL + bound params) — pairs with `sql`
- **`string`** — `upcase`, `downcase`, `trim`, `split`, `join`, `replace`, `contains?`, `starts-with?`, `pad-left`/`pad-right`, ...
- **`time`** — `now`, date/time component accessors, `format`, `parse`, `add-seconds`, `diff`

A `sql` + `sxql` example:

```lisp
(require 'sql)
(require 'sxql)

(define conn (sql:open ":memory:"))
(sql:execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
(sql:execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Alice" 30)

(define built
  (sxql:yield (sxql:select '(name age)
                (sxql:from 'person)
                (sxql:where (sxql:>= 'age 18)))))

(apply sql:query conn (first built) (second built))
```

## Embedding

Beyond the quick-start shown under [Installation](#as-a-crystal-library), a host application embedding the interpreter for templating, rule-engine, or dataset-filtering use cases has a few more building blocks available.

### Injecting host data and isolating calls

`run_source`/`run_file` take optional `bindings`/`parent` arguments, for running one warm `Interpreter` many times — once per dataset row, rule evaluation, or template render — without state leaking between calls:

```crystal
interp = LISP::Interpreter.new

rows.each do |row|
  bindings = {"name" => LISP.to_lisp(row.name), "age" => LISP.to_lisp(row.age)} of String => LISP::LispValue
  result = LISP.run_source(interp, "(> age 18)", bindings: bindings)
  puts LISP.truthy?(result)
end
```

- Neither given: evaluates against `interp.global`, same as always — a script's own top-level `define`s persist for later calls (handy for a REPL-style session).
- `bindings` given: evaluates against a fresh, isolated child of `interp.global` (or of `parent`, if also given), seeded with the bindings and discarded after the call — nothing leaks into `interp.global` or a later call, even an empty `{}` counts as "isolate this call."
- `parent` given alone: evaluates directly against that env.
- Both given: a fresh child of `parent`, seeded with `bindings` — register expensive callbacks once on a reusable `parent` env (see below), then reuse it as the chain root for many cheap, isolated calls.

### Reading results back as native Crystal data

`LISP.to_lisp`/`LISP.from_lisp` convert between `LISP::LispValue` and plain Crystal data (`Nil`, `Bool`, `Int64`, `Float64`, `String`, `Array`, `Hash(String, _)` — aliased as `LISP::Convertible`), so a rule/filter/template's result can be read back without touching `LispValue` at all:

```crystal
result = LISP.run_source(interp, "(filter active? people)", bindings: bindings)
LISP.from_lisp(result) # => Array/Hash/String/Int64/Float64/Bool/nil, recursively
```

`Array`s convert to/from `LispVector`s; `Hash(String, _)`s convert to/from alists (`(key . value)` pairs, matching the `json`/`sql` module convention) — duplicate alist keys resolve first-occurrence-wins, matching `assoc`. `NIL` converts to Crystal `nil` (matching `json:parse`'s existing `null`/`NIL` convention) — use `LISP.list_to_a` directly instead when a value is known to be list-shaped and an empty result should read as `[]`.

### Registering host callbacks

`Env#define_fn` registers a Crystal callback as a callable Lisp procedure:

```crystal
interp.global.define_fn("lookup-tax-rate", 1, 1) do |args|
  LISP.to_lisp(tax_table[args[0].as(LISP::LispStr).value])
end
```

Callbacks are ordinary `LispValue`s (`Builtin`s), so they can also go straight into a per-call `bindings` hash instead of `interp.global`, without a separate API.

### Sandboxing untrusted rule/template content

For rule/template content from a less-trusted source (stored in a database, editable by end users), `Interpreter.sandboxed` gives safe-by-default construction — deny-all modules, a finite step budget, captured (not real) stdout — so a host doesn't need to remember every knob:

```crystal
interp = LISP::Interpreter.sandboxed(allowed_modules: ["string", "math"])
```

`Interpreter.new` itself defaults to today's unrestricted behavior (`allowed_modules: nil`) for backward compatibility — use `.sandboxed` when embedding content you don't fully trust. `allowed_modules` restricts `(require ...)`; `interp.available_modules` lists every module name the interpreter knows, for building a deny-list (`interp.available_modules - ["process", "file", "sql", "env"]`). `interp.stdout` (an `IO`) redirects/captures/suppresses `display`/`write`/`newline`/`print`/`println` output — swap in an `IO::Memory` per render to capture a template's printed output, or just to keep guest code from writing to the host process's real stdout.

### Execution limits

`max_eval_depth` (existing) bounds non-tail recursion; `max_steps` additionally bounds every trampoline step, closing the one gap `max_eval_depth` doesn't cover — an infinite *tail*-recursive script. Both raise `LISP::LispExecutionLimitError` (a `LispRuntimeError` subclass) when exceeded, distinguishable from an ordinary bug in the guest code:

```crystal
interp = LISP::Interpreter.new(max_steps: 100_000)
```

`(exit ...)` raises a catchable `LISP::LispExit` rather than terminating the host process — `src/main.cr` (the `crisp` CLI) is the only place that translates it back into a real process exit.

### Known caveats

- `(define ...)` as a script's last top-level form returns the defined *symbol*, not its value — end a script with an explicit expression if you need its value back.
- `LISP.from_lisp` never returns a bare Crystal `nil` from anything except `NIL` itself.
- `max_steps` resets per top-level form (per `run_source`/`run_file`/`apply` call), not once for an entire multi-form script.
- This is `require`-gating, output redirection, and a step budget — not OS-level sandboxing. There's no CPU/memory ceiling beyond `max_steps`, and no protection against concurrent use of one `Interpreter` from multiple fibers (construct one per fiber instead).

## Development

```sh
shards install                 # install dependencies (also vendors ameba for linting)
crystal spec                   # run the test suite
crystal tool format --check    # check formatting
lib/ameba/bin/ameba            # lint
```

`make` wraps these as `fmt`/`fmtcheck`/`spec`/`lint`/`fix`. Building requires the system SQLite3 library (already present on macOS; `apt install libsqlite3-dev` on Debian/Ubuntu), since the `sql` module links against it.

## License

MIT, see [LICENSE](LICENSE). © Vincent Landgraf.
