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

`LISP.run_source`/`LISP.run_file` are pure library entry points with no STDOUT/STDERR/process-exit side effects.

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
