# CLI reference

Every subcommand and flag of the `creme` executable. The source of truth is the
dispatch in `src/main.cr` (and `creme --help`). Unless noted, a `<file.scm>` is
run under strict R7RS (it must `(import ...)` what it uses); the interactive REPL
is the only mode that auto-imports `(scheme base)`/`(scheme write)`.

## Running programs

| Invocation | Description |
|---|---|
| `creme` | Start the interactive REPL (needs a TTY). Quit with `Ctrl-D` or `(exit)`. |
| `creme <file.scm>` | Execute a Scheme source file. |
| `... \| creme` | Piped, non-interactive stdin is read and evaluated as one whole program (not a REPL). |
| `creme -- <file.scm> [args...]` | Same as `creme <file.scm> [args...]`, but forces `<file.scm>` to be treated as a plain script path even if it looks like one of creme's own flags (e.g. a script literally named `--profile`). Only ever needed for the path itself; ordinary args after the path already reach the script untouched. |
| `creme --help` / `creme -h` | Show usage. |

Script arguments are available to the program via `(command-line)` from
`(scheme process-context)`.

## Inspecting bytecode

| Invocation | Description |
|---|---|
| `creme -S <file.scm>` / `creme --dump-bytecode <file.scm>` | Compile a script and print its bytecode disassembly (one dump per top-level form, including nested closures) instead of running it. `(scheme base)`/`(scheme write)` are auto-imported by default (matching the REPL and what a real run would fuse). |
| `creme --dump-bytecode --strict <file.scm>` | As above, but plain-R7RS: require the script's own `(import ...)`. Useful to see exactly what an unfused / not-yet-imported form compiles to. |
| `creme --dump-bytecode --static <file.scm>` | Disassemble the single whole-program chunk that `--emit-icecreme` would produce (library bodies inlined) — the emitted-file view, without a temp file. |
| `creme --disassemble <file.ice>` | Disassemble an **already-compiled** ICE file (e.g. one written by `--emit-icecreme`, or by the self-hosted compiler). Does not recompile from source: it reads the file's raw bytes through the same deserializer icecreme uses, so the output is exactly what would run. |

`--strict` and `--static` are sub-options of `--dump-bytecode`/`-S`, not
standalone commands.

## Self-hosted compiler

| Invocation | Description |
|---|---|
| `creme --self-hosted <file.scm>` | Run `<file.scm>` exactly like plain `creme <file.scm>`, but compiled by the self-hosted Scheme-to-bytecode compiler (`(creme compiler compiler)`, see `modules/creme/compiler/compiler.sld`) instead of the native Crystal compiler — then run on the same Crystal VM. An opt-in way to exercise/benchmark the self-hosted compiler. With no file on a TTY, starts a self-hosted REPL. |

## icecreme (the standalone C VM)

These require the icecreme binary to be built first (`make -C icecreme`) and to be
run from the repository root. See the [icecreme guide](icecreme.md).

| Invocation | Description |
|---|---|
| `creme --emit-icecreme <file.scm> <out.ice>` | Compile a script and serialize its bytecode to `<out.ice>` for the standalone C11 VM in `icecreme/`. |
| `creme --emit-icecreme --strip <file.scm> <out.ice>` | As above, but strip reflective/debug metadata from the emitted image. Note: `--strip` is unsafe for the compiler image itself (it breaks reflective self-compilation); ship `icecreme.ice` unstripped. |
| `creme --icecreme <file.scm>` | Shorthand: emit to a throwaway `.ice` file, run it under `icecreme/icecreme`, and clean up the temp file. Compiles and runs `<file.scm>` under the C VM in one step. |
| `creme --profile --icecreme <file.scm>` | Same as `--icecreme`, but runs `icecreme/icecreme --profile <file>` (see icecreme's "Profiling" section). |

## Profiling

| Invocation | Description |
|---|---|
| `creme --profile table <file.scm> [args...]` | Run a script exactly as `creme <file.scm> [args...]` would, but with the whole run wrapped in `(creme bench)`'s profiling — both of `(creme prof)`'s samplers (a native SIGPROF sampler and the interpreter's cooperative step-counted one), printing the combined report to stdout after the script finishes. `table` is currently the only supported report format. |
