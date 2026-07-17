# scheme.cr

A Scheme interpreter, written in Crystal. The interpreter library is the `scheme` shard; the CLI/REPL executable is called `creme`.

## Features

- REPL and script execution, or embed the interpreter as a library
- An R7RS `define-library`/`import` library system (see [Libraries](#libraries) below) — the interactive REPL auto-imports `(scheme base)` and `(scheme write)` for zero-friction live typing; scripts (files or piped stdin) follow strict R7RS and must `(import ...)` everything they use, same as a `define-library` body
- Tail-call optimized eval/apply loop, closures, `let`/`let*`/`letrec`/named-`let`/`let-values`/`let*-values`, `do`, `case`/`case-lambda`, `cond-expand`, `defmacro`, `define-syntax`/`syntax-rules` (unhygienic — see [Known caveats](#known-caveats)), `let-syntax`/`letrec-syntax`
- `define-record-type`, `delay`/`delay-force`/`force`, `parameterize`, `dynamic-wind`
- A full R7RS exception system: `guard`, `raise`/`raise-continuable`/`with-exception-handler`, `error`/`error-object?`/`error-object-message`/`error-object-irritants`, `file-error?`/`read-error?`
- `values`/`call-with-values`/`define-values`
- `call/cc`/`call-with-current-continuation` — **escape continuations only**, not full R7RS multi-shot continuations (see [Known caveats](#known-caveats))
- A full numeric tower including complex numbers: exact integers, exact rationals (`SchemeRational`, auto-reducing, e.g. `(/ 1 3)` is exact `1/3`), inexact floats, and complex numbers (`SchemeComplex`, reader literal syntax like `3+4i`/`2i`/`-i`, plus `(scheme complex)`'s `make-rectangular`/`make-polar`/`real-part`/`imag-part`/`magnitude`/`angle`) — with `exact?`/`inexact?`/`exact->inexact`/`inexact->exact`/`exact-integer?`/`rational?`/`numerator`/`denominator`/`gcd`/`lcm`/`nan?`/`infinite?`/`finite?`/`square` — see [Known caveats](#known-caveats) for what's deliberately out of scope
- Bytevectors: `#u8(...)` reader literal syntax, `bytevector`/`make-bytevector`/`bytevector-u8-ref`/`bytevector-u8-set!`/`bytevector-copy`/`bytevector-append`, byte-oriented ports (`open-input-bytevector`, `open-output-bytevector`, `read-u8`/`write-u8`), `utf8->string`/`string->utf8`
- Quoting: `quote`, `` ` `` quasiquote, `,` unquote, `,@` unquote-splicing
- Comments: `;` line comments, `#| ... |#` nestable block comments, `#;` datum comments

## Installation

### As a standalone CLI

```sh
shards install
shards build
./bin/creme path/to/script.scm
```

### As a Crystal library

```yaml
dependencies:
  scheme:
    github: threez/scheme
```

```crystal
require "scheme"

# auto_import_base: false — a script must (import (scheme base) ...)
# itself, matching strict R7RS; this is what src/main.cr uses for both
# file and piped-stdin execution. Omit it (or pass true) for a REPL-style
# session where (scheme base)/(scheme write) should already be in scope.
interp = Scheme::Interpreter.new(auto_import_base: false)
Scheme.run_source(interp, "(import (scheme base)) (+ 1 2)")
Scheme.run_file(interp, "script.scm")
```

`Scheme.run_source`/`Scheme.run_file` are pure library entry points with no STDOUT/STDERR/process-exit side effects. See [Embedding](#embedding) below for injecting host data, reading results back as native Crystal types, registering host callbacks, sandboxing, and execution limits.

## Usage

```sh
creme                 # interactive REPL (Ctrl-D or (exit) to quit)
creme script.scm      # execute a script
creme --help          # usage
```

Piping input to `creme` (non-interactive stdin) reads and evaluates a whole program instead of starting the REPL.

## Language tour

```scheme
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

; case
(define (day-kind d) (case d ((sat sun) 'weekend) (else 'weekday)))

; named let / do — two ways to iterate
(let loop ((i 0) (acc 0)) (if (= i 5) acc (loop (+ i 1) (+ acc i)))) ; => 10
(do ((i 0 (+ i 1)) (acc 0 (+ acc i))) ((= i 5) acc))                 ; => 10

; define-record-type
(define-record-type point (make-point x y) point? (x point-x) (y point-y))
(point-x (make-point 3 4)) ; => 3

; guard / error-object-message
(guard (e (#t (list 'caught (error-object-message e)))) (error "boom"))

; exact rationals: division of exact numbers stays exact
(/ 1 3)                    ; => 1/3 (not 0.333...)
(+ (/ 1 3) (/ 1 6))         ; => 1/2
(exact->inexact (/ 1 3))   ; => 0.3333333333333333

; values / call-with-values
(call-with-values (lambda () (values 1 2 3)) +) ; => 6

; call/cc: non-local exit (escape continuations only, see Known caveats)
(call/cc (lambda (return)
  (for-each (lambda (x) (if (> x 3) (return x))) '(1 2 3 4 5))
  'not-found)) ; => 4

; raise / with-exception-handler / raise-continuable
(with-exception-handler
  (lambda (e) 42)                       ; the handler's return value...
  (lambda () (+ 1 (raise-continuable 'oops)))) ; ...flows back in-line: => 43

; dynamic-wind: before/after always run in pairs, even across a call/cc escape
(call/cc (lambda (k)
  (dynamic-wind
    (lambda () (display "enter ") )
    (lambda () (k 'done))
    (lambda () (display "exit ")))))     ; prints "enter exit "

; bytevectors
(define bv (bytevector 72 105))
(utf8->string bv)                        ; => "Hi"
#u8(1 2 3)                               ; reader literal syntax

; complex numbers
(import (scheme complex))
3+4i                                     ; reader literal syntax
(magnitude 3+4i)                         ; => 5.0
(sqrt -4)                                ; => 0.0+2.0i
```

Booleans are `#t`/`#f`, the empty list/nil is `()`, predicates end in `?` (`even?`, `null?`), mutators end in `!` (`set!`, `set-car!`). There's no `defun`/`loop`/`dotimes` — use the `(define (name args...) body)` sugar, `do` or named-`let` for iteration, and `map`/`filter`/`for-each`/`foldl`/`foldr`/`reduce`, or recursion.

See `examples/` for complete, runnable programs (numbered by topic), and `examples/demo.scm` for a quick tour of the core language.

## Libraries

Libraries are loaded with `(import ...)`, following R7RS's `define-library`/`import` mechanism (§5.6) — `only`/`except`/`prefix`/`rename` import-set combinators are all supported, e.g. `(import (only (scheme base) car cdr) (prefix (creme string) str:))`. Every library must be imported explicitly to be used — including `(scheme base)` itself — matching real R7RS scoping; a `define-library` body sees only what it imports, same as a top-level script. The *interactive REPL only* auto-imports `(scheme base)` and `(scheme write)` at construction (`Interpreter.new(auto_import_base: true)`, the default) purely for typing convenience — file and piped-stdin execution use `auto_import_base: false` and get nothing for free (see `src/main.cr`). Everything else, including this project's own `(creme extra)`, is import-only always, even in the REPL — see [Libraries](#libraries) below. See [Execution limits](#execution-limits) below for `allowed_libraries`, which can restrict which libraries a script may `import` at all (the REPL's auto-import bypasses that restriction, since it happens at construction, before any script runs). A library can also be defined directly with `(define-library (name ...) (export ...) (import ...) (begin ...))`, either inline in a script or as a file-based `.sld` library resolved via `library_search_path` (see [Embedding](#embedding)).

### `(scheme ...)`: the R7RS standard libraries

| Library | Contents |
|---|---|
| `(scheme base)` | Core forms and procedures — arithmetic, pairs/lists, vectors, bytevectors, strings, characters, ports, `guard`/`raise`/`with-exception-handler`, `dynamic-wind`, `call/cc`, `values`, `let-values`, `case-lambda`, `cond-expand`, and more — see R7RS Appendix A for the full list |
| `(scheme write)` | `display`, `write` |
| `(scheme char)` | Unicode-table-dependent character/string operations: `char-upcase`/`char-downcase`/`char-alphabetic?`/etc., `char-foldcase`, `digit-value`, `string-foldcase`, `string-ci=?` and friends, `string-upcase`/`string-downcase` |
| `(scheme inexact)` | `sqrt`, `finite?`/`infinite?`/`nan?`, and transcendental functions: `sin`/`cos`/`tan`/`asin`/`acos`/`atan`/`exp`/`log` |
| `(scheme complex)` | `make-rectangular`, `make-polar`, `real-part`, `imag-part`, `magnitude`, `angle`, `complex?` |
| `(scheme cxr)` | The 22 depth-3/4 `car`/`cdr` compositions beyond `(scheme base)`'s `caar`/`cadr`/`cdar`/`cddr` |
| `(scheme lazy)` | `force`, `make-promise`, `promise?`, `delay-force` (`delay` itself is a special form, always available with no import) |
| `(scheme read)` | `read` |
| `(scheme eval)` | `eval` |
| `(scheme process-context)` | `command-line`, `emergency-exit`, `exit`, `get-environment-variable`, `get-environment-variables` |
| `(scheme case-lambda)` | `case-lambda` (also a special form, always available with no import) |
| `(scheme time)` | `current-second`, `current-jiffy`, `jiffies-per-second` — R7RS's minimal time contract; see `(creme time)` below for a much richer, non-standard time API |

### `(creme ...)`: this project's own extensions

Modules with no SRFI precedent (`sql`, `tui`, `http`, `digest`, `bigdecimal`, `rfc8439`, `jose`, the `sxql` DSL) use a `module-name-` prefix to stay collision-free; modules that do follow a SRFI keep that SRFI's naming.

- **`(creme bigdecimal)`** — arbitrary-precision decimal arithmetic: `string->bigdecimal`, `integer->bigdecimal`, `bigdecimal-add`/`sub`/`mul`/`div`/`neg`, `bigdecimal-compare`, `bigdecimal=?`/`<?`/`>?`, `bigdecimal->string`, `bigdecimal?`
- **`(creme digest)`** — `digest-md5`, `digest-sha1`, `digest-sha256`, `base64-encode`, `base64-decode`
- **`(creme env)`** — process environment variables (SRFI-98 naming where it exists): `get-environment-variable`, `get-environment-variables`, `set-environment-variable!`, `delete-environment-variable!`, `environment-variable-set?`
- **`(creme extra)`** — this project's own non-R7RS conveniences, a file-based `.sld` library (`modules/creme/extra.sld`, pure R7RS Scheme, same as `(creme sxql)`) rather than compiled into the interpreter binary — never auto-imported, even in the REPL: SRFI-1-style list procedures (`filter`, `reduce`, `foldl`/`foldr`, `any`, `every`, `count`, `iota`, `partition`, `cons*`, `append-map`, `filter-map`, `last-pair`, `delete`/`delete!`), `print`/`println`, and legacy R5RS numeric aliases (`exact->inexact`, `inexact->exact`, `float?`) — note there is deliberately no `blob*` family here: `blob?`/`blob-size`/`blob->string`/`string->blob` were exact duplicates of the real R7RS bytevector procedures (`bytevector?`/`bytevector-length`/`utf8->string`/`string->utf8` — `SchemeBlob` *is* the bytevector type) and were removed; there's also no `eval-string` — `current-output-port`/`current-input-port`/`current-error-port` are genuine R7RS parameter objects, so "capture printed output while evaluating" is expressible portably via `(parameterize ((current-output-port p)) (eval ...))` plus `guard`, with no interpreter-specific helper needed (see `examples/24-tui-try-scheme.scm`'s `eval-source-line` for a worked example). Internal conveniences (`add1`/`sub1`/`1+`/`identity`/`range`/`last`, plus the extra cxr accessors `caddr`/`cdddr`/`cadddr` and the aliases `first`/`second`/`third`/`rest`) are defined in `@base_env` but aren't exported through any library — `caddr`/`cdddr`/`cadddr` are reachable portably via `(scheme cxr)` instead. The cxr accessors and their aliases are real builtins (not wrapper closures), so a direct `(cadr x)`/`(first x)` fuses into the single `Op::Cxr` instruction; `add1`/`range`/etc. still live in `interpreter/prelude.cr`, while the cxr set is installed as builtins/value-aliases (see `Interpreter#install_cxr_conveniences`).
- **`(creme introspection)`** — `macro?` and `gensym`, the two genuinely Crystal-level operations `(creme extra)` can't express in portable Scheme (a real R7RS `syntax-rules` transformer isn't a first-class runtime value, so there's no way to ask "is this a macro" at all; `gensym` has no R7RS analog since hygienic macro expansion generates fresh identifiers automatically)
- **`(creme file)`** — whole-file convenience helpers (`file-read`/`file-write`/`file-append`/`file-lines`/`file-size`, plus R7RS-exact `file-exists?`/`delete-file`) and R7RS port-based file I/O (`open-input-file`, `open-output-file`, `call-with-input-file`, `call-with-output-file`, `with-input-from-file`, `with-output-to-file`) — the latter compose with `(scheme base)`'s own `read-char`/`peek-char`/`read-line`/`read-string`/`write-char`/`write-string`/port procedures
- **`(creme hash-table)`** — `make-hash-table`, `hash-table?`, `hash-table-set!`, `hash-table-ref` (optional default value or thunk), `hash-table-delete!`, `hash-table-contains?`, `hash-table-keys`, `hash-table-values`, `hash-table->alist` — keys compared by `equal?`, not R7RS-small but a common practical need
- **`(creme json)`** — `json-read`/`json-write` (JSON arrays decode to vectors, objects to alists)
- **`(creme jose)`** — JOSE (JSON Object Signing and Encryption), backed by the [jose.cr](https://github.com/threez/jose.cr) shard (OpenSSL underneath): JWK generation/import/export (`jose-jwk-generate-oct`/`-ec`/`-rsa`/`-okp`, `jose-jwk-from-oct`/`-pem`/`-json`, `jose-jwk-to-pem`/`-json`/`-public`, `jose-jwk-with-kid`, `jose-jwk-kty`, `jose-jwk-public?`/`-private?`/`?`), JWS signing (`jose-jws-sign`/`-verify`, `-sign-detached`/`-verify-detached`, `-sign-json`/`-verify-json`), JWT issuing/verification with RFC 8725 checks (`jose-jwt-sign`, `jose-jwt-verify`), JWE encryption (`jose-jwe-encrypt`/`-decrypt`, `-password-encrypt`/`-decrypt`, `-json-encrypt`/`-json-decrypt`), and JWKS key sets (`jose-jwks-new`, `-to-public`, `-ref`, `-size`, `?`) — claims/headers round-trip as alists, matching the `(creme json)` convention; compact tokens are plain strings
- **`(creme math)`** — a superset of `(scheme inexact)`'s trig/log functions plus non-standard extras: `log2`, `log10`, `atan2`, `pow`, `hypot`, `pi`, `e`
- **`(creme pipe)`** — Elixir-style `|>` pipeline threading, spelled `pipe` since this project's reader treats a leading `|` as the start of a `|...|` piped identifier so a literal `|>` token isn't lexable: `(pipe x step ...)` threads `x` through each step left to right, a bare identifier step `f` called as `(f acc)` and a list step `(f arg ...)` called as `(f acc arg ...)` — e.g. `(pipe 5 (+ 1) (* 2) -)` → `-12`; a file-based `.sld` library (`modules/creme/pipe.sld`), not compiled into the interpreter binary
- **`(creme process)`** — `process-run` to run external commands (`command-line` is in `(scheme process-context)`)
- **`(creme raft)`** — replicated state machines via the [raft.cr](https://github.com/threez/raft.cr) shard: `raft-node` wires together a `raft-state-machine` (three Scheme procedures — apply/snapshot/restore, commands and responses round-tripping as bytevectors), a `raft-log-in-memory`/`raft-log-file`, and a `raft-transport-in-memory`/`raft-transport-tcp`, tuned by an optional `raft-config` alist; `raft-start!`/`raft-stop!` control the node, `raft-propose!`/`raft-read` submit commands (leader-only, blocking until committed), `raft-add-peer!`/`-add-learner!`/`-promote-learner!`/`-remove-peer!` change membership, and `raft-leader`/`raft-role`/`raft-metrics` observe cluster state — `raft-await-leader!` blocks until one of a list of nodes becomes leader, since this dialect has no general-purpose sleep primitive to poll with; see `(creme raft-machine)` for declarative sugar over this, or `examples/37-raft-kv-store.scm` for a complete demo
- **`(creme raft-machine)`** — declarative sugar over `(creme raft)`: `raft-sexp->bytevector`/`raft-bytevector->sexp` for the write/read codec every command needs, `(raft-commands (pattern body ...) ...)` builds an `apply-proc` that decodes, dispatches on the command's head symbol, re-encodes the result, and transparently no-ops `raft-read`'s empty-bytevector linearizability probe, `raft-cluster` wires a flat list of node ids into one node per id with `peers` computed as "every other id", and `raft-noop-snapshot`/`raft-noop-restore` are ready-made no-op persistence hooks for demos/tests — a file-based `.sld` library (`modules/creme/raft-machine.sld`), not compiled into the interpreter binary
- **`(creme random)`** — SRFI-27 naming/contract: `random-real` (a float in `[0, 1)`), `random-integer` (`(random-integer n)` → an integer in `[0, n)`), `random-seed!`, `random-choice`, `random-shuffle`
- **`(creme regex)`** — SRFI-115 naming: `regexp`, `regexp-matches?`, `regexp-search`, `regexp-extract`, `regexp-replace`, `regexp-replace-all`, `regexp-split`, `regexp?`
- **`(creme sql)`** — SQLite access: `sql-open`, `sql-close`, `sql-execute`, `sql-query`, `sql-scalar`, `sql-connection?` — file-backed or `:memory:`
- **`(creme sxql)`** — SQL statement builder DSL, every export `sxql-`-prefixed (`sxql-select`/`sxql-insert-into`/`sxql-update`/`sxql-delete-from`, `sxql-where`/`sxql-join`/`sxql-group-by`/..., DDL, `sxql-yield` to render SQL + bound params, `sxql-select!` macro DSL) — pairs with `(creme sql)`; a file-based `.sld` library (`modules/creme/sxql.sld`), not compiled into the interpreter binary
- **`(creme string)`** — extends `(scheme base)`'s string builtins: `string-upcase`, `string-downcase`, `string-trim`, `string-split`, `string-join`, `string-replace`, `string-contains?`, `string-prefix?`, `string-suffix?`, `string-pad`/`string-pad-right`, `string-repeat`, `string-index-of`, `string-reverse`
- **`(creme time)`** — the original rich epoch-float time API (superseded by, but not replaced with, `(scheme time)`'s minimal contract), SRFI-19-adjacent naming: `current-time`, `time-year`/`time-month`/`time-day`/`time-hour`/`time-minute`/`time-second`, `time->string`, `string->time`, `time-add`, `time-difference`
- **`(creme treelist)`** — Racket-style [treelists](https://docs.racket-lang.org/reference/treelist.html): immutable sequences backed by an RRB (Relaxed Radix Balanced) tree, so `treelist-ref`/`-set`/`-add`/`-append`/`-insert`/`-delete`/`-take`/`-drop` are all O(log n). Immutable API — `treelist`, `make-treelist`, `empty-treelist`, `treelist?`/`treelist-empty?`/`treelist-length`, `treelist-ref`/`-first`/`-last`, `treelist-add`/`-cons`/`-set`/`-insert`/`-delete`, `treelist-take`/`-drop`/`-take-right`/`-drop-right`/`-sublist`/`-rest`, `treelist-append`/`-reverse`, `treelist-map`/`-filter`/`-for-each`/`-sort`, `treelist-member?`/`-index-of`/`-find`, and `list->treelist`/`treelist->list`/`vector->treelist`/`treelist->vector` — plus a full mutable `mutable-treelist` variant (`mutable-treelist-add!`/`-set!`/`-insert!`/`-delete!`/`-append!`/`-sort!`/… and `mutable-treelist-snapshot` for an O(1) immutable view). Chaperones/impersonators, the sequence protocol, and the `for/treelist` macros are not implemented
- **`(creme tui)`**, **`(creme http)`**, **`(creme rfc8439)`** — terminal UI primitives, an HTTP(S) client, and ChaCha20/Poly1305 AEAD encryption, respectively

A `(creme sql)` + `(creme sxql)` example:

```scheme
(import (creme sql) (creme sxql))

(define conn (sql-open ":memory:"))
(sql-execute conn "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
(sql-execute conn "INSERT INTO person (name, age) VALUES (?, ?)" "Alice" 30)

(define built
  (sxql-yield (sxql-select '(name age)
                (sxql-from 'person)
                (sxql-where (sxql->= 'age 18)))))

(apply sql-query conn (first built) (second built))
```

## Embedding

Beyond the quick-start shown under [Installation](#as-a-crystal-library), a host application embedding the interpreter for templating, rule-engine, or dataset-filtering use cases has a few more building blocks available.

### Injecting host data and isolating calls

`run_source`/`run_file` take optional `bindings`/`parent` arguments, for running one warm `Interpreter` many times — once per dataset row, rule evaluation, or template render — without state leaking between calls:

```crystal
interp = Scheme::Interpreter.new

rows.each do |row|
  bindings = {"name" => Scheme.to_scheme(row.name), "age" => Scheme.to_scheme(row.age)} of String => Scheme::SchemeValue
  result = Scheme.run_source(interp, "(> age 18)", bindings: bindings)
  puts Scheme.truthy?(result)
end
```

- Neither given: evaluates against `interp.global`, same as always — a script's own top-level `define`s persist for later calls (handy for a REPL-style session).
- `bindings` given: evaluates against a fresh, isolated child of `interp.global` (or of `parent`, if also given), seeded with the bindings and discarded after the call — nothing leaks into `interp.global` or a later call, even an empty `{}` counts as "isolate this call."
- `parent` given alone: evaluates directly against that env.
- Both given: a fresh child of `parent`, seeded with `bindings` — register expensive callbacks once on a reusable `parent` env (see below), then reuse it as the chain root for many cheap, isolated calls.

### Reading results back as native Crystal data

`Scheme.to_scheme`/`Scheme.from_scheme` convert between `Scheme::SchemeValue` and plain Crystal data (`Nil`, `Bool`, `Int64`, `Float64`, `String`, `Array`, `Hash(String, _)` — aliased as `Scheme::Convertible`), so a rule/filter/template's result can be read back without touching `SchemeValue` at all:

```crystal
result = Scheme.run_source(interp, "(filter active? people)", bindings: bindings)
Scheme.from_scheme(result) # => Array/Hash/String/Int64/Float64/Bool/nil, recursively
```

`Array`s convert to/from `SchemeVector`s; `Hash(String, _)`s convert to/from alists (`(key . value)` pairs, matching the `json`/`sql` module convention) — duplicate alist keys resolve first-occurrence-wins, matching `assoc`. `NIL` converts to Crystal `nil` (matching `json-read`'s existing `null`/`NIL` convention) — use `Scheme.list_to_a` directly instead when a value is known to be list-shaped and an empty result should read as `[]`.

### Registering host callbacks

`Env#define_fn` registers a Crystal callback as a callable Scheme procedure:

```crystal
interp.global.define_fn("lookup-tax-rate", 1, 1) do |args|
  Scheme.to_scheme(tax_table[args[0].as(Scheme::SchemeStr).value])
end
```

Callbacks are ordinary `SchemeValue`s (`Builtin`s), so they can also go straight into a per-call `bindings` hash instead of `interp.global`, without a separate API.

### Loading file-based libraries

`library_search_path` (an `Array(String)` of directories, empty by default) is where `(import (a b c))` looks for an `a/b/c.sld` file when `(a b c)` isn't a Crystal-native library — the mechanism `(creme sxql)` itself uses (`modules/creme/sxql.sld`):

```crystal
interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
```

A `.sld` file must contain exactly one top-level `(define-library (name ...) ...)` form whose name matches the path it was found at.

### Sandboxing untrusted rule/template content

For rule/template content from a less-trusted source (stored in a database, editable by end users), `Interpreter.sandboxed` gives safe-by-default construction — deny-all library imports, a finite step budget, captured (not real) stdout — so a host doesn't need to remember every knob:

```crystal
interp = Scheme::Interpreter.sandboxed(allowed_libraries: ["scheme base", "creme string", "scheme inexact"])
Scheme.run_source(interp, %[(import (scheme base) (creme string)) (string-upcase "hi")])
```

`Interpreter.new` itself defaults to today's unrestricted behavior (`allowed_libraries: nil`) for backward compatibility — use `.sandboxed` when embedding content you don't fully trust. `allowed_libraries` restricts `(import ...)` by space-joined library name (e.g. `"creme sql"` for `(creme sql)`, `"scheme base"` for `(scheme base)`) — note that `"scheme base"` itself is not implicitly allowed, so guest code needs it listed explicitly if it's expected to `(import (scheme base))`. `.sandboxed` defaults `auto_import_base: false` (unlike `Interpreter.new`), so guest code gets nothing for free, including `(scheme base)`/`(scheme write)` — every binding it uses must come from an `(import ...)` it's actually allowed to make; pass `auto_import_base: true` to `.sandboxed` to opt back into pre-binding those two (still bypassing `allowed_libraries`, since that binding happens at construction, before any script runs). `interp.available_libraries` lists every library name the interpreter currently knows about, for building a deny-list (`interp.available_libraries - ["creme process", "creme file", "creme sql", "creme env"]`). `interp.stdout` (an `IO`) redirects/captures/suppresses `display`/`write`/`newline`/`print`/`println` output — swap in an `IO::Memory` per render to capture a template's printed output, or just to keep guest code from writing to the host process's real stdout.

### Execution limits

`max_eval_depth` (existing) bounds non-tail recursion; `max_steps` additionally bounds every trampoline step, closing the one gap `max_eval_depth` doesn't cover — an infinite *tail*-recursive script. Both raise `Scheme::SchemeExecutionLimitError` (a `SchemeRuntimeError` subclass) when exceeded, distinguishable from an ordinary bug in the guest code:

```crystal
interp = Scheme::Interpreter.new(max_steps: 100_000)
```

`(exit ...)` raises a catchable `Scheme::SchemeExit` rather than terminating the host process — `src/main.cr` (the `creme` CLI) is the only place that translates it back into a real process exit.

### Known caveats

- `(define ...)` as a script's last top-level form returns the defined *symbol*, not its value — end a script with an explicit expression if you need its value back.
- `Scheme.from_scheme` never returns a bare Crystal `nil` from anything except `NIL` itself.
- `max_steps` resets per top-level form (per `run_source`/`run_file`/`apply` call), not once for an entire multi-form script.
- This is `import`-gating (via `allowed_libraries`), output redirection, and a step budget — not OS-level sandboxing. There's no CPU/memory ceiling beyond `max_steps`, and no protection against concurrent use of one `Interpreter` from multiple fibers (construct one per fiber instead).
- `define-syntax`/`syntax-rules` is unhygienic: template-introduced identifiers are not renamed, so they can capture (or be captured by) use-site identifiers of the same name. Same posture as `defmacro` — authors who need capture-avoidance should `gensym` template identifiers by hand.
- `parameterize` and `guard` cannot tail-call out of their body in the final position — both need to run cleanup (restoring parameter values, or letting the `rescue` boundary close) before returning to the caller, so the body's last form is evaluated as an ordinary (non-tail) call.
- `guard` never catches `SchemeExecutionLimitError` (the `max_eval_depth`/`max_steps` budget) — it's a host-configured ceiling, not a guest-catchable condition, so a script can't swallow it and keep running past its own budget. `(exit ...)`'s `SchemeExit` is likewise never caught, for the same host-vs-guest reason.
- **Exact/exact division now produces an exact rational, not a float** — `(/ 1 3)` returns `1/3`, not `0.3333333333333333` as in earlier versions. This is the correct R7RS behavior (exact arithmetic stays exact), but it's a breaking change if a script or test relied on the old inexact fallback. Use `exact->inexact` (or `inexact`) to force a float when you specifically want one.
- Rational literal syntax (`1/3` typed directly in source) is **not** supported by the reader — rationals can only be produced via arithmetic (`/`, `expt` with a negative exponent, `sqrt` of a non-perfect-square-denominator ratio, `inexact->exact`). Parsing rational literals from source is a deferred follow-up, not implemented yet.
- Division by an inexact (float) zero still raises `SchemeRuntimeError`, the same as division by exact zero — it does **not** produce `+inf.0`/`-inf.0`/`+nan.0` per IEEE-754 float semantics. `nan?`/`infinite?`/`finite?` exist and work correctly on floats produced other ways (e.g. via the `math` module), this is specifically about `/`'s own zero-divisor behavior, which is a deliberately deferred decision.
- `SchemeRational` is `Int64`-backed (matching `SchemeInt`), not arbitrary-precision — arithmetic that overflows `Int64` (including intermediate numerator/denominator products) raises `SchemeRuntimeError`, the same as integer overflow. Comparisons (`=`/`<`/etc.) are exact and overflow-safe internally regardless.
- `call/cc`/`call-with-current-continuation` implement **escape continuations only**, via a Crystal exception unwind — not full R7RS multi-shot/re-entrant continuations. A captured continuation can be invoked at most once, and only while its originating `call/cc` call is still on the (real) call stack (i.e. before `call/cc` has returned normally). This covers non-local exit, early return, and `guard`-style unwinding — the large majority of real-world call/cc use — but not `amb`-style backtracking or re-entrant/restartable generators. Invoking a continuation after its `call/cc` has already returned raises `SchemeRuntimeError` ("continuation invoked outside its dynamic extent") rather than resuming.
- `dynamic-wind` runs its before/after thunks correctly around normal return, an error, or a call/cc escape (including escaping past multiple nested `dynamic-wind` frames, innermost-first). What it does **not** do, matching the escape-only `call/cc` limitation above: re-fire `before` when a continuation captured *inside* a `dynamic-wind` call is invoked to re-enter it from *outside*, after that `dynamic-wind` call has already returned — true re-entrant continuations would be required for that, and invoking such a continuation instead raises the same "continuation invoked outside its dynamic extent" error rather than behaving incorrectly.
- `include`/`include-ci` inside a `define-library` body raise `"not yet implemented"` — deliberately deferred, not a bug. Every other `define-library` declaration kind (`export`, `import`, `begin`, `cond-expand`) works.
- Complex numbers have no arbitrary-precision or exact-rational real/imaginary components — real/imag are always `SchemeInt | SchemeRational | SchemeFloat`, so the same `Int64`-backed overflow behavior applies. Division and `magnitude`/`angle`/`make-polar` always produce an inexact (float) result, even for two exact-integer-component operands, since complex division/trigonometry isn't representable exactly in the rational tower.
- `sqrt` of a negative real returns a complex result (e.g. `(sqrt -4)` is `0.0+2.0i`), but there is no corresponding complex-aware `expt`/`log`/`asin`/etc. — those still only accept real arguments.

## Development

```sh
shards install                 # install dependencies (also vendors ameba for linting)
crystal spec                   # run the test suite
crystal tool format --check    # check formatting
lib/ameba/bin/ameba            # lint
```

`make` wraps these as `fmt`/`fmtcheck`/`spec`/`lint`/`fix`. Building requires the system SQLite3 library (already present on macOS; `apt install libsqlite3-dev` on Debian/Ubuntu), since the `sql` module links against it. The `jose` module links against system OpenSSL (via the `jose`/`ed25519` shards) — already present on macOS with no extra setup; `apt install libssl-dev` on Debian/Ubuntu if missing.

## License

MIT, see [LICENSE](LICENSE). © Vincent Landgraf.
