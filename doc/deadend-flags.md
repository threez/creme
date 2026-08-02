# Build-flag tuning — explored and rejected

Companion to `doc/deadend-icecreme.md` (VM/opcode-level dead-ends) and
`doc/optimization-icecreme.md` (the wins). This file covers a different axis:
compiler-flag tuning on `icecreme/Makefile` and `competition/c/demo-todo/Makefile`,
prompted by the todo-app HTTP bench (`competition/bench.scm`) putting icecreme and
the C/facil.io twin behind Crystal's `Kemal+Granite+ECR+SQLite` app, which
builds via `shards build --release --no-debug`. All of it was reverted;
`icecreme/Makefile` stays at its original `-O2 -g -fno-omit-frame-pointer`, and
`competition/c/demo-todo/Makefile` stays at its original plain `-O3`. Short by
design, same as the sibling doc — the point is the verdict.

## Rejected ideas

- **icecreme `release` target: `-O3` instead of `-O2`.** Naive reading of
  Crystal's `--release` as "always the max opt level" — tried bumping icecreme's
  default `-O2` to `-O3`. **Rejected before even landing**: this project's
  own prior experience already measured `-O3` on icecreme's dispatch loop as
  *worse* than `-O2`, not better. `vm.c`'s own "fast_* inline wrappers"
  comment explains why — `fast_add`/`fast_sub`/etc. are deliberately sized
  so `-O2`'s inlining heuristic inlines them at every `OP_ADD`/`OP_TESTLT`/
  etc. call site for free (confirmed via `objdump -dr vm.o`); `-O3`'s more
  aggressive general-purpose inlining elsewhere in the same translation
  unit bloats `cvm_dispatch` enough to cost icache/branch-prediction
  locality on that same hot loop, outweighing whatever `-O3` gains
  elsewhere. **Never built past the design stage once this was raised.**

- **icecreme `release` target: `-O2 -DNDEBUG`, dropping `-g`/
  `-fno-omit-frame-pointer`.** Built and benchmarked (see
  `competition/bench.scm`'s todo-app suite, HTML/JSON req/s columns).
  Measured **flat**: 59150→57740 HTML req/s, 98944→97899 JSON req/s —
  within ordinary wrk run-to-run noise (Crystal itself moved a similar
  ±5-8% between the same two runs with no code change). `-DNDEBUG` is a
  genuine no-op on this codebase — zero `assert()` calls anywhere in
  `icecreme/*.c` to compile out. Dropping `-g`/`-fno-omit-frame-pointer` also
  buys nothing real: the native "hot C frames" `--profile` sampler
  symbolizes via `dladdr(3)` against the ELF *dynamic* symbol table (kept
  regardless of `-g`, since `icecreme/Makefile`'s `LDFLAGS := -rdynamic` is
  unconditional), and `backtrace(3)` unwinds via glibc's `.eh_frame` CFI,
  not frame pointers — so icecreme's own profiler works the same either way.
  What it does cost: a live `gdb`/`perf` attach against the shipped binary
  loses file:line detail. No measured upside to justify that.
  **Reverted** — `icecreme/Makefile` has no `release` target; `all` stays the
  only target, at `-O2 -g -fno-omit-frame-pointer`.

- **C/facil.io twin: adding `-DNDEBUG`.** facil.io (the vendored HTTP
  library the C todo-app twin links against, not the twin's own
  `main.c`, which has zero `assert()`s of its own) carries ~58 live
  `assert()` calls. Added `-DNDEBUG` to strip them and re-ran the todo-app
  suite. Measured **flat**: 62210→60998 HTML req/s, 58132→53117 JSON
  req/s — again within normal noise. Those asserts sit in connection
  setup/teardown paths, not the per-request templating hot loop, so
  there's nothing on the critical path to remove. **Reverted** —
  `competition/c/demo-todo/Makefile`'s `CFLAGS` stays plain `-O3`, no
  `-DNDEBUG`.

## Takeaway

Neither avoiding `-O3` on icecreme, stripping `-g`, nor `-DNDEBUG` on either C
binary moved todo-app throughput outside normal run-to-run noise. The gap
between icecreme/C and Crystal's Kemal+Granite+ECR twin on this benchmark isn't a
compiler-flag artifact — it's structural (templating/ORM-layer differences),
and not something this axis of tuning can close. Building icecreme/C at a genuine
`-O2`/`-O3` (not a stray unoptimized debug build) remains worth keeping for
fairness against Crystal's own `--release` build; going further than that on
flags alone isn't.
