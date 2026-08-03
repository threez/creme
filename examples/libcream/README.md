# libcream embedding example

A minimal C host program embedding `icecreme` via `libcreme.a` — a tiny
"receipt generator". The host owns a live price catalog (a hash table it
builds and could update at any time — a config reload, a live price feed,
etc.) and a fixed list of pending orders, and delegates the actual report
logic to a user-editable Scheme script (`host_demo.scm`) it doesn't want
to recompile itself for every change — exactly the shape a real host
program embeds a scripting layer for: a customizable pricing/report/
policy layer on top of state and data the host itself owns.

`host_demo.c` registers:

- `host-welcome` — a native function (`creme_arg_cstr`/`creme_format_value`)
- `host-price-lookup` — a REAL hash-table key/value access performed from
  the host's own C code (`creme_hash_table_get`) against the host's own
  live price catalog, not something the script could compute itself
- `host-log` — a side-effecting native function (writes to stderr), the
  kind of capability a script commonly needs from its host beyond pure
  data in/out
- `host-store-name` — a native value (a plain registered constant string)
- `host-orders` — a native value: a real Scheme list of `(item . qty)`
  pairs, the order data the report script processes
  (`creme_cons`/`creme_list_from_values`)

`host_demo.scm` then tallies `host-orders` into its OWN hash table (a real
Scheme-side hash table, distinct from the host's price catalog), looks up
each item's current price via `host-price-lookup`, and prints a line-item
receipt with a total — a real, checkable end-to-end computation, not a
list of disconnected feature demos.

See `host_demo.c`/`host_demo.scm` for the whole thing, and
`../../icecreme/README.md`'s "Embedding" section for the general
call-sequence writeup this mirrors.

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

Expected output (stdout):

```
Welcome to Ionos Grocery, Alice!
apple: 5 x $1.50 = $7.50
bread: 1 x $3.20 = $3.20
milk: 2 x $2.75 = $5.50
total: $16.20
thank you for shopping at Ionos Grocery
```

`host-log`'s two messages go to stderr, not stdout:

```
[host] generating receipt
[host] receipt complete
```

(prices/totals are integer CENTS internally, formatted back to
`"$X.YZ"` by the script's own `cents->string` — money on binary floats
accumulates visible rounding noise, e.g. `0.1 + 0.2` prints as
`0.30000000000000004` in any IEEE-754 language including this one; exact
integer cents is the standard way real receipt/point-of-sale code avoids
that, not just a display trick here.)

`make` first builds `../../icecreme/libcreme.a` if it doesn't already exist
(`$(MAKE) -C ../../icecreme lib`), which in turn needs `bin/creme` already
built (`shards build --release --no-debug` from the repo root) — the
library's bundled self-hosted compiler/REPL bytecode (`compiler-run.ice`/
`repl.ice`) is produced by running the real Crystal `creme` binary once at
library-build time, then baked directly into `libcreme.a`; nothing at
`host_demo`'s own runtime touches Crystal at all.

## Minimal dependency footprint

`host_demo.scm` only imports `(scheme base)`/`(scheme write)`/`(creme
hash-table)` — the last of which is always on regardless (a hard
dependency of the bundled self-hosted compiler itself, see
`icecreme/builtin_config.h`) — so this example's own `Makefile` still
builds `libcreme.a` with every OTHER optional native builtin family
(`icecreme/builtin_config.h`) compiled OUT — `CREME_WITH_SQL=0
CREME_WITH_HTTP=0 CREME_WITH_CIPHER=0 CREME_WITH_PKEY=0 CREME_WITH_X509=0
CREME_WITH_DIGEST=0 CREME_WITH_SECURE_RANDOM=0 CREME_WITH_ACTOR=0
CREME_WITH_FFI=0 CREME_WITH_YAML=0 CREME_WITH_MUX=0 CREME_WITH_CSV=0
CREME_WITH_TREELIST=0 CREME_WITH_JSON=0 CREME_WITH_BIGDECIMAL=0
CREME_WITH_TERM=0 CREME_WITH_PROCESS=0 CREME_WITH_STRING=0`, in
`MINIMAL_FAMILY_FLAGS` in this directory's own `Makefile`. The resulting
`host_demo` binary links against just `libm`, `pthread` (tied to Boehm
GC's threaded build), Boehm GC itself, GMP (`T_RATIONAL`), and PCRE2
(`regex` is a hard, non-gateable dependency of the bundled self-hosted
compiler — see `icecreme/builtin_config.h`'s own doc comment) — no
`sqlite3`/`openssl`/`libffi`/`libyaml` at all. Confirm with `ldd
examples/libcream/host_demo` (or `otool -L` on macOS) after a build.

Want a family back? Drop its `=0` override (or set it to `=1`) in
`MINIMAL_FAMILY_FLAGS`, and add the matching pkg-config lines/`LDLIBS`
entry from `icecreme/Makefile`'s own (e.g. re-enabling `CREME_WITH_SQL`
needs `-lsqlite3` added back to this Makefile's own `LDLIBS`) — see
`icecreme/README.md`'s "Embedding" section for the full family list and
their external dependencies.

Try editing `host_demo.scm` (e.g. add another item to `host-orders`,
change a price in `host_demo.c`'s own catalog and rebuild) and re-running
`./examples/libcream/host_demo` (from the repo root) — `creme_run_scheme_
file` recompiles the script fresh on every run via the bundled compiler,
it isn't baked in once at library-build time the way `compiler-run.ice`/
`repl.ice` themselves are.
