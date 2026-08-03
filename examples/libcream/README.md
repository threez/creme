# libcream embedding example

A minimal C host program embedding `icecreme` via `libcreme.a`. It:

- registers its own native function, `host-greet`, as a Scheme global
- registers its own native value, `host-version`, as a Scheme global
- registers five more native functions exercising `embed.h`'s list/vector/
  number helpers on both sides of the call boundary: `host-sum` (a Scheme
  list of integers in, a single integer out), `host-scale-vector` (a
  vector + a scale factor in, a new vector out), `host-word-lengths` (a
  list of strings in, an alist out — fed into a real `(creme hash-table)`
  hash table on the Scheme side), `host-table-lookup` (a REAL hash-table
  key/value access performed from the host's own C code — takes that same
  hash table plus a key, and returns the value by calling back into the
  registered `hash-table-ref` procedure), and `host-stats` (a variadic run
  of numbers in, a 3-element `#(min max avg)` vector out)
- runs `host_demo.scm` — a plain Scheme script (no precompilation step, no
  `.ice` file) that calls/reads all of the above

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
15
#(2.5 5.0 7.5)
9
9
#(1.0 9.0 3.875)
```

(the two `9`s are the same `hash-table-ref` lookup done once from Scheme,
once from the host's own C code via `host-table-lookup` — same table, same
key, same answer.)

`make` first builds `../../icecreme/libcreme.a` if it doesn't already exist
(`$(MAKE) -C ../../icecreme lib`), which in turn needs `bin/creme` already
built (`shards build --release --no-debug` from the repo root) — the
library's bundled self-hosted compiler/REPL bytecode (`compiler-run.ice`/
`repl.ice`) is produced by running the real Crystal `creme` binary once at
library-build time, then baked directly into `libcreme.a`; nothing at
`host_demo`'s own runtime touches Crystal at all.

## Minimal dependency footprint

`host_demo.scm` only imports `(scheme base)`/`(scheme write)`, so this
example's own `Makefile` builds `libcreme.a` with every optional native
builtin family (`icecreme/builtin_config.h`) compiled OUT —
`CREME_WITH_SQL=0 CREME_WITH_HTTP=0 CREME_WITH_CIPHER=0 CREME_WITH_PKEY=0
CREME_WITH_X509=0 CREME_WITH_DIGEST=0 CREME_WITH_SECURE_RANDOM=0
CREME_WITH_ACTOR=0 CREME_WITH_FFI=0 CREME_WITH_YAML=0 CREME_WITH_MUX=0
CREME_WITH_CSV=0 CREME_WITH_TREELIST=0 CREME_WITH_JSON=0
CREME_WITH_BIGDECIMAL=0 CREME_WITH_TERM=0 CREME_WITH_PROCESS=0
CREME_WITH_STRING=0`, in `MINIMAL_FAMILY_FLAGS` in this directory's own
`Makefile`. The resulting `host_demo` binary links against just `libm`,
`pthread` (tied to Boehm GC's threaded build), Boehm GC itself, GMP
(`T_RATIONAL`), and PCRE2 (`regex` is a hard, non-gateable dependency of
the bundled self-hosted compiler — see `icecreme/builtin_config.h`'s own
doc comment) — no `sqlite3`/`openssl`/`libffi`/`libyaml` at all. Confirm
with `ldd examples/libcream/host_demo` (or `otool -L` on macOS) after a
build.

Want a family back? Drop its `=0` override (or set it to `=1`) in
`MINIMAL_FAMILY_FLAGS`, and add the matching pkg-config lines/`LDLIBS`
entry from `icecreme/Makefile`'s own (e.g. re-enabling `CREME_WITH_SQL`
needs `-lsqlite3` added back to this Makefile's own `LDLIBS`) — see
`icecreme/README.md`'s "Embedding" section for the full family list and
their external dependencies.

Try editing `host_demo.scm` (e.g. change the displayed text) and re-running
`./examples/libcream/host_demo` (from the repo root) with no rebuild —
`creme_run_scheme_file` recompiles the script fresh on every run via the
bundled compiler, it isn't baked in once at library-build time the way
`compiler-run.ice`/`repl.ice` themselves are.
