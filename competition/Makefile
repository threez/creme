# ===========================================================================
# Builds every artifact competition/bench.scm's two suites (bench, todo-app
# -- see that file's own header comment) need before either can run: bin/
# creme itself, icecreme/icecreme and its self-hosted-compiler image, both suites'
# native-code comparison floors, and every todo-app twin.
#
# Real, prerequisite-tracked targets everywhere in this file (source files,
# shard.lock/go.sum/package-lock.json, ...) -- not bench.scm's own former ad
# hoc shell existence/mtime tests (`[ -x bin/app ] && [ ! src -nt bin/app
# ]`), which only ever checked THAT a binary existed and was newer than its
# source, never HOW it had been built. That gap let a hand-built, non-
# `--release` competition/crystal/demo-todo/bin/app sit untouched for days
# -- src/app.cr never changed, so the freshness check kept passing, so
# Crystal quietly benchmarked mid-field on a debug binary the whole time.
# With `make` (not a shell script) owning the actual recipe, there's no
# other path to any of these targets for a stray manual build to sneak in
# through -- the one recipe here is the only way the file is ever produced.
#
# Written in the subset of make both this project's own default `make`
# (BSD make, on its usual FreeBSD dev box) and GNU make (`gmake`) agree on:
# `!=` for a shell-command-output variable (not GNU-only `$(shell ...)`/
# `$(wildcard ...)`, which BSD make silently mis-parses instead of
# rejecting outright -- see the `find | tr` idiom below), `:=`, `.PHONY`,
# and plain recipe lines. `find ... | tr '\n' ' '` specifically (not bare
# `find`) -- a `!=` variable holding find's default newline-separated
# output breaks BSD make's prerequisite-list parsing (each embedded
# newline reads as a literal, unmatchable "prerequisite", so the target
# looks permanently out of date); space-joining it first is the portable
# fix, and reads identically to GNU make either way. Run this file with
# either `make -C competition build` or `gmake -C competition build`.
#
# Every delegation below uses `$(MAKE)`: icecreme/Makefile is now written in
# the same portable BSD+GNU subset too (it used to need GNU-only `$(shell ...)`,
# which is why this delegation once hardcoded `gmake`), so whichever make runs
# THIS file drives every child Makefile as well -- no `gmake` process anywhere.
#
# Every build here is an all-or-nothing prerequisite of `build` -- matching
# the root Makefile's own pre-existing `bench` target convention (it always
# hard-depended on bin/bench_cr/bin/bench_go, no toolchain-missing
# fallback at build time either) -- unlike bench.scm's own RUNTIME
# tolerance for a missing app (falls back to "n/a" in the bench suite,
# process-run-safe-wrapped). If a toolchain genuinely isn't installed here,
# `make build` fails loudly on that one target rather than silently
# skipping it -- fix the toolchain, or run `./bin/creme competition/
# bench.scm` directly once you've built only the subset you actually have.
# ===========================================================================

ROOT := ..

.PHONY: all build clean creme icecreme bench-binaries todo-app-binaries c/demo-todo/bin/app

build: creme icecreme bench-binaries todo-app-binaries

all: build

# ---- creme itself + the self-hosted compiler image -------------------------

# Delegates to the root Makefile, which owns bin/creme's own recipe and
# prerequisite list (shards build --release --no-debug -- see its own
# header comment). Called unconditionally: make itself no-ops instantly
# once nothing's stale, so there's no need to replicate its prerequisite
# list here too. Plain $(MAKE) (not hardcoded gmake) -- the root Makefile
# is written in this same portable subset, so whichever make invoked THIS
# file works for that delegation too.
creme:
	$(MAKE) -C $(ROOT) bin/creme

# Delegates to icecreme/Makefile -- which has real per-.c/.h prerequisite
# tracking (see its own .c.o suffix rule) -- called unconditionally, same
# reasoning as `creme` above. Plain `$(MAKE)`: icecreme/Makefile is now written
# in the portable BSD+GNU subset (it used `$(shell ...)` and `%` pattern rules,
# both GNU-only; those are gone), so whichever make runs THIS file drives it too.
# Its vendored C deps are git submodules that auto-init on first build.
icecreme:
	$(MAKE) -C $(ROOT)/icecreme

# icecreme's self-hosted-compiler image (icecreme.scm) is compiled to
# icecreme.ice and bin2c'd straight INTO the icecreme binary by icecreme/Makefile,
# which rebuilds it whenever icecreme.scm OR any compiler .sld it bundles
# changes. So the `icecreme` target above ($(MAKE) -C icecreme) already yields a
# binary carrying a fresh embedded image -- icecreme no longer reads any .ice off
# disk at run time, so there is no separate on-disk image to build or depend on.

# ---- bench suite: native-code comparison floors -----------------------------

$(ROOT)/bin/bench_cr: crystal/bench/bench.cr
	crystal build --release --no-debug crystal/bench/bench.cr -o $(ROOT)/bin/bench_cr

$(ROOT)/bin/bench_go: go/bench/bench.go
	go build -o $(ROOT)/bin/bench_go go/bench/bench.go

# Gives plain (non-JIT) Lua a real CLOCK_MONOTONIC timer (see monotonic.c's
# own header comment for why bare os.clock() isn't enough) -- bench.lua
# falls back to os.clock() at runtime if this .so is simply missing, so a
# missing Lua 5.5 dev package doesn't need to fail this whole target; only
# the recipe itself, if actually invoked, can fail loudly (pkg-config not
# finding lua-5.5) -- matching this file's own all-or-nothing convention.
# $$(...) below is plain shell command substitution inside the recipe
# body (evaluated by /bin/sh when the recipe runs), not a make function --
# portable either way, nothing make-flavor-specific about it.
lua/bench/monotonic.so: lua/bench/monotonic.c
	$(CC) -shared -fPIC $$(pkg-config --cflags lua-5.5) -o $@ lua/bench/monotonic.c $$(pkg-config --libs lua-5.5)

bench-binaries: $(ROOT)/bin/bench_cr $(ROOT)/bin/bench_go lua/bench/monotonic.so

# ---- todo-app suite: every twin ---------------------------------------------

# scheme.cr / bin/creme and icecreme / creme (C11 prototype VM) run
# scheme/demo-todo/app.scm directly -- no separate build artifact of their
# own beyond `creme`/`icecreme` above.

CRYSTAL_TODO_SRCS != find crystal/demo-todo/src -name '*.cr' | tr '\n' ' '

crystal/demo-todo/bin/app: $(CRYSTAL_TODO_SRCS) crystal/demo-todo/shard.yml crystal/demo-todo/shard.lock
	cd crystal/demo-todo && shards build --release --no-debug

go/demo-todo/bin/app: go/demo-todo/main.go go/demo-todo/go.mod go/demo-todo/go.sum
	cd go/demo-todo && go build -o bin/app .

node/demo-todo/node_modules: node/demo-todo/package.json node/demo-todo/package-lock.json
	cd node/demo-todo && npm install
	touch node/demo-todo/node_modules

# Delegates to c/demo-todo/Makefile, which already vendors+builds facil.io
# and tracks bin/app against main.c with real prerequisites, and (unlike
# icecreme/Makefile) has no GNU-only construct of its own -- plain $(MAKE) is
# fine here. Named explicitly since that Makefile's own FIRST (so default)
# target is the vendored facil.io clone, not bin/app (see its own target
# order). Declared .PHONY (see the list up top) and called unconditionally,
# same as `creme`/`icecreme` above -- a real prerequisite list here would only
# duplicate c/demo-todo/Makefile's own, and worse, once the file exists a
# target declared with NO prerequisites is never reconsidered at all,
# silently skipping this delegation forever after the first build.
c/demo-todo/bin/app:
	$(MAKE) -C c/demo-todo bin/app

# Ruby (Sinatra) and Racket have no compiled artifact of their own to track
# here -- both run their app.rb/app.rkt source directly (bundler/raco
# resolve dependencies at run time, same as scheme.cr's own bin/creme +
# app.scm), so there's nothing for this Makefile to build for either.
todo-app-binaries: creme icecreme \
                    crystal/demo-todo/bin/app go/demo-todo/bin/app \
                    node/demo-todo/node_modules c/demo-todo/bin/app

clean:
	rm -f $(ROOT)/bin/bench_cr $(ROOT)/bin/bench_go lua/bench/monotonic.so
	rm -rf crystal/demo-todo/bin go/demo-todo/bin
	$(MAKE) -C c/demo-todo clean
