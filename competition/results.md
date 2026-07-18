# Results: scheme.cr vs. Sinatra/ERB/Sequel/SQLite

Machine: Apple Silicon macOS, `wrk -t4 -c32`, 5-8s runs, both servers on
`127.0.0.1`, both backed by an in-memory SQLite DB seeded with the same 3
rows. scheme.cr via `bin/creme` (release-mode build already present in this
repo); Ruby via `ruby 3.4.8` + `puma 8.0.2` + `sinatra 4.2.1` + `sequel`.

## GET / (text/html) -- full page render, 3 rows, row cache warm after first hit

| | req/s | avg latency | p_max latency |
|---|---:|---:|---:|
| **scheme.cr** | **5,304** | 5.99ms | 12.5ms |
| Ruby/Sinatra/ERB/Sequel | 2,797 | 14.70ms | 429ms |

scheme.cr ~**1.9x** the throughput, with a much tighter latency tail (Ruby's
429ms max vs. scheme.cr's 12.5ms -- GC pauses and Sequel's per-request
object allocation show up here).

## GET / (application/json) -- same 3 rows, JSON-encoded

| | req/s | avg latency |
|---|---:|---:|
| **scheme.cr** | **4,696** | 6.81ms |
| Ruby/Sinatra/ERB/Sequel | 3,471 | 11.18ms |

Closer here (~1.35x) -- JSON serialization is a smaller share of the work
than full HTML templating, so the gap narrows.

## POST /todos/2/complete -- write path: SQL UPDATE + cache invalidation

| | req/s | avg latency |
|---|---:|---:|
| **scheme.cr** | **52,230** | 0.61ms |
| Ruby/Sinatra/ERB/Sequel | 3,867 | 10.41ms |

This is the biggest gap (~13.5x). This route does no templating at all --
just a DAO update + a hash-cache delete + a redirect -- so it isolates
framework/ORM/dispatch overhead from templating cost. Sequel's per-request
object instantiation, Sinatra's routing/middleware stack, and Puma's
thread-pool dispatch all cost real time here that scheme.cr's compiled
router + register-VM dispatch doesn't pay.

## Interpretation

- **The gap is smallest where templating dominates (plain JSON) and
  largest where framework/ORM/dispatch overhead dominates relative to a
  tiny handler body (the POST toggle).** This lines up with the qualitative
  prediction: scheme.cr's edge comes less from "the VM is fast" in the
  abstract and more from doing a lot of the request's work (routing
  compiled once, static template chunks folded at compile time, per-row
  memoization) ahead of time or once, rather than repeating it every
  request the way a typical Sinatra+ERB+Sequel stack does.
- Both apps are running as a single process/single connection to the same
  in-memory SQLite DB, so DB access itself isn't the bottleneck for either
  side -- this measures app-server + templating + ORM overhead, not SQLite
  throughput.
- Ruby's tail latency (429ms max on the HTML route) is the more visible
  practical difference for a real deployment: scheme.cr's worst case here
  is a small multiple of its average, Ruby's is ~30x its average --
  consistent with GC-driven pauses under load rather than raw per-request
  CPU cost.
- This is one machine, one run, unpinned CPU affinity, default GC tuning
  on both sides -- treat the ratios as directional, not a certified
  benchmark. YJIT was enabled by default (Ruby 3.4 default).

## Multi-core: `-Dpreview_mt` and `puma -w N`

The obvious follow-up: give Ruby real parallelism via clustered Puma
(`WEB_CONCURRENCY=N` forked workers), and give scheme.cr real parallelism
via a `-Dpreview_mt` build (`CRYSTAL_WORKERS=N` OS threads sharing one
process). Doing this **found and fixed three genuine interpreter-level
thread-safety bugs**, and surfaced one deeper architectural one that isn't
fixed. In order:

### Bugs found and fixed (all confirmed via `crystal spec`: 1736 examples,
### 0 failures both before and after)

1. **`SchemeSym.of`'s interning table** (`src/scheme/value/values.cr`) --
   a plain `Hash(String, SchemeSym)` class variable (`@@table`), mutated on
   every dynamic symbol intern (`string->symbol`, `gensym`, `read`, ...)
   with no synchronization. Under one cooperative OS thread this is safe
   (mutations never truly overlap); under `-Dpreview_mt` with more than one
   OS thread, two fibers interning at the same instant corrupt the Hash's
   internal buckets. **Fixed** with a `Mutex` around the lookup-or-insert.

2. **`Interpreter.current`'s fiber-keyed backtrace stack**
   (`src/scheme/eval/interpreter.cr`) -- `@@current_stacks : Hash(Fiber,
   Array(Interpreter))`. The design comment already said "only one Fiber
   ever touches a given key's array" -- true, but the *Hash itself*
   (insert/delete of different fibers' keys, which can trigger an internal
   bucket resize) was never safe for two threads to touch at the same
   instant. This one reproduced as a hard crash (`Invalid memory access`,
   SIGSEGV, inside `GC_malloc_kind`) under real concurrent load within
   seconds. **Fixed** with a `Mutex` around the three Hash-touching
   operations (the per-fiber Array itself still needs no lock, per the
   original invariant).

3. **`(creme raft)`'s fresh-namespace counter** (`src/scheme/modules/creme/
   raft.cr`) -- a bare `@@namespace_counter += 1`, explicitly commented as
   "single-threaded cooperative fibers make the plain increment safe with
   no Mutex." That comment stopped being true the moment `-Dpreview_mt`
   became a real option. **Fixed** by switching to `Atomic(UInt64)`.

4. **`(creme hash-table)`'s backing store** (`src/scheme/modules/creme/
   hash_table.cr`) -- entries lived in a plain `Array({SchemeValue,
   SchemeValue})` mutated directly by every builtin (`hash-table-set!`,
   `-delete!`, ...) with no lock. This is a *Scheme-level* mutable value,
   not interpreter bookkeeping -- and this demo app's own `(creme
   memoize)` cache is exactly such a table, shared by every concurrent
   request handler. Confirmed as a second, independent crash cause (`GC
   "Duplicate large block deallocation"` abort) after fixing #1-#3.
   **Fixed** by giving `SchemeHashTable` its own internal `Mutex` and
   routing every builtin through new `set`/`get?`/`contains?`/`delete`/
   `snapshot` methods instead of touching `@entries` directly (the
   lazy-thunk default in `hash-table-ref` deliberately runs *outside* the
   lock, since Crystal's `Mutex` isn't reentrant and a default thunk could
   legally re-enter the same table).

### `@call_stack`: fixed by reusing the actor model's own isolation

After fixing #1-#4, a **trivial** route with zero app-level mutable state
(`(get "/" (request) (surf-text "hello"))`) still crashed under
`CRYSTAL_WORKERS=4` load within seconds. The cause: `Interpreter#
@call_stack` (`src/scheme/eval/interpreter.cr`) — a plain `Array(Frame)`
instance variable, pushed/popped by `push_frame`/`pop_frame` on *every
single function call* (for backtraces). `mux-listen!` ran every
concurrently-handled request's Scheme code against **one shared
`Interpreter` instance** (registered once, at `mux-listen!` time) — so
under real OS-thread parallelism, two requests' calls raced on the same
`@call_stack` Array at the literal same instant.

The fix didn't need new machinery — `(creme actor)`'s `spawn` already
solves exactly this problem for actors, via `Interpreter.new(inherit_from:
parent)` (`@base_env` shared by reference since it's read-only after
construction; `@global`/`@libraries` a private per-actor overlay; and
critically, a fresh, private `@call_stack`/gensym-counter/eval-depth/
exception-handler-stack). **`src/scheme/modules/creme/mux.cr` now gives
every HTTP request its own child `Interpreter`** the same way: one
lightweight `Interpreter.new(inherit_from: interp)` per request (shared
across that request's own middleware chain + route handler via a new
`HTTP::Server::Context#mux_interp` property, set once by whichever
handler in the chain runs first), instead of every request reusing the
router-registration-time `Interpreter` directly. `Interpreter#apply`'s
existing `active = Interpreter.current || self` logic (originally written
to keep actors' nested/stale-captured `interp` references correct) already
threads the right per-request instance through every nested call with no
further changes needed. Verified: a trivial route survived **749,491
requests in 15s at 0 errors, ~257% CPU** (genuine 2.5-core utilization)
under `CRYSTAL_WORKERS=4` — where it previously crashed within seconds.

### A second, independent bug this surfaced: `:memory:` + connection pooling

With `@call_stack` fixed, the full demo app survived much longer under
load but still eventually threw `sql-query: no such table: todo` under
concurrency. Cause: crystal-db's connection pool defaults to
`max_pool_size=0` (unlimited) — fine for a real file (every pooled
connection opens the same file), fatal for `:memory:` (every physical
SQLite connection is its own private, empty database). Under enough
concurrent query load the pool opens a second connection, and any query
landing on it sees no tables at all. **Fixed** in `src/scheme/modules/
creme/sql.cr` by forcing `initial_pool_size=1&max_pool_size=1` on the URI
whenever `sql-open` is called with `":memory:"` — every query now lands on
the same physical connection, which is what "one shared in-memory
database" actually requires. (A real file path is untouched — real
pooling is fine and desirable there.)

### `sql-open` grew a real reader/writer connection split

`(creme dao)`/`(creme sxql)` already dispatch cleanly along a read/write
line (`sql-execute` for writes, `sql-query`/`sql-scalar` for reads) — so
`sql-open` now opens **two connections** for a real file: a writer
(`max_pool_size=1`, since SQLite only ever allows one write transaction
at a time no matter how the pool is sized) and a reader pool (many
connections, safe under WAL since WAL readers never block on — or block —
the single writer). `":memory:"` still gets exactly one connection shared
by both roles (a second physical `:memory:` connection is a second,
private, empty database — no way around that without patching the
vendored sqlite3 shard to support `cache=shared`, which wasn't done here).

Tunable via the same `'keyword value` convention `(creme dao)`'s
`todo-create!`/`-update!` already use:

```scheme
(sql-open path)                        ; defaults: 8 readers, 1 writer
(sql-open path 'reader 4)
(sql-open path 'writer 1)
(sql-open path 'reader 16 'writer 1)
(sql-open ":memory:" 'reader 4)        ; accepted, has no effect
```

**A second perf bug this surfaced**: with the reader pool actually
handing out more than one connection, throughput on a file-backed
connection *dropped* under concurrent load — 8 readers ran at ~460 req/s
under `wrk`, *worse* than serializing everything onto a single connection
(~12,300 req/s with `'reader 1`). Cause: SQLite returns `SQLITE_BUSY`
immediately under WAL lock contention across many connections, and
crystal-db's `Pool` retries a busy query at its own default pace
(`retry_attempts=1`, `retry_delay=1.0` — a full **second**) rather than
letting SQLite wait natively. Adding `busy_timeout=5000` (SQLite's own
pragma, milliseconds) to both the reader and writer connection URIs fixed
it: same 8-reader setup went from ~460 req/s to ~2,986 req/s (6.5x) with
zero errors. This is a different layer from `checkout_timeout` (crystal-
db's own pool-level wait) — both matter, and only `busy_timeout` was
missing.

### Where this leaves things

The trivial route and SQL/DAO alone (isolated, no HTML/CSS/memoize/JSON)
are now both solid under sustained `-Dpreview_mt` load, and the SQL layer
now has genuine, correct, reasonably fast reader/writer concurrency for
file-backed connections. The full demo-todo app still hit a further,
rarer crash under heavy sustained load after the interpreter-isolation
and pool-size fixes — likely a residual race somewhere in the
HTML/CSS/path/memoize/JSON-builder combination the full app exercises,
not yet isolated to a specific line. Given how much ground the fixes
above already covered (crashing within seconds → surviving 750K clean
requests on the trivial path, and a 6.5x fix on top of that for the SQL
layer), further isolation is a reasonable next step but wasn't pursued
exhaustively here. `-Dpreview_mt` is therefore still not a *certified*
path to multi-core scheme.cr today, even though it's meaningfully closer
than when this investigation started.

### The practical fix in the meantime: multiple OS processes (historical)

Given that open item, the safe, verified path to multi-core scheme.cr
today is multiple OS processes, not one multi-threaded one. This is also
a fair comparison to Ruby: **Ruby's own real parallelism story is also
multi-process** (Puma's forked `-w N` workers), not multi-threading
against the GVL. Earlier in this investigation a `bench_cluster.sh` +
`app_cluster.scm` pair (since removed, to keep this directory to one
app/one benchmark script) measured exactly that: N independent
`bin/creme` processes (each single-threaded/cooperative, i.e. the normal,
verified-safe build) vs. N Puma-forked workers, both sharing one on-disk
SQLite file (`:memory:` is private per OS process either way, so neither
side could use it there). Kept here as a historical record, not something
`./competition/bench.sh` reproduces:

| Route (4 processes/workers each) | scheme.cr (sum) | Ruby/Puma cluster | Ratio |
|---|---:|---:|---:|
| GET / (text/html) | 20,032 req/s | 7,870 req/s | ~2.5x |
| GET / (application/json) | 16,448 req/s | 9,728 req/s | ~1.7x |
| POST /todos/2/complete | 100,786 req/s | 10,892 req/s | ~9.3x |

Both sides scaled close to linearly with process count (each scheme.cr
process independently delivered ~4,800-5,100 req/s on the HTML route,
matching its single-process number; Ruby's cluster hit ~2.8x its own
single-process number with 4 workers) -- consistent with both being
genuinely CPU-bound per request rather than contending on the shared
SQLite file. The relative ordering and rough magnitude from the
single-process numbers above carry over unchanged.

### Reproducing

- `./competition/bench.sh` -- single-process baseline (both sides). Set
  `DURATION`/`THREADS`/`CONNS` env vars to change the `wrk` parameters.
