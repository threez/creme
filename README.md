# scheme.cr

A Scheme interpreter, written in Crystal. The interpreter library is the `creme` shard; the CLI/REPL executable is also called `creme`.

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

`Creme.run_source`/`Creme.run_file` are pure library entry points with no STDOUT/STDERR/process-exit side effects. See [Embedding](#embedding) below for injecting host data, reading results back as native Crystal types, registering host callbacks, sandboxing, and execution limits.

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

- **`(creme abbrev)`** — Ruby `Abbrev`-style unambiguous-abbreviation lookup: `(abbrev words)` builds an alist mapping every prefix of every word that uniquely identifies one word (plus each full word, always) to that word; `(abbrev-resolve alist prefix)` looks a prefix up — a file-based `.sld` library (`modules/creme/abbrev.sld`), not compiled into the interpreter binary
- **`(creme bigdecimal)`** — arbitrary-precision decimal arithmetic: `string->bigdecimal`, `integer->bigdecimal`, `bigdecimal-add`/`sub`/`mul`/`div`/`neg`, `bigdecimal-compare`, `bigdecimal=?`/`<?`/`>?`, `bigdecimal->string`, `bigdecimal?`
- **`(creme cgi)`** — Ruby `CGI`-style form-urlencoding/HTML-entity escaping and query-string parsing: `cgi-escape`/`cgi-unescape` (`application/x-www-form-urlencoded`), `cgi-escape-html` (delegates to `(creme html)`'s `html-escape`)/`cgi-unescape-html` (the 5 standard entities plus numeric character references), `cgi-parse` (a query string → an alist of `key → (value ...)`, repeated keys accumulating rather than last-wins) — a file-based `.sld` library (`modules/creme/cgi.sld`), not compiled into the interpreter binary
- **`(creme css)`** — a data-driven CSS builder with Sass-style nesting: a stylesheet is a plain list of rules — `(css->string '((body (font-family "sans-serif")) (".todo-app" (max-width "28rem") (".title" (color "#888")) ("&.done" (opacity "0.6")))))` — where a nested rule's selector is combined with its parent's (a descendant combinator by default, or `&`-prefixed for compound selectors like `&.active`/`&:hover`, no separating space) and emitted as its own separate top-level rule, comma-separated selector groups nest as the full cross-product, and `(raw ...)` passes content through verbatim (e.g. for an `@media` block); `(creme html)`'s `html-document->string` accepts either a plain CSS string or a `(creme css)` rule list for its `css` argument; `css!` is a `defmacro` counterpart of `css->string` that folds every part of a stylesheet free of `,expr`/`,@expr` into a plain string literal at macro-expansion time — since real stylesheets are almost always fully static, this usually precomputes the whole thing, at zero runtime cost — and `css-write!` is the same folding writing directly into an already-open port instead of building a string (e.g. for streaming an HTTP response body via `(creme mux)`) — a file-based `.sld` library (`modules/creme/css.sld`), not compiled into the interpreter binary
- **`(creme csv)`** — bulk `csv-read`/`csv-read-headers`/`csv-write`/`csv-write-headers` (rows decode to vectors of strings, or with headers to alists of `(header . cell)`, matching the `(creme json)` convention; cells to write may be strings, chars, numbers, or booleans) plus a row-by-row streaming API over ports — `csv-writer-open`/`csv-writer-row!`/`csv-writer?` and `csv-reader-open`/`csv-reader-read!`/`csv-reader?` (the latter returns `eof-object` at end of input) — all backed by Crystal's stdlib `CSV` parser/builder, with separator/quote-char/quoting (`'none`/`'rfc`/`'all`) all configurable
- **`(creme digest)`** — `digest-md5`, `digest-sha1`, `digest-sha256`, `digest-sha384`, `digest-sha512`, `hmac-sha256`/`-sha384`/`-sha512` (hex digest strings; the `hmac-*`/`digest-sha384`/`-sha512` procedures accept a bytevector OR a string for their arguments, unlike the original three string-only ones), `base64-encode`, `base64-decode`
- **`(creme secure-random)`** — Ruby `SecureRandom`, deliberately its own module distinct from `(creme random)`'s plain, non-cryptographic PRNG above: `secure-random-bytes` (→ a bytevector), `secure-random-hex`/`secure-random-base64` (→ hex/base64 strings of N random bytes) — backed by the OS's own CSPRNG (`Random::Secure` natively, OpenSSL's `RAND_bytes` in `icecreme`, the same primitive `(creme actor)`'s handshake nonces and `(creme rfc8439)`'s random-key/nonce already use), no new system dependency on either backend
- **`(creme cipher)`** — Ruby `OpenSSL::Cipher`, deliberately scoped to AES-256-GCM only (authenticated encryption, no raw CBC/ECB offered — the same AEAD-first cut `(creme rfc8439)` already made): `aes-256-gcm-encrypt key nonce plaintext [aad]` → an alist of `("ciphertext" . blob)`/`("tag" . blob)`; `aes-256-gcm-decrypt key nonce ciphertext tag [aad]` → the plaintext blob, raising on any tag/key/nonce/aad mismatch rather than ever returning corrupted data; `aes-256-gcm-random-key`/`-random-nonce` (32/12 bytes). Native drives OpenSSL's raw EVP AEAD API directly (Crystal's own high-level `OpenSSL::Cipher` wrapper has no GCM/AEAD support at all in this Crystal version — no way to feed it AAD or get/set an authentication tag — so `src/creme/modules/creme/cipher.cr` reopens Crystal's own `OpenSSL::LibCrypto` binding to add the one missing entry point, `EVP_CIPHER_CTX_ctrl`); `icecreme`'s own `cipher.c` drives the same EVP AEAD API directly in C. No new system dependency on either backend (both already link libcrypto)
- **`(creme env)`** — process environment variables (SRFI-98 naming where it exists): `get-environment-variable`, `get-environment-variables`, `set-environment-variable!`, `delete-environment-variable!`, `environment-variable-set?`
- **`(creme escm)`** — a minimal ERB-style template compiler for embedded Scheme (same `<% ... %>`/`<%= ... %>` syntax as Ruby's ERB, hence the style not the name): `<% ... %>` silent Scheme code, `<%= ... %>` a Scheme expression `display`ed unescaped, everything else literal text; `escm-compile`/`escm-render`/`escm-render-string` — locals are installed as fresh `(scheme eval)` bindings per render, so one compiled template renders safely and repeatedly with different locals — native `bin/creme` only (see the library's own header comment for why `icecreme/icecreme` doesn't support this yet) — a file-based `.sld` library (`modules/creme/escm.sld`), not compiled into the interpreter binary
- **`(creme extra)`** — this project's own non-R7RS conveniences, a file-based `.sld` library (`modules/creme/extra.sld`, pure R7RS Scheme, same as `(creme sxql)`) rather than compiled into the interpreter binary — never auto-imported, even in the REPL: SRFI-1-style list procedures (`filter`, `reduce`, `foldl`/`foldr`, `any`, `every`, `count`, `iota`, `partition`, `cons*`, `append-map`, `filter-map`, `last-pair`, `delete`/`delete!`), `print`/`println`, and legacy R5RS numeric aliases (`exact->inexact`, `inexact->exact`, `float?`) — note there is deliberately no `blob*` family here: `blob?`/`blob-size`/`blob->string`/`string->blob` were exact duplicates of the real R7RS bytevector procedures (`bytevector?`/`bytevector-length`/`utf8->string`/`string->utf8` — `SchemeBlob` *is* the bytevector type) and were removed; there's also no `eval-string` — `current-output-port`/`current-input-port`/`current-error-port` are genuine R7RS parameter objects, so "capture printed output while evaluating" is expressible portably via `(parameterize ((current-output-port p)) (eval ...))` plus `guard`, with no interpreter-specific helper needed (see `examples/24-tui-try-scheme.scm`'s `eval-source-line` for a worked example). Internal conveniences (`add1`/`sub1`/`1+`/`identity`/`range`/`last`, plus the extra cxr accessors `caddr`/`cdddr`/`cadddr` and the aliases `first`/`second`/`third`/`rest`) are defined in `@base_env` but aren't exported through any library — `caddr`/`cdddr`/`cadddr` are reachable portably via `(scheme cxr)` instead. The cxr accessors and their aliases are real builtins (not wrapper closures), so a direct `(cadr x)`/`(first x)` fuses into the single `Op::Cxr` instruction; `add1`/`range`/etc. still live in `interpreter/prelude.cr`, while the cxr set is installed as builtins/value-aliases (see `Interpreter#install_cxr_conveniences`).
- **`(creme ffi)`** — a generic `dlopen`/libffi bridge instead of a hand-written native module per C library: `(ffi-open "libm.so.6")` → a library handle, `(ffi-function lib "sqrt" 'double '(double))` → a callable handle for one function's name+signature, `(ffi-call fn (list 2.0))` → `1.4142135623730951`, `(ffi-close lib)`. MVP type-marshalling scope: `void` (return only), `int32`, `int64`, `double`, `bool`, `string`, `pointer` (an opaque handle round-tripped through a box). `ffi-pointer-ref`/`ffi-pointer-set!` read/write an individual struct FIELD given a pointer and that field's byte offset (`ffi-type-size` reports a type's byte size) — but this bridge never computes a struct's layout/alignment for you, and there's still no whole-struct-by-value marshalling or passing a Scheme closure as a C callback; see `icecreme/creme_ffi.c`'s own header comment for the exact non-goals. `ffi-gc-malloc` allocates scratch memory through this process's own Boehm GC heap instead of libc's malloc — reclaimed automatically once unreachable, no matching free ever required; `ffi-gc-free` is an optional early release, valid ONLY on a pointer `ffi-gc-malloc` itself returned (never on a libc-malloc'd pointer or one a C function handed back, e.g. a `FILE*`, which corrupts the GC's own heap bookkeeping). Implemented identically on both backends — native `bin/creme` (`src/creme/modules/creme/ffi.cr`) and `icecreme/icecreme` (`icecreme/creme_ffi.c`) — see `examples/39-ffi-libm-caller.scm`/`examples/40-ffi-struct-pointer-clock.scm`/`examples/41-ffi-record-file-handle.scm`. SECURITY: genuine native code execution with every memory-safety risk that comes with it — an embedder MUST exclude this from any `allowed_libraries` allowlist for untrusted guest scripts, same as `(creme tui)`/`(creme rfc8439)`/etc.
- **`(creme foreign)`** — declarative sugar over `(creme ffi)`, a file-based `.sld` library (`modules/creme/foreign.sld`), not compiled into the interpreter binary: `(define-foreign-function name lib c-name ret-type (arg-type ...))` turns the raw `ffi-function`+`ffi-call` boilerplate into an ordinary callable procedure (`(sqrt 2.0)` instead of `(ffi-call (ffi-function lib "sqrt" 'double '(double)) (list 2.0))`); `(define-foreign-struct type-name (accessor-name mutator-name field-type byte-offset) ...)` declares real struct-field accessors/mutators over `ffi-pointer-ref`/`ffi-pointer-set!` at explicit (caller-supplied, never auto-computed) byte offsets; `(define-foreign-record type-name (ctor-name lib c-name ret-type (arg-type ...)) pred-name (accessor-name lib c-name ret-type (arg-type ...)) ...)` wraps an opaque native handle (stdio's `FILE*`-style APIs, `sqlite3*`-style APIs) in a genuine, distinct Scheme record type (a real per-type predicate, via this interpreter's own `define-record-type`) whose accessors thread the wrapped pointer in as each underlying C function's first argument automatically. See the library's own header comment for the full contract (including why every macro here keeps its internal helper names confined to a private lexical scope rather than relying on macro hygiene, verified directly against this interpreter rather than assumed).
- **`(creme for)`** — a Racket-`for`-family iteration/comprehension library, a file-based `.sld` library (`modules/creme/for.sld`, pure R7RS Scheme, built with `define-syntax`/`syntax-rules` rather than `defmacro` since there's no static template content to fold) — sequence constructors `in-range`/`in-list`/`in-vector`/`in-string`, each returning an ordinary (eager, not lazy) list; `for`/`for/list` (side-effecting/collecting parallel iteration over one or more `(var seq)` clauses, zipped and stopping at the shortest, same as R7RS's own multi-list `map`/`for-each`); `for/vector`, `for/sum`, `for/product`; `for/and`/`for/or` (true short-circuit — body isn't evaluated past the deciding element); `for/first`/`for/last`; `for/fold` (general accumulation, supporting multiple accumulators via `(values ...)`); `for/alist` (builds a `(key . value)` alist — this project's own convention for object-shaped data — instead of a real `(creme hash-table)` object, to stay dependency-free); and `for*`/`for*/list`, the nested (Cartesian-product) counterparts of `for`/`for/list`. Deliberately self-contained (no dependency beyond `(scheme base)`, not even `(creme extra)`/`(creme hash-table)`) since a macro's expansion is analyzed against the calling site's own environment in this interpreter — a cross-library dependency inside a macro's template would force every caller of that macro to import the other library too, not just `(creme for)`.
- **`(creme ipaddr)`** — Ruby `IPAddr`-style IPv4/IPv6 address parsing/formatting/CIDR math: `make-ipaddr` (parses `"192.168.1.0/24"` or a bare `"192.168.1.1"`, `"fe80::/10"`/`"::1"` for ipv6, family autodetected), `ipaddr->string` (ipv6 canonical form per RFC 5952, longest zero run collapsed to `::`), `ipaddr-network`/`-broadcast`/`-netmask`/`-hostmask`, `ipaddr-include?` (CIDR containment), `ipaddr=?`/`-<?`, `ipaddr-succ`/`-pred` — internally a list of per-group integers rather than one combined address integer, since this interpreter's plain integers are fixnums that don't auto-promote to a bignum past ~2^62, too narrow for a full 128-bit IPv6 address (see the library's own header comment) — a file-based `.sld` library (`modules/creme/ipaddr.sld`), not compiled into the interpreter binary, no new builtins on either backend
- **`(creme introspection)`** — `macro?` and `gensym`, the two genuinely Crystal-level operations `(creme extra)` can't express in portable Scheme (a real R7RS `syntax-rules` transformer isn't a first-class runtime value, so there's no way to ask "is this a macro" at all; `gensym` has no R7RS analog since hygienic macro expansion generates fresh identifiers automatically)
- **`(creme file)`** — whole-file convenience helpers (`file-read`/`file-write`/`file-append`/`file-lines`/`file-size`, plus R7RS-exact `file-exists?`/`delete-file`) and R7RS port-based file I/O (`open-input-file`, `open-output-file`, `call-with-input-file`, `call-with-output-file`, `with-input-from-file`, `with-output-to-file`) — the latter compose with `(scheme base)`'s own `read-char`/`peek-char`/`read-line`/`read-string`/`write-char`/`write-string`/port procedures
- **`(creme hash-table)`** — `make-hash-table`, `hash-table?`, `hash-table-set!`, `hash-table-ref` (optional default value or thunk), `hash-table-delete!`, `hash-table-contains?`, `hash-table-keys`, `hash-table-values`, `hash-table->alist` — keys compared by `equal?`, not R7RS-small but a common practical need
- **`(creme html)`** — a Hiccup-style HTML5 builder: a page is plain nested list data (a "node") rather than imperative calls — `(html->string '(div (@ (class "x")) (p "hi")))` — with `(@ (name value) ...)` attribute blocks (`#t`/`#f` values for boolean/omitted attributes), automatic escaping, void-element self-closing (`br`, `img`, `input`, ...), `(raw ...)` for unescaped content, bare lists as spliced fragments (so `(map ...)` works directly as a run of children), and `html-document->string` for a full `<!DOCTYPE html>` document; also provides `html-style`, a `(creme table)` style function producing real `<table>`/`<thead>`/`<tbody>`/`<tfoot>` markup; `html!` is a `defmacro` counterpart of `html->string` that folds every part of a template free of `,expr`/`,@expr` into a plain string literal at macro-expansion time, leaving only the genuinely dynamic seams to render at runtime; `html-write!`/`html-document-write!` are port-targeting siblings of `html!`/`html-document->string` that write directly into an already-open port instead of building a string — e.g. `(creme mux)` accepts either a plain string or a one-argument procedure (called with a port wrapping the real HTTP response) as a route handler's response `"body"`, letting a large/dynamic page stream straight into the response instead of being materialized as one string first — a file-based `.sld` library (`modules/creme/html.sld`), not compiled into the interpreter binary
- **`(creme json)`** — `json-read`/`json-write` (JSON arrays decode to vectors, objects to alists)
- **`(creme logger)`** — Ruby `Logger`-style leveled logging to a port: five severity levels (`'debug` through `'fatal`), `logger-debug!`/`-info!`/`-warn!`/`-error!`/`-fatal!` (a no-op below the logger's own threshold), `logger-level-set!`/`logger-formatter-set!` — a file-based `.sld` library (`modules/creme/logger.sld`), not compiled into the interpreter binary
- **`(creme lr)`** — a from-scratch SLR(1) parser generator + driver: `(make-rule lhs rhs action)`/`(make-grammar start rules)` build a plain grammar (terminals/nonterminals told apart purely by which symbols appear as some rule's own `lhs`), `(build-parser grammar)` computes FIRST/FOLLOW sets, the canonical LR(0) item sets, and the resulting ACTION/GOTO tables — raising immediately on any shift/reduce or reduce/reduce conflict rather than resolving it, since this library deliberately has no precedence/associativity declarations (no bison-style `%left`/`%prec`); a grammar encodes operator precedence the classic way instead, via layered nonterminals — and `(lr-parse table tokens token-symbol token-value)` runs the shift-reduce driver, token representation left entirely to the caller. `(debug-states grammar)` inspects the raw item sets/states while tracking down a conflict. Backs `(creme syntax ruby)` below; see the library's own header comment for the full API and a worked tiny-arithmetic-grammar example
- **`(creme jose)`** — JOSE (JSON Object Signing and Encryption), backed by the [jose.cr](https://github.com/threez/jose.cr) shard (OpenSSL underneath): JWK generation/import/export (`jose-jwk-generate-oct`/`-ec`/`-rsa`/`-okp`, `jose-jwk-from-oct`/`-pem`/`-json`, `jose-jwk-to-pem`/`-json`/`-public`, `jose-jwk-with-kid`, `jose-jwk-kty`, `jose-jwk-public?`/`-private?`/`?`), JWS signing (`jose-jws-sign`/`-verify`, `-sign-detached`/`-verify-detached`, `-sign-json`/`-verify-json`), JWT issuing/verification with RFC 8725 checks (`jose-jwt-sign`, `jose-jwt-verify`), JWE encryption (`jose-jwe-encrypt`/`-decrypt`, `-password-encrypt`/`-decrypt`, `-json-encrypt`/`-json-decrypt`), and JWKS key sets (`jose-jwks-new`, `-to-public`, `-ref`, `-size`, `?`) — claims/headers round-trip as alists, matching the `(creme json)` convention; compact tokens are plain strings
- **`(creme math)`** — a superset of `(scheme inexact)`'s trig/log functions plus non-standard extras: `log2`, `log10`, `atan2`, `pow`, `hypot`, `pi`, `e`
- **`(creme matrix)`** — basic dense-matrix linear algebra (Ruby's bundled `Matrix`/`Vector`): `matrix-add`/`-sub`/`-scale`/`-multiply`/`-transpose`/`-trace`/`-determinant` (recursive cofactor expansion), `matrix-identity`/`-zero`, `matrix-ref`/`-set!` — a file-based `.sld` library (`modules/creme/matrix.sld`), not compiled into the interpreter binary
- **`(creme memoize)`** — function-result caching: `(memoize f)` wraps `f` so a repeat call with `equal?` arguments returns the cached result instead of calling `f` again (cache key is the whole argument list), `(memoize-forget! memoized-f arg ...)` deletes one cached entry so the next call with those arguments recomputes (for a caller that knows the data behind an argument list changed), and `(memoize-lru f max-size)` is a self-bounding variant that evicts the least-recently-used entry once full, needing no explicit invalidation — a file-based `.sld` library (`modules/creme/memoize.sld`), not compiled into the interpreter binary
- **`(creme pkey)`** — Ruby `OpenSSL::PKey::RSA`/`EC`: `rsa-generate-key [bits]` (default 2048)/`ec-generate-key [curve]` (`'p256`/`'p384`/`'p521`, default `'p256`) → a `<pkey>` handle; `pkey-public-key`/`pkey-private?`/`pkey-type`/`pkey?`; `pkey-sign`/`pkey-verify` (one shared procedure name for both RSA and EC, mirroring Ruby's shared `PKey#sign`/`#verify` — RSA uses PKCS1v1.5-SHA256, matching Ruby's own default; EC uses ECDSA-SHA256); `rsa-encrypt`/`rsa-decrypt` (RSA-OAEP-SHA256 only — deliberately not legacy PKCS1v1.5 encryption padding, the real padding-oracle-vulnerable case, unlike PKCS1v1.5 for signatures); `pkey->pem`/`pem->pkey` (auto-detecting RSA vs EC, private vs public). Crystal's stdlib has NO `OpenSSL::PKey` class hierarchy at all, so native reopens the vendored `jose.cr` shard's own `LibCryptoJose` FFI bindings (already proven correct by that shard's own JWK/JWS code) rather than re-declaring them from scratch; `icecreme`'s own `pkey.c` drives the same EVP_PKEY/RSA/EC_KEY C API directly, where it's simply part of `<openssl/evp.h>`/`<openssl/rsa.h>`/`<openssl/ec.h>`. A `<pkey>` handle holds its own PEM text rather than a live native key pointer — every operation reconstructs a transient key from that PEM, uses it once, and frees it immediately. No new system dependency on either backend
- **`(creme x509)`** — Ruby `OpenSSL::X509`: `x509-self-signed-certificate key subject-alist [days]` (default 365) and `x509-create-csr key subject-alist` (subject as a plain alist, e.g. `(("CN" . "example.com") ("O" . "My Org"))`) → cert/CSR handles; `x509-sign-csr csr ca-cert ca-key [days]` (a CA signs a CSR into a real chainable certificate); `x509-cert->pem`/`pem->x509-cert`; `x509-cert-subject`/`-issuer` (→ alist), `x509-cert-public-key` (→ a `(creme pkey)` handle), `x509-cert-not-before`/`-not-after` (→ epoch-second floats, matching `(creme time)`'s own convention); `x509-verify-chain cert ca-certs` → `#t` or raises with OpenSSL's own verification-failure reason. Every self-signed certificate gets a `basicConstraints CA:TRUE` extension (required for `x509-verify-chain` to accept it as a trust anchor at all). Native reopens Crystal's own `OpenSSL::LibCrypto` binding for every X.509/ASN.1 declaration it needs (neither Crystal's stdlib nor the vendored `jose.cr` shard bind a certificate-building/chain-verification surface — Crystal's own `openssl/x509/` subdirectory only has certificate *parsing*); `icecreme`'s own `x509.c` drives the same API directly in C. No new system dependency on either backend
- **`(creme ostruct)`** — Ruby `OpenStruct`-style dynamic-attribute records: `make-ostruct`/`ostruct` (a `defmacro` literal-field constructor)/`ostruct-ref`/`ostruct-set!`/`ostruct-delete!`/`ostruct->alist`/`ostruct-each` — field access is always an explicit procedure call, since Scheme has no `method_missing` to dispatch dot syntax through — a file-based `.sld` library (`modules/creme/ostruct.sld`), not compiled into the interpreter binary
- **`(creme pathname)`** — pure string path *parsing* (Ruby's `Pathname`), the reverse direction of `(creme path)`'s macro-folded path *building*: `pathname-dirname`/`-basename`/`-extname`/`-split`/`-join`/`-cleanpath`/`-parent`/`-each-filename`/`-sub-ext` — purely lexical, no filesystem access at all (that's `(creme file)`'s job) — a file-based `.sld` library (`modules/creme/pathname.sld`), not compiled into the interpreter binary
- **`(creme pipe)`** — Elixir-style `|>` pipeline threading, spelled `pipe` since this project's reader treats a leading `|` as the start of a `|...|` piped identifier so a literal `|>` token isn't lexable: `(pipe x step ...)` threads `x` through each step left to right, a bare identifier step `f` called as `(f acc)` and a list step `(f arg ...)` called as `(f acc arg ...)` — e.g. `(pipe 5 (+ 1) (* 2) -)` → `-12`; a file-based `.sld` library (`modules/creme/pipe.sld`), not compiled into the interpreter binary
- **`(creme prime)`** — Ruby `Prime`-style primality/factorization: `prime?`, `next-prime`, `prime-factors` (ascending `(base . exponent)` pairs), `primes-upto` (Sieve of Eratosthenes) — plain trial division, not Miller-Rabin, so fine for ordinary integers but not cryptographic-scale ones — a file-based `.sld` library (`modules/creme/prime.sld`), not compiled into the interpreter binary
- **`(creme process)`** — `process-run` to run external commands (`command-line` is in `(scheme process-context)`)
- **`(creme pstore)`** — Ruby `PStore`-style single-file persistent key-value store, backed by this project's own `write`/`read` round-tripping a whole alist verbatim: `pstore-open`, `pstore-transaction!` (commits on a normal return, discards on `(pstore-abort!)` or any other exception), `pstore-ref`/`-set!`/`-delete!`/`-roots`/`-root?` — no file locking, so concurrent writers can race, same caveat Ruby's own PStore gives; native `bin/creme` only (see the library's own header comment for why `icecreme/icecreme`'s `read` doesn't support this unmodified) — a file-based `.sld` library (`modules/creme/pstore.sld`), not compiled into the interpreter binary
- **`(creme raft)`** — replicated state machines, transparently backed by one of two implementations depending on which VM is running: the real [raft.cr](https://github.com/threez/raft.cr) shard FFI binding on native `creme`, or a from-scratch pure-Scheme engine (actors + SQLite, see `(creme raft-scheme)` below) under `icecreme` (which has no `raft.cr` FFI at all). `modules/creme/raft.sld` picks between them via `(cond-expand ((library (creme builtin raft)) ...) (else ...))` — `(creme builtin raft)` is only ever resolvable where `raft.cr`'s FFI code is actually compiled in, so this needs no new feature identifier on either runtime; see that file's own header comment for the full mechanism. Either way, the same surface: `raft-node` wires together a `raft-state-machine` (three Scheme procedures — apply/snapshot/restore, commands and responses round-tripping as bytevectors), a `raft-log-in-memory`/`raft-log-file`, and a `raft-transport-in-memory`/`raft-transport-tcp` (TCP only on the native/FFI backend), tuned by an optional `raft-config` alist; `raft-start!`/`raft-stop!` control the node, `raft-propose!`/`raft-read` submit commands (leader-only, blocking until committed), `raft-add-peer!`/`-add-learner!`/`-promote-learner!`/`-remove-peer!` change membership, and `raft-leader`/`raft-role`/`raft-metrics` observe cluster state — `raft-await-leader!` blocks until one of a list of nodes becomes leader, since this dialect has no general-purpose sleep primitive to poll with; see `(creme raft-machine)` for declarative sugar over this, or `examples/37-raft-kv-store.scm` for a complete demo runnable unchanged via both `./bin/creme` and `./icecreme/icecreme`
- **`(creme raft-machine)`** — declarative sugar over `(creme raft)`: `raft-sexp->bytevector`/`raft-bytevector->sexp` for the write/read codec every command needs, `(raft-commands (pattern body ...) ...)` builds an `apply-proc` that decodes, dispatches on the command's head symbol, re-encodes the result, and transparently no-ops `raft-read`'s empty-bytevector linearizability probe, `raft-cluster` wires a flat list of node ids into one node per id with `peers` computed as "every other id", and `raft-noop-snapshot`/`raft-noop-restore` are ready-made no-op persistence hooks for demos/tests — a file-based `.sld` library (`modules/creme/raft-machine.sld`), not compiled into the interpreter binary
- **`(creme raft-scheme)`** — the pure-Scheme engine `(creme raft)` transparently dispatches to under `icecreme` (see above) — a from-scratch Raft implementation (no FFI, unlike `raft.cr`'s shard binding) under its own `raft-scheme-*`-prefixed names, for anyone who wants it directly without going through `(creme raft)`'s dispatch: one actor (`(creme actor)`) per node instead of Crystal fibers/channels, log/metadata/snapshots persisted to SQLite (`(creme sql)`) instead of a bespoke binary format — so it's the ONE Raft implementation in this repo that also runs under `icecreme` (see `icecreme/README.md`; `(creme raft)` has no icecreme-native counterpart at all). Same shape as `(creme raft)`: `raft-scheme-node`/`raft-scheme-start!`/`-stop!`, `raft-scheme-propose!`/`-read` (plain s-expressions, no bytevector codec needed), `raft-scheme-add-peer!`/`-remove-peer!`/`-add-learner!`/`-promote-learner!`, `raft-scheme-snapshot!`, `raft-scheme-metrics`/`-role`/`-leader`, `raft-scheme-transport-partition!`/`-heal!` for partition testing, and `raft-scheme-cluster` for the "one node per id, peers computed automatically" convenience. Includes leader election with pre-vote, log replication, snapshotting/compaction, and single-server-at-a-time membership changes; deliberately no RTT auto-tuning and no TCP/Unix wire transport (`(creme actor)`'s own `start-node 'tcp`/`'unix` already covers distribution). The engine itself (`modules/creme/raft-scheme/core.scm`) has no `import`/`define-library` header — it's spliced into `modules/creme/raft-scheme.sld` via `(include ...)` for native, or included directly (after a plain `(import ...)` line naming the needed builtin families) by an icecreme-facing script — see its own header comment for the full design and every documented limitation; `examples/39-raft-scheme-kv-store.scm` runs unchanged under both `./bin/creme` and `./icecreme/icecreme`
- **`(creme random)`** — SRFI-27 naming/contract: `random-real` (a float in `[0, 1)`), `random-integer` (`(random-integer n)` → an integer in `[0, n)`), `random-seed!`, `random-choice`, `random-shuffle`
- **`(creme regex)`** — SRFI-115 naming: `regexp`, `regexp-matches?`, `regexp-search`, `regexp-extract`, `regexp-replace`, `regexp-replace-all`, `regexp-split`, `regexp?`
- **`(creme set)`** — a mutable hash-set (plus a `SortedSet` variant) over `(creme hash-table)`: `set-add!`/`-delete!`/`-member?`/`-union`/`-intersection`/`-difference`/`-symmetric-difference`/`-subset?`/`-superset?`/`-disjoint?`/`-equal?`/`-merge!`, `sorted-set`/`sorted-set-add!`/`sorted-set->list` (always ascending, via `(creme sort)`) — a file-based `.sld` library (`modules/creme/set.sld`), not compiled into the interpreter binary
- **`(creme sql)`** — SQLite access: `sql-open`, `sql-close`, `sql-execute`, `sql-query`, `sql-scalar`, `sql-connection?` — file-backed or `:memory:`
- **`(creme sxql)`** — SQL statement builder DSL, every export `sxql-`-prefixed (`sxql-select`/`sxql-insert-into`/`sxql-update`/`sxql-delete-from`, `sxql-where`/`sxql-join`/`sxql-group-by`/..., DDL, `sxql-yield` to render SQL + bound params, `sxql-select!` macro DSL) — pairs with `(creme sql)`; a file-based `.sld` library (`modules/creme/sxql.sld`), not compiled into the interpreter binary
- **`(creme string)`** — extends `(scheme base)`'s string builtins: `string-upcase`, `string-downcase`, `string-trim`, `string-split`, `string-join`, `string-replace`, `string-contains?`, `string-prefix?`, `string-suffix?`, `string-pad`/`string-pad-right`, `string-repeat`, `string-index-of`, `string-reverse`
- **`(creme tempfile)`** — Ruby `Tempfile`-style scratch files under `TMPDIR`: `make-tempfile`, `tempfile-path`/`-port`/`-close!`/`-unlink!`, `call-with-tempfile` (guarantees close+unlink via `dynamic-wind`, even if its block raises) — a file-based `.sld` library (`modules/creme/tempfile.sld`), not compiled into the interpreter binary
- **`(creme time)`** — the original rich epoch-float time API (superseded by, but not replaced with, `(scheme time)`'s minimal contract), SRFI-19-adjacent naming: `current-time`, `time-year`/`time-month`/`time-day`/`time-hour`/`time-minute`/`time-second`, `time->string`, `string->time`, `time-add`, `time-difference`
- **`(creme treelist)`** — Racket-style [treelists](https://docs.racket-lang.org/reference/treelist.html): immutable sequences backed by an RRB (Relaxed Radix Balanced) tree, so `treelist-ref`/`-set`/`-add`/`-append`/`-insert`/`-delete`/`-take`/`-drop` are all O(log n). Immutable API — `treelist`, `make-treelist`, `empty-treelist`, `treelist?`/`treelist-empty?`/`treelist-length`, `treelist-ref`/`-first`/`-last`, `treelist-add`/`-cons`/`-set`/`-insert`/`-delete`, `treelist-take`/`-drop`/`-take-right`/`-drop-right`/`-sublist`/`-rest`, `treelist-append`/`-reverse`, `treelist-map`/`-filter`/`-for-each`/`-sort`, `treelist-member?`/`-index-of`/`-find`, and `list->treelist`/`treelist->list`/`vector->treelist`/`treelist->vector` — plus a full mutable `mutable-treelist` variant (`mutable-treelist-add!`/`-set!`/`-insert!`/`-delete!`/`-append!`/`-sort!`/… and `mutable-treelist-snapshot` for an O(1) immutable view). Chaperones/impersonators, the sequence protocol, and the `for/treelist` macros are not implemented
- **`(creme tsort)`** — Ruby `TSort`-style topological sort: `tsort` (dependencies-first order, raising on a cycle), `tsort?` (checks first instead of raising), `tsort-strongly-connected-components` (Tarjan's algorithm — a cycle collapses into one multi-node component instead of raising) — a file-based `.sld` library (`modules/creme/tsort.sld`), not compiled into the interpreter binary
- **`(creme tui)`**, **`(creme http)`**, **`(creme rfc8439)`** — terminal UI primitives, an HTTP(S) client, and ChaCha20/Poly1305 AEAD encryption, respectively
- **`(creme uri)`** — Ruby `URI`-style parsing/building/reference-resolution: `uri-parse`/`uri->string`, `uri-scheme`/`-userinfo`/`-host`/`-port`/`-path`/`-query`/`-fragment`, `uri-encode-www-form`/`-decode-www-form` (one `(key . value)` pair per occurrence, matching Ruby exactly — unlike `(creme cgi)`'s grouping `cgi-parse`), `uri-join` (full RFC 3986 §5.3 reference resolution, §5.2.4's `remove_dot_segments` included) — native `bin/creme` only (see the library's own header comment for why `icecreme/icecreme`'s regex engine doesn't support this unmodified) — a file-based `.sld` library (`modules/creme/uri.sld`), not compiled into the interpreter binary
- **`(creme xml)`** — a minimal well-formed-XML reader/writer (a useful subset of Ruby's `REXML`): `xml-read`/`xml-read-port` parse into exactly `(creme html)`'s own node shape (`(tag (@ (name value) ...) child ...)`), so a parsed document is directly usable anywhere an html node is; `xml-write`/`xml->string` serialize back, self-closing any childless element; no DTD/namespace/CDATA support — a file-based `.sld` library (`modules/creme/xml.sld`), not compiled into the interpreter binary
- **`(creme yaml)`** — `yaml-read`/`yaml-write` for a single YAML document (mappings decode to alists, sequences to vectors, matching the `(creme json)` convention; multi-document streams out of scope): native `bin/creme` backs this with Crystal's stdlib `YAML` module, `icecreme/icecreme` wraps libyaml directly — both ultimately the same underlying C library either way. A plain (unquoted) scalar is resolved per YAML's core-schema conventions (bool words `yes`/`no`/`on`/`off` included, `0x`/`0o`/leading-zero-octal/underscored integers, `.inf`/`.nan`); a quoted or block-style scalar always stays a string

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

### `(dialect ruby)`: Ruby-familiar naming over the stdlib

A file-based library (`modules/dialect/ruby.sld`, pure R7RS Scheme, same as `(creme extra)`/`(creme sort)`) giving Ruby-familiar procedure names over the existing R7RS/`(creme ...)` stdlib — no new semantics, just naming, since this is a naming/onboarding aid for people coming from Ruby, not a second implementation of anything: `puts`/`print`/`p`, generic `to_s`/`to_i`/`to_f`/`inspect`, generic `length`/`size`/`empty?`/`each`/`each_with_index`/`reverse`/`include?`/`first`/`last` (dispatching across string/vector/hash-table/list by runtime type), string helpers (`upcase`/`downcase`/`strip`/`split`/`start_with?`/`end_with?`/`gsub`/`chars`/`index`/`ljust`/`rjust`), array helpers over plain lists (`select`/`reject`/`collect`/`inject`/`reduce`, `push`/`pop`/`shift`/`unshift` — pure functions returning a new list rather than true in-place mutation, `flatten`/`uniq`/`sort`/`min`/`max`/`sum`/`count`/`compact`/`zip`/`join`), hash helpers over `(creme hash-table)` (`keys`/`values`/`has_key?`/`key?`/`delete`/`each_pair`/`to_a`/`merge`), and numeric helpers (`times`/`upto`/`downto`/`step` plus re-exports of `even?`/`odd?`/`zero?`/`positive?`/`negative?`/`abs`/`round`/`ceil`/`floor`) — `each`/`each_with_index` are receiver-first (`(each coll proc)`) while `map`/`select`/`reject`/`inject` keep the stdlib's existing proc-first order to avoid silently changing `map`/`for-each`'s calling convention if a script also imports `(scheme base)`; `values` is Ruby's `Hash#values` (R7RS's own multiple-return `values` is still reachable as `r7rs-values`); `do` is a `(do (param ...) body ...)` macro expanding to `(lambda (param ...) body ...)` — but this **shadows the real R7RS `do` loop** for the rest of any script that imports `(dialect ruby)`, including indirectly (e.g. `(creme extra)`'s `times` macro expands to a real `do` loop at its call site and breaks once `do` is shadowed); the six proc-last operations `each`/`each_with_index`/`times`/`upto`/`downto`/`step` additionally fuse this into a bare, no-extra-parens block form at their own call site — `(each lst do (x) (puts x))`, reading close to Ruby's `lst.each do |x| ... end` — which makes those six macros rather than plain procedures (each has a same-named `-proc` sibling — `each-proc`, `times-proc`, etc. — also exported, for whenever a first-class procedure value is still needed); `times`/`upto`/`downto`/`step` are these macros, distinct from `(creme extra)`'s own side-effect-only `times` macro; these six loop operations are purely for side effects and return void (`'()`, matching what `for-each`/`(when #f ...)` already return in this project) rather than `#f` — see the library's own header comment for the full rationale and every naming/collision tradeoff made.

### `(creme syntax ruby)`: a minimal Ruby-flavored `#lang` dialect

A `#lang (creme syntax ruby)` file (see `src/creme/runner.cr`'s `#lang` header handling — a literal first line `#lang <library-name> <extra-args>...` imports that library and calls its exported `read-program` to parse the rest of the file) gets real Ruby-looking concrete syntax, not just the renamed procedures `(dialect ruby)` above provides: `def`/`end` methods, `if`/`elsif`/`else`/`end`, `unless`/`end`, `while`/`end`, `name = expr` assignment, no-paren and dotted method calls, `do |x| ... end` blocks, string interpolation, and integer/float/string/symbol/array/`nil`/`true`/`false` literals with the usual `+-*/% < > <= >= == != && || !` operators — translating down to plain Scheme forms that call into `(dialect ruby)`. Built on `(creme lr)` above (a real SLR(1) grammar, not a hand-written recursive-descent parser like `(creme syntax scss)`/`(creme syntax slim)` use for their own line/indentation-shaped dialects, since Ruby genuinely needs infix expression precedence).

```ruby
#lang (creme syntax ruby)
def greet(name)
  if name
    puts "Hello, #{name}!"
  else
    puts "Hello, stranger"
  end
end

greet("World")

[1, 2, 3].each do |n|
  puts n * 2
end
```

Deliberately a small, real subset, not a second Ruby implementation — no classes, exceptions, `case`/`when`, multiple assignment, ranges, hashes, heredocs, or `{ }` blocks (only `do`/`end`); `nil`/`false` both compile to Scheme's `#f`; a no-paren call is its own statement (can't nest inside a larger expression or take a trailing block) and its arguments can't start with unary `-`/`!` or be another no-paren call; `name(args)` requires the `(` immediately adjacent to `name` (`name (args)`, with a space, is instead a no-paren call whose one argument happens to be parenthesized) — every tradeoff, and why, is documented in `modules/creme/syntax/ruby.sld`'s own header comment (LIMITATIONS section).

## Embedding

Beyond the quick-start shown under [Installation](#as-a-crystal-library), a host application embedding the interpreter for templating, rule-engine, or dataset-filtering use cases has a few more building blocks available.

### Injecting host data and isolating calls

`run_source`/`run_file` take optional `bindings`/`parent` arguments, for running one warm `Interpreter` many times — once per dataset row, rule evaluation, or template render — without state leaking between calls:

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

### Reading results back as native Crystal data

`Creme.to_scheme`/`Creme.from_scheme` convert between `Creme::SchemeValue` and plain Crystal data (`Nil`, `Bool`, `Int64`, `Float64`, `String`, `Array`, `Hash(String, _)` — aliased as `Creme::Convertible`), so a rule/filter/template's result can be read back without touching `SchemeValue` at all:

```crystal
result = Creme.run_source(interp, "(filter active? people)", bindings: bindings)
Creme.from_scheme(result) # => Array/Hash/String/Int64/Float64/Bool/nil, recursively
```

`Array`s convert to/from `SchemeVector`s; `Hash(String, _)`s convert to/from alists (`(key . value)` pairs, matching the `json`/`sql` module convention) — duplicate alist keys resolve first-occurrence-wins, matching `assoc`. `NIL` converts to Crystal `nil` (matching `json-read`'s existing `null`/`NIL` convention) — use `Creme.list_to_a` directly instead when a value is known to be list-shaped and an empty result should read as `[]`.

### Registering host callbacks

`Env#define_fn` registers a Crystal callback as a callable Scheme procedure:

```crystal
interp.global.define_fn("lookup-tax-rate", 1, 1) do |args|
  Creme.to_scheme(tax_table[args[0].as(Creme::SchemeStr).value])
end
```

Callbacks are ordinary `SchemeValue`s (`Builtin`s), so they can also go straight into a per-call `bindings` hash instead of `interp.global`, without a separate API.

### Loading file-based libraries

`library_search_path` (an `Array(String)` of directories, empty by default) is where `(import (a b c))` looks for an `a/b/c.sld` file when `(a b c)` isn't a Crystal-native library — the mechanism `(creme sxql)` itself uses (`modules/creme/sxql.sld`):

```crystal
interp = Creme::Interpreter.new(library_search_path: ["./modules"])
```

A `.sld` file must contain exactly one top-level `(define-library (name ...) ...)` form whose name matches the path it was found at.

### Sandboxing untrusted rule/template content

For rule/template content from a less-trusted source (stored in a database, editable by end users), `Interpreter.sandboxed` gives safe-by-default construction — deny-all library imports, a finite step budget, captured (not real) stdout — so a host doesn't need to remember every knob:

```crystal
interp = Creme::Interpreter.sandboxed(allowed_libraries: ["scheme base", "creme string", "scheme inexact"])
Creme.run_source(interp, %[(import (scheme base) (creme string)) (string-upcase "hi")])
```

`Interpreter.new` itself defaults to today's unrestricted behavior (`allowed_libraries: nil`) for backward compatibility — use `.sandboxed` when embedding content you don't fully trust. `allowed_libraries` restricts `(import ...)` by space-joined library name (e.g. `"creme sql"` for `(creme sql)`, `"scheme base"` for `(scheme base)`) — note that `"scheme base"` itself is not implicitly allowed, so guest code needs it listed explicitly if it's expected to `(import (scheme base))`. `.sandboxed` defaults `auto_import_base: false` (unlike `Interpreter.new`), so guest code gets nothing for free, including `(scheme base)`/`(scheme write)` — every binding it uses must come from an `(import ...)` it's actually allowed to make; pass `auto_import_base: true` to `.sandboxed` to opt back into pre-binding those two (still bypassing `allowed_libraries`, since that binding happens at construction, before any script runs). `interp.available_libraries` lists every library name the interpreter currently knows about, for building a deny-list (`interp.available_libraries - ["creme process", "creme file", "creme sql", "creme env"]`). `interp.stdout` (an `IO`) redirects/captures/suppresses `display`/`write`/`newline`/`print`/`println` output — swap in an `IO::Memory` per render to capture a template's printed output, or just to keep guest code from writing to the host process's real stdout.

### Execution limits

`max_eval_depth` (existing) bounds non-tail recursion; `max_steps` additionally bounds every trampoline step, closing the one gap `max_eval_depth` doesn't cover — an infinite *tail*-recursive script. Both raise `Creme::SchemeExecutionLimitError` (a `SchemeRuntimeError` subclass) when exceeded, distinguishable from an ordinary bug in the guest code:

```crystal
interp = Creme::Interpreter.new(max_steps: 100_000)
```

`(exit ...)` raises a catchable `Creme::SchemeExit` rather than terminating the host process — `src/main.cr` (the `creme` CLI) is the only place that translates it back into a real process exit.

### Known caveats

- `(define ...)` as a script's last top-level form returns the defined *symbol*, not its value — end a script with an explicit expression if you need its value back.
- `Creme.from_scheme` never returns a bare Crystal `nil` from anything except `NIL` itself.
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

`make` wraps these as `fmt`/`fmtcheck`/`spec`/`lint`/`fix`. Building requires the system SQLite3 library (already present on macOS; `apt install libsqlite3-dev` on Debian/Ubuntu), since the `sql` module links against it. The `jose` module links against system OpenSSL (via the `jose`/`ed25519` shards) — already present on macOS with no extra setup; `apt install libssl-dev` on Debian/Ubuntu if missing. The `yaml` module links against system libyaml (via Crystal's own bundled `YAML` stdlib module) — already present on macOS with no extra setup; `apt install libyaml-dev` on Debian/Ubuntu if missing. `icecreme` links libyaml directly too (see `icecreme/README.md`), so this is a build-time dependency for both backends.

## License

MIT, see [LICENSE](LICENSE). © Vincent Landgraf.
