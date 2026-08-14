![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)

# creme

**creme** is a small, practical [Scheme](https://www.scheme.org/) implementation
written in [Crystal](https://crystal-lang.org/), following R7RS-small. It's
both a standalone CLI/REPL and an embeddable library, with a large,
batteries-included extension library and a second, self-hosting C11 VM
backend (**icecreme**) that runs the same bytecode with no Crystal process
involved.

```scheme
(define (fact n) (if (<= n 1) 1 (* n (fact (- n 1)))))
(write (fact 10)) (newline) ; => 3628800

(define (make-counter)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(write (list (c) (c) (c))) (newline) ; => (1 2 3)

(write (map (lambda (x) (* x x)) '(1 2 3 4))) (newline) ; => (1 4 9 16)

(write (/ 1 3)) (newline) ; => 1/3 (exact, not 0.333...)

(define-record-type point (make-point x y) point? (x point-x) (y point-y))
(write (point-x (make-point 3 4))) (newline) ; => 3

(write (guard (e (#t (list 'caught (error-object-message e))))
         (error "boom"))) (newline) ; => (caught "boom")
```

More in the [Language tour](doc/guide/language-tour.md), and 50+ runnable
programs under [`examples/`](examples/).

## Features

- A complete R7RS-small language — library system, tail calls, hygienic
  `syntax-rules`, `define-record-type`, a full exception system, multiple
  values, `call/cc` (escape continuations), and a numeric tower with exact
  rationals and complex numbers.
- A batteries-included `(creme …)` standard library — JSON, YAML, CSV, XML,
  SQLite, HTTP, crypto (digests, ciphers, PKey, X.509, JOSE), regex, an actor
  system, Raft consensus, an FFI bridge, and more.
- Two backends: the native Crystal interpreter, and **icecreme**, a
  standalone self-hosting C11 bytecode VM.
- Embed it as a Crystal library, or link `libcreme.a` into a C program.
- Ruby-flavored conveniences: a `(dialect ruby)` naming layer and a
  `#lang (creme syntax ruby)` concrete-syntax dialect.

See the full [Features](doc/guide/features.md) list for everything above in
detail, and [Known caveats](doc/guide/known-caveats.md) for what's
deliberately out of scope (e.g. `call/cc` is escape-only, not full multi-shot
continuations).

## Benchmarks

A sample from `make bench-md`'s output — single-threaded wall-clock time in
seconds, lower is better. Native-language floors (Crystal, Go) are included
for context; see [`benchmarks/amd64_freebsd.md`](benchmarks/amd64_freebsd.md)
for the full table (more workloads, more languages), the environment it ran
on, and how to regenerate it on your own machine.

| workload                | crystal | go      | node    | luajit  | racket  | guile   | icecreme | creme   | ruby    |
| ------------------------ | ------- | ------- | ------- | ------- | ------- | ------- | -------- | ------- | ------- |
| fib(27)                  | 0.00054 | 0.00060 | 0.00153 | 0.00144 | 0.00085 | 0.00308 |  0.00935 | 0.03069 | 0.01010 |
| record-test(500000)      | 0.00348 | 0.01011 | 0.00684 | 0.05522 | 0.01180 | 0.01154 |  0.03677 | 0.06148 | 0.09714 |
| nqueens(9)                | 0.00048 | 0.00051 | 0.00113 | 0.00200 | 0.00078 | 0.00107 |  0.00882 | 0.01323 | 0.01187 |
| **total** (all 9 workloads) | 0.04578 | 0.10587 | 0.07660 | 0.11843 | 0.12980 | 0.13703 |  0.15998 | 0.27220 | 0.32783 |

## Quick start

```sh
shards install
shards build
./bin/creme path/to/script.scm     # run a script
./bin/creme                        # start the REPL (Ctrl-D or (exit) to quit)
```

Building requires Crystal ≥ 1.19.0 and the system SQLite3, OpenSSL, and libyaml
libraries. See [Getting started](doc/guide/getting-started.md) for
prerequisites, building, the REPL, piped input, and running the test suite.

## Documentation

- [Introduction](doc/guide/introduction.md) — what creme is, the two backends, project scope
- [Features](doc/guide/features.md) — the full feature list
- [Getting started](doc/guide/getting-started.md) — build, run, REPL, development
- [Language tour](doc/guide/language-tour.md) — the language by example
- [Libraries](doc/guide/libraries.md) — the full standard-library surface
- [CLI reference](doc/guide/cli-reference.md) — every subcommand and flag
- [Embedding](doc/guide/embedding.md) — using creme as a Crystal library
- [icecreme](doc/guide/icecreme.md) — the self-hosting C VM
- [Repository structure](doc/guide/repository-structure.md) — a map of the codebase
- [Known caveats](doc/guide/known-caveats.md) — what's deliberately out of scope

📖 The full documentation index, including maintainer/internals notes, is in
[`doc/README.md`](doc/README.md).

## License

MIT, see [LICENSE](LICENSE). © Vincent Landgraf.
