# Introduction

**creme** is a [Scheme](https://www.scheme.org/) implementation written in
[Crystal](https://crystal-lang.org/). It follows the
[R7RS-small](https://small.r7rs.org/) standard and adds a large, practical
extension library. The interpreter is both a **standalone CLI/REPL** for running
Scheme programs and an **embeddable Crystal library** you can drop into a host
application.

## What you get

- A complete R7RS-small language: the `define-library`/`import` library system, a
  tail-call-optimized evaluator, `syntax-rules` macros, `define-record-type`, a
  full exception system, multiple values, `call/cc` (escape continuations), and a
  numeric tower with exact rationals and complex numbers.
- A batteries-included standard library under the `(creme …)` namespace — JSON,
  YAML, CSV, XML, SQLite, HTTP, crypto (digests, ciphers, PKey, X.509, JOSE),
  regular expressions, an actor system, Raft consensus, an FFI bridge, and much
  more. See the [Libraries reference](libraries.md).
- Ruby-flavored conveniences: a `(dialect ruby)` naming layer and a
  `#lang (creme syntax ruby)` concrete-syntax dialect.

## Two backends

creme runs the same language on two independent engines:

1. **Native (`bin/creme`)** — the interpreter/compiler implemented in Crystal. This
   is the default and the most complete backend.
2. **icecreme** — a standalone, self-hosting C11 bytecode VM. creme can compile a
   program (and the compiler itself) to icecreme's compact bytecode, which
   icecreme then loads and runs with no Crystal process involved. See the
   [icecreme guide](icecreme.md) and `icecreme/README.md`.

Most programs run unchanged on both; a handful of libraries are native-only and
say so in their [library reference](libraries.md) entry.

## Project scope and status

creme is a research implementation with a deliberately honest scope. It
implements the large majority of R7RS-small, but a few areas are intentionally
limited (unhygienic macros, escape-only `call/cc`, `Int64`-backed rationals, and
more). These are documented up front in the README's **Known caveats** section —
read them before relying on an edge case.

## Where to go next

- **Run your first program:** [Getting started](getting-started.md)
- **Learn the language:** [Language tour](language-tour.md)
- **Browse the standard library:** [Libraries](libraries.md)
- **Every CLI flag:** [CLI reference](cli-reference.md)
- **Embed creme in Crystal:** [Embedding](embedding.md)
- **The self-hosting VM:** [icecreme](icecreme.md)
- **Find your way around the source:** [Repository structure](repository-structure.md)
