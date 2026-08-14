# Features

The full feature list. For a quick taste see the [Language tour](language-tour.md);
for the complete standard-library surface see [Libraries](libraries.md).

## Language

- REPL and script execution, or embed the interpreter as a library.
- An R7RS `define-library`/`import` library system (see
  [Libraries](libraries.md)) — the interactive REPL auto-imports `(scheme base)`
  and `(scheme write)` for zero-friction live typing; scripts (files or piped
  stdin) follow strict R7RS and must `(import ...)` everything they use, same
  as a `define-library` body.
- Tail-call optimized eval/apply loop, closures,
  `let`/`let*`/`letrec`/named-`let`/`let-values`/`let*-values`, `do`,
  `case`/`case-lambda`, `cond-expand`, `defmacro`,
  `define-syntax`/`syntax-rules` (hygienic — see [Known caveats](known-caveats.md)
  for the one narrow residual gap), `let-syntax`/`letrec-syntax`.
- `define-record-type`, `delay`/`delay-force`/`force`, `parameterize`,
  `dynamic-wind`.
- A full R7RS exception system: `guard`,
  `raise`/`raise-continuable`/`with-exception-handler`,
  `error`/`error-object?`/`error-object-message`/`error-object-irritants`,
  `file-error?`/`read-error?`.
- `values`/`call-with-values`/`define-values`.
- `call/cc`/`call-with-current-continuation` — **escape continuations only**,
  not full R7RS multi-shot continuations (see [Known caveats](known-caveats.md)).
- A full numeric tower including complex numbers: exact integers, exact
  rationals (`SchemeRational`, auto-reducing, e.g. `(/ 1 3)` is exact `1/3`),
  inexact floats, and complex numbers (`SchemeComplex`, reader literal syntax
  like `3+4i`/`2i`/`-i`, plus `(scheme complex)`'s
  `make-rectangular`/`make-polar`/`real-part`/`imag-part`/`magnitude`/`angle`)
  — with `exact?`/`inexact?`/`exact->inexact`/`inexact->exact`/`exact-integer?`/
  `rational?`/`numerator`/`denominator`/`gcd`/`lcm`/`nan?`/`infinite?`/
  `finite?`/`square` — see [Known caveats](known-caveats.md) for what's
  deliberately out of scope.
- Bytevectors: `#u8(...)` reader literal syntax,
  `bytevector`/`make-bytevector`/`bytevector-u8-ref`/`bytevector-u8-set!`/
  `bytevector-copy`/`bytevector-append`, byte-oriented ports
  (`open-input-bytevector`, `open-output-bytevector`, `read-u8`/`write-u8`),
  `utf8->string`/`string->utf8`.
- Quoting: `quote`, `` ` `` quasiquote, `,` unquote, `,@` unquote-splicing.
- Comments: `;` line comments, `#| ... |#` nestable block comments, `#;` datum
  comments.
- Ruby-flavored conveniences: a `(dialect ruby)` naming layer and a
  `#lang (creme syntax ruby)` concrete-syntax dialect.

## Standard library

A batteries-included standard library under the `(creme …)` namespace — JSON,
YAML, CSV, XML, SQLite, HTTP, crypto (digests, ciphers, PKey, X.509, JOSE),
regular expressions, an actor system, Raft consensus, an FFI bridge, and much
more. See the [Libraries reference](libraries.md) for the complete surface.

## Two backends

creme runs the same language on two independent engines:

1. **Native (`bin/creme`)** — the interpreter/compiler implemented in Crystal.
   This is the default and the most complete backend.
2. **icecreme** — a standalone, self-hosting C11 bytecode VM. creme can
   compile a program (and the compiler itself) to icecreme's compact
   bytecode, which icecreme then loads and runs with no Crystal process
   involved. See the [icecreme guide](icecreme.md) and `icecreme/README.md`.

Most programs run unchanged on both; a handful of libraries are native-only
and say so in their [library reference](libraries.md) entry.
