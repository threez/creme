# libcream embedding example

A minimal C host program embedding `icecreme` via `libcreme.a`. It:

- registers its own native function, `host-greet`, as a Scheme global
- registers its own native value, `host-version`, as a Scheme global
- runs `host_demo.scm` — a plain Scheme script (no precompilation step, no
  `.ice` file) that calls/reads both

See `host_demo.c` for the whole thing, and `../../icecreme/README.md`'s
"Embedding" section for the general call-sequence writeup this mirrors.

## Build and run

```sh
cd examples/libcream && make
cd ../.. && ./examples/libcream/host_demo
```

**Run it from the repo root**, not from `examples/libcream/` — the
self-hosted compiler `creme_run_scheme_file` uses resolves every library it
needs (`(scheme base)`, etc.) relative to the process's own working
directory, the same repo-root-relative assumption `icecreme`'s own CLI
makes everywhere else (see `host_demo.c`'s own comment on this). `make`
itself can run from either directory; only the resulting `host_demo`
binary itself needs the repo root as its CWD.

Expected output:

```
Hello from C, world!
libcream host demo 0.1
```

`make` first builds `../../icecreme/libcreme.a` if it doesn't already exist
(`$(MAKE) -C ../../icecreme lib`), which in turn needs `bin/creme` already
built (`shards build --release --no-debug` from the repo root) — the
library's bundled self-hosted compiler/REPL bytecode (`compiler-run.ice`/
`repl.ice`) is produced by running the real Crystal `creme` binary once at
library-build time, then baked directly into `libcreme.a`; nothing at
`host_demo`'s own runtime touches Crystal at all.

Try editing `host_demo.scm` (e.g. change the displayed text) and re-running
`./examples/libcream/host_demo` (from the repo root) with no rebuild —
`creme_run_scheme_file` recompiles the script fresh on every run via the
bundled compiler, it isn't baked in once at library-build time the way
`compiler-run.ice`/`repl.ice` themselves are.
