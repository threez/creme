# Repository structure

A map of the codebase to help you find your way around. creme is a Crystal
implementation of an R7RS Scheme; `icecreme` is a companion C11 VM that runs the
same language.

## Top-level layout

| Path | What it is |
|---|---|
| `src/` | The native creme interpreter/compiler/VM and Crystal-implemented builtin libraries (~99 `.cr` files). |
| `modules/` | The Scheme-level standard library, written in Scheme (`.sld` = Scheme library definitions). |
| `icecreme/` | The standalone, self-hosting C11 bytecode VM (C sources, autoconf build, vendored deps, bytecode seeds). |
| `spec/` | Test suite: Crystal specs (`spec/scheme/…`) and Scheme specs (`spec/creme/*.scm`). |
| `examples/` | 50+ numbered, runnable `.scm` example programs, plus a C host-embedding example. |
| `competition/` | Cross-language benchmark/demo harness (creme vs Guile, Racket, Lua, Node, Go, Ruby, C, …). |
| `bin/` | Built binaries (`creme`, `creme_spec`, vendored `ameba`). |
| `lib/` | Installed Crystal shard dependencies. |
| `doc/` | Hand-written documentation (this directory): `guide/` (user-facing), `internals/` (maintainer notes), plus `logo.md` and `r7rs.pdf`. |
| `docs/` | **Generated** Crystal API HTML (`crystal docs` output). Note the singular `doc/` vs. plural `docs/` distinction. |
| `benchmarks/` | **Generated** per-machine benchmark snapshots (`make bench-md`), one file per architecture+OS (e.g. `amd64_freebsd.md`). |
| `Makefile` | Top-level build orchestration (Crystal build + icecreme + specs + lint + docs + benchmarks). |
| `README.md`, `CHANGELOG.md`, `LICENSE` | Project landing page, change log, license. |

## `src/` — the native implementation

Entry points: `src/main.cr` (CLI dispatch and process lifecycle), `src/creme.cr`
(library require root), `src/creme/runner.cr` (pure `run_source`/`run_file`
entry points; also handles `#lang` dialect selection). The rest is organized by
subsystem under `src/creme/`:

- **`read/`** — front end: `lexer.cr` (source → tokens), `reader.cr` (tokens →
  s-expressions).
- **`compile/`** — analysis and bytecode: `analyzer.cr`, `ast.cr`,
  `bytecode_compiler.cr` (+ `bytecode_closure.cr`), `chunk.cr`, `opcode.cr`,
  `chunk_serializer.cr`/`chunk_deserializer.cr`, `disassembler.cr`,
  `syntax_rules.cr` (macro expander), and `icecreme_emitter.cr` (compile a whole
  script to icecreme's compact bytecode).
- **`eval/`** — runtime: `interpreter.cr`, `vm.cr` (register-bytecode dispatch
  loop), `import.cr` and `library.cr` (the `define-library`/`import` system),
  `prelude.cr`, `builtin_registration.cr`/`builtin_helpers.cr`,
  `object_pool.cr`, `record.cr`.
- **`value/`** — the data model: `values.cr` (the `SchemeValue` hierarchy + cons
  cells), `complex.cr`, `rational.cr`, `box.cr`, `alias.cr`.
- **Top-level support:** `env.cr`, `errors.cr`, `convert.cr` (Crystal↔Scheme
  conversion), `helpers.cr`.
- **`src/creme/modules/`** — the Crystal-implemented bodies of the standard
  libraries, split into `scheme/…` (R7RS; `scheme/base.cr` further split under
  `scheme/base/…`) and `creme/…` (the extensions, incl. the one C source
  `creme/ffi_shim.c`).

## `modules/` — Scheme `.sld` libraries

The Scheme-level standard library, in three namespaces:

- **`modules/scheme/`** — the R7RS standard libraries: `base.sld`, `char.sld`,
  `complex.sld`, `cxr.sld`, `eval.sld`, `file.sld`, `inexact.sld`, `lazy.sld`,
  `load.sld`, `process-context.sld`, `read.sld`, `repl.sld`, `time.sld`,
  `write.sld`, `case-lambda.sld`, `r5rs.sld`.
- **`modules/creme/`** — the extended creme standard library (the bulk of the
  surface, ~90+ libraries). Notable nested subdirectories:
  - `creme/compiler/` — the self-hosting Scheme compiler (`compiler.sld`, …).
  - `creme/syntax/` — `#lang` dialects (`ruby.sld`, `scss.sld`, `slim.sld`,
    `mex.sld`).
  - `creme/xml-schema/` — `dtd.sld`, `xsd.sld` (paired with top-level
    `creme/xml-schema.sld`).
- **`modules/dialect/`** — `ruby.sld`, the Ruby-flavored naming layer.

See the [Libraries reference](libraries.md) for what each provides.

## `icecreme/` — the C self-hosting VM

A C11 implementation of the same VM that runs creme's compact bytecode; it can
bootstrap itself.

- **Build system:** autoconf — `configure`, `configure.ac`, `Makefile.in`,
  generated `Makefile`, `config.h`.
- **Core:** `vm.c`/`vm.h` (dispatch loop), `main.c`, `loader.c`, `builtins.c`,
  `value.h`, `opcodes.h`, embedding glue (`embed.c`, `embedded_icecreme*.c`).
- **Feature modules (C, mirroring creme builtins):** `json`, `yaml`, `csv`,
  `regex`, `sql`, `http`, `cipher`, `digest`, `pkey`, `x509`, `actor`,
  `bigdecimal`, `zstd`, `creme_ffi`, and more.
- **Seed/bootstrap artifacts:** `icecreme.scm` (the VM written in Scheme),
  `repl.scm`, and the serialized bytecode seeds `icecreme.ice` / `icecreme-boot.ice`.
- **Vendored deps (`vendor/`, git submodules):** `picohttpparser/`, `sds/`,
  `verstable/`.
- **Docs:** `icecreme/README.md`, `icecreme/STABILITY.md`.

## `spec/` — tests

Two parallel styles, both driven from Crystal:

- **Crystal specs (`spec/scheme/…`)** — unit tests of the Crystal implementation,
  mirroring the `src/` layout (`read/`, `compile/`, `eval/`, `value/`, `r7rs/`,
  and `modules/`). Entry point: `spec/main_spec.cr` (with `spec/spec_helper.cr`).
- **Scheme specs (`spec/creme/*.scm`)** — behavioral tests written in Scheme and
  run through creme's own spec framework (`modules/creme/spec.sld`).
  `spec/creme/main_spec.scm` is the aggregate runner (`make creme-spec`, or
  `make creme-spec-icecreme` to run them under icecreme).

## `examples/`

50+ standalone, runnable `.scm` programs, numbered and organized by topic —
numerics, text/regex, JSON/YAML/CSV/XML, SQL, HTTP, crypto, FFI, actors/Raft,
TUI, and language features. `examples/demo.scm` is a quick tour of the core
language; `examples/libcream/` shows embedding creme/icecreme in a C host.

## `competition/`

A cross-language comparison harness: the same programs implemented in many
languages to benchmark creme against them. `competition/Makefile` drives it and
`competition/bench.scm` defines the creme-side workloads; one subdirectory per
competitor language.
