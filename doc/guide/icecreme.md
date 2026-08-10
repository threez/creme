# icecreme: the self-hosting C VM

**icecreme** is a standalone C11 bytecode VM that runs the same Scheme language as
native `creme`. creme compiles a program — and the compiler itself — to icecreme's
compact bytecode, which icecreme then loads and runs with no Crystal process
involved at run time.

This page covers how to build and drive icecreme from the CLI. For its internals,
scope, stability guarantees, and numeric-tower notes, see the authoritative
component docs:

- `icecreme/README.md` — building, running, scope, compatibility, profiling.
- `icecreme/STABILITY.md` — cross-release bytecode/behavior guarantees.

## Build

icecreme has its own autoconf-based build, driven from the repo root:

```sh
make -C icecreme        # configures on first run, then builds icecreme/icecreme
```

This also builds the embedded self-hosted-compiler image, so the binary reflects
the current compiler/builtin sources.

## Run a program under icecreme

The simplest path is to let native `creme` compile and hand off in one step (run
from the repository root, with `icecreme/icecreme` already built):

```sh
./bin/creme --icecreme examples/demo.scm
```

Or split the two steps explicitly — compile to a `.ice` image, then run it:

```sh
./bin/creme --emit-icecreme examples/demo.scm out.ice
./icecreme/icecreme out.ice
```

Profile a run under icecreme:

```sh
./bin/creme --profile --icecreme examples/demo.scm
```

See the [CLI reference](cli-reference.md) for the exact flag semantics
(`--emit-icecreme`, `--icecreme`, `--strip`, `--disassemble`).

## Self-hosted compiler (native VM)

Distinct from icecreme is the `--self-hosted` flag, which compiles a script with
the self-hosted Scheme-to-bytecode compiler but still runs it on the native
Crystal VM:

```sh
./bin/creme --self-hosted examples/demo.scm
```

It is an opt-in way to exercise the self-hosted compiler on a real script without
making it the default execution path.

## Portability notes

Most programs run unchanged on both backends. A few libraries are native-only
(e.g. `(creme escm)`, `(creme uri)`, `(creme pstore)`) and note this in their
[library reference](libraries.md) entry; where a library has an icecreme-specific
implementation (e.g. `(creme raft)` dispatching to a pure-Scheme engine under
icecreme), that is documented there too.

## Running the test suite under icecreme

```sh
make creme-spec-icecreme
```

This rebuilds icecreme, then runs every Scheme spec through it. See the top-level
`Makefile` for exactly what is and isn't covered (a small, documented baseline of
known-excluded cases).
