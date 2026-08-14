# Introduction

**creme** is a [Scheme](https://www.scheme.org/) implementation written in
[Crystal](https://crystal-lang.org/). It follows the
[R7RS-small](https://small.r7rs.org/) standard and adds a large, practical
extension library. The interpreter is both a **standalone CLI/REPL** for running
Scheme programs and an **embeddable Crystal library** you can drop into a host
application.

## What you get

creme implements the large majority of R7RS-small — the library system, a
tail-call-optimized evaluator, hygienic `syntax-rules` macros,
`define-record-type`, a full exception system, multiple values, `call/cc`
(escape continuations), and a numeric tower with exact rationals and complex
numbers — plus a large, batteries-included extension library under the
`(creme …)` namespace (JSON, YAML, SQLite, HTTP, crypto, an actor system, an
FFI bridge, and more). See the full [Features](features.md) list and the
[Libraries reference](libraries.md).

It runs on two independent backends — the native Crystal interpreter
(`bin/creme`) and **icecreme**, a standalone self-hosting C11 bytecode VM —
see [Features](features.md#two-backends) for how the two relate.

## Project scope and status

creme is a research implementation with a deliberately honest scope. A few
areas are intentionally limited (escape-only `call/cc`, and more) — see
[Known caveats](known-caveats.md) and read them before relying on an edge
case, or before assuming something is a bug.

## Where to go next

- **See what it can do:** [Features](features.md)
- **Run your first program:** [Getting started](getting-started.md)
- **Learn the language:** [Language tour](language-tour.md)
- **Browse the standard library:** [Libraries](libraries.md)
- **Every CLI flag:** [CLI reference](cli-reference.md)
- **Embed creme in Crystal:** [Embedding](embedding.md)
- **The self-hosting VM:** [icecreme](icecreme.md)
- **Find your way around the source:** [Repository structure](repository-structure.md)
- **What's deliberately out of scope:** [Known caveats](known-caveats.md)
