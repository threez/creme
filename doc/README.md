# creme documentation

The documentation map. Start with the [Introduction](guide/introduction.md) if
you're new here.

## For users

Guides for people writing Scheme with creme or embedding it in an application:

- [Introduction](guide/introduction.md) — what creme is, the two backends, and project scope.
- [Getting started](guide/getting-started.md) — build it, run a script, use the REPL.
- [Language tour](guide/language-tour.md) — the language by example.
- [Libraries](guide/libraries.md) — the full standard-library surface (`(scheme …)`, `(creme …)`, `(dialect ruby)`, `(creme syntax ruby)`).
- [CLI reference](guide/cli-reference.md) — every subcommand and flag.
- [Embedding](guide/embedding.md) — using creme as a Crystal library, with sandboxing and limits.
- [icecreme](guide/icecreme.md) — the self-hosting C VM: build, run, and portability.
- [Repository structure](guide/repository-structure.md) — a map of the codebase.

See also the top-level [README](../README.md) (project overview, feature list,
and **Known caveats**) and, for icecreme specifically,
[`icecreme/README.md`](../icecreme/README.md) and
[`icecreme/STABILITY.md`](../icecreme/STABILITY.md).

## For contributors

Maintainer-facing engineering notes:

- [internals/optimization-crystal.md](internals/optimization-crystal.md) — the native Crystal VM/interpreter performance journey.
- [internals/optimization-icecreme.md](internals/optimization-icecreme.md) — the icecreme C11 VM performance journey.
- [internals/optimization-general.md](internals/optimization-general.md) — cross-backend and library-level optimizations.
- [internals/deadend-icecreme.md](internals/deadend-icecreme.md) — VM/opcode ideas explored and rejected.
- [internals/deadend-flags.md](internals/deadend-flags.md) — build-flag tuning explored and rejected.
- [internals/improvement-areas.md](internals/improvement-areas.md) — JIT-adjacent techniques and roadmap.
- [internals/creme-vs-ruby-stdlib.md](internals/creme-vs-ruby-stdlib.md) — feature-gap analysis vs. Ruby's stdlib.

Other references:

- [logo.md](logo.md) — image-generation prompts for a creme logo.
- `r7rs.pdf` — the R7RS-small standard (bundled reference).
- [../CHANGELOG.md](../CHANGELOG.md) — the change log.
- [../benchmarks/](../benchmarks/) — generated, per-machine benchmark snapshots (`make bench-md`), one file per architecture+OS (e.g. `amd64_freebsd.md`).
