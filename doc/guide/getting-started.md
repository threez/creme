# Getting started

This guide gets you from a fresh checkout to running Scheme code with the native
`creme` CLI. For the self-hosting C VM, see the [icecreme guide](icecreme.md); to
embed creme in a Crystal program, see [Embedding](embedding.md).

## Prerequisites

- **Crystal** ≥ 1.19.0
- **SQLite3** — already present on macOS; `apt install libsqlite3-dev` on
  Debian/Ubuntu. The `(creme sql)` module links against it.
- **OpenSSL** — already present on macOS with no extra setup; `apt install
  libssl-dev` on Debian/Ubuntu if missing. The `jose` module links against
  system OpenSSL (via the `jose`/`ed25519` shards); also used by the other
  crypto modules (`pkey`, `x509`, `cipher`).
- **libyaml** — already present on macOS with no extra setup; `apt install
  libyaml-dev` on Debian/Ubuntu if missing. The `yaml` module links against
  system libyaml (via Crystal's own bundled `YAML` stdlib module).
  `icecreme` links libyaml directly too, so this is a build-time dependency
  for both backends.

## Build

```sh
shards install     # fetch dependencies (also vendors ameba for linting)
shards build       # produces ./bin/creme
```

`make` wraps the common tasks — `bin/creme` is a proper prerequisite-tracked
target, so `make spec`/`make lint` rebuild it when any source changes.

## Run a script

```sh
./bin/creme path/to/script.scm
```

A script (a file, or a program piped on stdin) follows **strict R7RS**: it must
`(import ...)` everything it uses, including `(scheme base)`. For example, save
this as `hello.scm`:

```scheme
(import (scheme base) (scheme write))

(define (greet name)
  (string-append "Hello, " name "!"))

(write (greet "world"))
(newline)
```

```sh
./bin/creme hello.scm      # => "Hello, world!"
```

Try the bundled examples — 50+ numbered, runnable programs under `examples/`:

```sh
./bin/creme examples/demo.scm                 # a quick tour of the core language
./bin/creme examples/06-json-config-loader.scm
```

## The REPL

Run `creme` with no arguments in a terminal to start the interactive REPL:

```sh
./bin/creme
```

For typing convenience the **REPL only** auto-imports `(scheme base)` and
`(scheme write)`, so you can start evaluating immediately. Quit with `Ctrl-D` or
`(exit)`. Everything else — including `(creme extra)` — must still be imported
explicitly.

## Piping a program

Piping a whole program to `creme` on non-interactive stdin evaluates it instead of
starting the REPL. Like a file, piped input is strict R7RS (no auto-import):

```sh
echo '(import (scheme base) (scheme write)) (write (+ 1 2))' | ./bin/creme
```

## Development

```sh
shards install                 # install dependencies (also vendors ameba for linting)
crystal spec                   # run the test suite
crystal tool format --check    # check formatting
lib/ameba/bin/ameba            # lint
```

`make` wraps these as `fmt`/`fmtcheck`/`spec`/`lint`/`fix` (and rebuilds
`bin/creme` first when needed, since it's a proper prerequisite-tracked
target). See the [Repository structure](repository-structure.md) guide for a
map of the source tree.

## Next steps

- [Language tour](language-tour.md) — the language by example
- [Libraries](libraries.md) — the full standard-library surface
- [CLI reference](cli-reference.md) — every subcommand and flag
