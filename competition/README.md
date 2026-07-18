# Competition: scheme.cr vs. Ruby/Sinatra/ERB/Sequel/SQLite vs. Crystal/Kemal/Granite vs. Racket

A head-to-head benchmark of a small todo-list app built four ways: scheme.cr
with `(creme surf)`/`(creme mux)`/`(creme dao)`/etc., idiomatic Ruby --
Sinatra for routing, ERB for templates, Sequel as the ORM (mirroring
`(creme dao)`), SQLite (in-memory) for storage, served by Puma -- idiomatic
Crystal -- Kemal for routing (Sinatra's closest Crystal analog), Granite as
the ORM (Sequel's closest Crystal analog, same declarative column-only
model), ECR (Crystal's stdlib templating, ERB's closest analog) for
templates, SQLite (in-memory) for storage -- and idiomatic Racket --
`web-server/dispatch` for routing (Racket's own stdlib router, no external
framework needed), plain `db` library queries for storage (Racket has no
dominant Sequel/Granite-style ORM, so this mirrors the Scheme twin's own
hand-written CRUD functions), x-expressions rendered via `response/xexpr`
for HTML (Racket's own idiom, closest structural analog to the Scheme
twin's own `(creme html)` s-expression templates).

## Layout

- `scheme/demo-todo/app.scm` -- the scheme.cr app. Listens on an OS-assigned
  ephemeral port by default (so running it directly is as easy as any other
  example); set the `PORT` env var to pin it to a known port for a benchmark
  script to target.
- `ruby/demo-todo/` -- the Ruby twin: same routes, same in-memory SQLite
  schema (or a shared on-disk file under `puma -w N`, via `TODO_DB_PATH`),
  same row-level memoization strategy (a `Hash` keyed on
  `[id, done, title]`, mirroring `(creme memoize)`), same JSON
  content-negotiation behavior. Includes `puma.rb`/`config.ru` for
  clustered (`WEB_CONCURRENCY=N`) runs. `bundle install` first.
- `crystal/demo-todo/` -- the Crystal twin: same routes/schema/JSON
  content-negotiation, same row-level memoization strategy (a `Hash` keyed
  on the `{id, done, title}` tuple). `shards install` first, then either
  `shards build --release` (or let `bench.sh` build it lazily) before
  running `PORT=4572 ./bin/app`.
- `racket/demo-todo/` -- the Racket twin: same routes/schema/JSON
  content-negotiation, same row-level memoization strategy (a hash table
  keyed on the `(id done title)` list). `raco pkg install --auto db-lib
  web-server-lib` first (a `minimal-racket` install doesn't ship these by
  default); no build step, just `PORT=4573 racket app.rkt`.
- `bench.sh` -- starts each app in turn and runs `wrk` against `GET /`
  (`text/html` and `application/json`).
- `results.md` -- recorded results and analysis from runs on this machine
  (Apple Silicon, macOS), including several interpreter-level
  thread-safety bugs found and fixed along the way while investigating
  `-Dpreview_mt` multi-core scheme.cr: symbol interning, the backtrace
  fiber-stack, `(creme hash-table)`'s backing store, and (the big one)
  `mux-listen!` reusing one shared `Interpreter` across every concurrent
  request instead of giving each request its own — fixed by reusing
  `(creme actor)`'s own `Interpreter.new(inherit_from:)` isolation
  mechanism, which took a trivial route from crashing in seconds to 750K
  clean requests. Two SQL-layer bugs were found and fixed too (`:memory:`
  + connection pooling, and a `busy_timeout` gap that made a reader/writer
  pool split slower than one serialized connection under contention). A
  residual, rarer crash still shows up in the full app under sustained
  load, not yet isolated — `-Dpreview_mt` is closer than when this started
  but not yet a certified path to multi-core scheme.cr.

## Running it yourself

```sh
make lib/rfc8439/ext/chacha20_neon.o   # aarch64 only, if bin/creme isn't built yet
shards build --release                  # or: make all
cd competition/ruby/demo-todo && bundle install && cd -
./competition/bench.sh
```
