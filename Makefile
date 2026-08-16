.PHONY: all clean fmt fmtcheck lint fix docs spec creme-spec creme-spec-icecreme icecreme bench bench-md version tag

all: clean fmt lint docs spec

fmt:
	crystal tool format

fmtcheck:
	crystal tool format --check

# rfc8439's NEON C extension (aarch64 only) isn't built by `shards install`;
# compile it once so `crystal spec`/`shards build` can link against it. Always
# a bin/creme/spec prerequisite (not gated behind a `!=`-computed variable --
# see FFI_SHIM_OBJ's own comment below for why that breaks under Apple's
# stock GNU Make 3.81), but the recipe itself is arch-gated in its own
# shell: on non-arm64/aarch64 it just touches an empty object file rather
# than invoking $(CC) with -march=armv8-a+simd, which would fail to
# assemble on a non-ARM target.
NEON_OBJ = lib/rfc8439/ext/chacha20_neon.o

lib/rfc8439/ext/chacha20_neon.o: lib/rfc8439/ext/chacha20_neon.c lib/rfc8439/ext/chacha20_neon.h
	@case "`uname -m`" in \
		arm64|aarch64) $(CC) -O3 -march=armv8-a+simd -c -o $@ lib/rfc8439/ext/chacha20_neon.c ;; \
		*) : > $@ ;; \
	esac

# (creme ffi)'s small precompiled dlopen/libffi shim (see that file's own
# header comment for why) -- needed on every platform, so it's an
# unconditional bin/creme prerequisite below (a plain `=` assignment, same
# as NEON_OBJ above -- no arch gating needed for the prerequisite itself).
# -I/usr/local/include is a no-op where it doesn't exist (BSD's base cc
# already searches it by default; Linux distros installing libffi-dev under
# /usr/include don't need it either) and covers this project's own FreeBSD
# dev environment, where libffi's headers live under /usr/local/include
# specifically (a ports/pkg convention). macOS ships libffi's headers
# inside the Xcode/CLT SDK too, but nested under usr/include/ffi/ffi.h
# rather than flat at usr/include/ffi.h like every other platform above --
# so on Darwin needs that nested dir explicitly instead. This can't be a
# `!=`-assigned variable: Apple ships a GNU Make frozen at 3.81 (the last
# GPLv2 release) as macOS's stock /usr/bin/make, and `!=` shell-assignment
# wasn't added to GNU Make until 4.0, so it silently evaluates empty there
# even though both BSD make and modern GNU make support it fine (the same
# gap NEON_OBJ's own recipe above works around, by moving its arch check
# into the recipe's shell instead of a `!=`-computed variable). Computing
# the include-path flag inside the recipe's own shell instead sidesteps
# that gap entirely -- every make flavor here runs recipes via /bin/sh
# regardless of its own variable-assignment feature set.
FFI_SHIM_OBJ = src/creme/modules/creme/ffi_shim.o

# Names the .c explicitly, not $< -- BSD make only sets $< in inference/suffix
# rules, not explicit ones (where it expands to empty).
src/creme/modules/creme/ffi_shim.o: src/creme/modules/creme/ffi_shim.c
	@case "`uname -s`" in \
		Darwin) inc="`xcrun --show-sdk-path`/usr/include/ffi" ;; \
		*) inc=/usr/local/include ;; \
	esac; \
	echo $(CC) -O2 -I"$$inc" -c -o $@ src/creme/modules/creme/ffi_shim.c; \
	$(CC) -O2 -I"$$inc" -c -o $@ src/creme/modules/creme/ffi_shim.c

spec: $(NEON_OBJ) $(FFI_SHIM_OBJ)
	crystal spec -v

# bin/creme itself, the one binary everything else in this project (creme-
# spec/creme-spec-icecreme above, competition/Makefile's own `creme` delegation
# target) either runs directly or shells out to. Real prerequisites --
# every .cr source file plus shard.yml/shard.lock/the NEON object above --
# not a bare existence check, so a rebuild happens exactly when creme's own
# behavior could have changed, never leaving a stale (or hand-built, wrong-
# flags) binary silently in place indefinitely (see competition/Makefile's
# own header comment for the concrete incident that motivated this: the
# Crystal demo-todo twin's bin/app once sat unrebuilt for days after a
# manual, non-`--release` build, because nothing ever re-checked HOW it had
# been built, only whether it existed and was newer than its source).
CREME_SRCS != find src -name '*.cr' | tr '\n' ' '

bin/creme: $(CREME_SRCS) shard.yml shard.lock $(NEON_OBJ) $(FFI_SHIM_OBJ)
	shards build --release --no-debug

# Run-only: assumes bin/creme is already built (shards build --release
# --no-debug). Runs spec/creme/main_spec.scm -- (creme spec)-based tests,
# written and run entirely in Scheme (see modules/creme/spec.sld), one
# per bin/creme subprocess (see modules/creme/spec-runner.sld's own
# header comment for why each spec file needs its own fresh global
# table, not one shared interpreter) -- which itself loops over every
# spec/creme/*_spec.scm file and reports ONE combined "N examples, M
# failures" total, propagating failure if any file failed.
creme-spec:
	./bin/creme spec/creme/main_spec.scm

# Builds the icecreme self-hosting C VM from the repo root, delegating to
# icecreme/Makefile (which owns its own per-.c/.h prerequisites and the
# two-stage self-hosting bootstrap). `$(MAKE)`, not a hardcoded `gmake`:
# icecreme/Makefile is now written in the portable subset both GNU make and BSD
# make accept, so whichever make is running THIS file drives that one too. Its
# vendored C deps are git submodules that auto-init on first build.
#
# icecreme/Makefile itself is GENERATED (by icecreme/configure, from
# icecreme/Makefile.in -- see icecreme/configure.ac's own header comment for
# why: it resolves every pkg-config-dependent build flag in configure's own
# portable shell instead of a Make-level `!=`, which isn't supported by every
# make this project runs under). Not committed -- a fresh checkout has no
# icecreme/Makefile until configure creates one, so this depends on it and
# runs configure automatically the first time (or whenever configure.ac/
# Makefile.in change) rather than requiring a separate manual step.
icecreme/Makefile: icecreme/configure icecreme/Makefile.in
	cd icecreme && ./configure

icecreme: icecreme/Makefile
	$(MAKE) -C icecreme

# Rebuilds the icecreme binary first (`$(MAKE) -C icecreme`) so its EMBEDDED
# self-hosted-compiler image (icecreme.scm, baked in via bin2c -- icecreme no
# longer reads it off disk at run time) reflects the current compiler/builtin
# source; a stale binary would silently run each spec against old behavior. Then
# runs spec/creme/
# main_spec.scm --icecreme, which spawns `./icecreme/icecreme <file>` (icecreme reentrant-
# compiling+running each file with the SELF-HOSTED compiler, entirely
# inside icecreme, no native Crystal process involved at run time -- NOT `./
# bin/creme --icecreme`, an unrelated native-compile-then-run-on-icecreme path) for
# every spec/creme/*_spec.scm file except reader_native_spec.scm (see
# that file's own header comment: (creme reader)'s lex-tokens/tokens->
# forms are native-Crystal-only, no icecreme equivalent at all), and reports
# ONE combined total the same way creme-spec does.
#
# Every file now passes in full, including compiler_numeric_tower_spec.
# scm (icecreme/value.h's T_RATIONAL, GMP-backed, and T_COMPLEX -- see icecreme/
# README.md's "numeric tower" note for exactly what this does and
# doesn't cover), reader_literals_spec.scm's own 7 complex-number cases,
# and bootstrap_spec.scm's "import! applies only/except/prefix import-
# set filters" case (icecreme/bootstrap.c's import! bridge, plus a small
# hardcoded library-exports table so it can alias a NATIVE library's
# exports too, not just a pure-Scheme one -- see that file's own
# comment), EXCEPT bootstrap_spec.scm's one remaining, harmless
# environment-artifact case -- explained in that file's own header
# comment, NOT a regression.
#
# This target still propagates failure (so a REGRESSION -- a NEW failure
# beyond today's known baseline -- doesn't go unnoticed), but a nonzero
# exit here isn't automatically a problem; check which specific case
# failed against the affected file's own documented list before assuming
# something broke.
creme-spec-icecreme: icecreme/Makefile
	$(MAKE) -C icecreme
	./bin/creme spec/creme/main_spec.scm --icecreme

# Every artifact competition/bench.scm's two suites need (bin/creme and
# icecreme/icecreme themselves, the self-hosted-compiler image, both suites' native-
# code comparison floors, and every todo-app twin) is now a real,
# prerequisite-tracked target owned by competition/Makefile -- see its own
# header comment for why (a hand-built, wrong-flags binary used to be able
# to sit unrebuilt indefinitely; a target's only path to existing now is
# through that Makefile's own recipe). competition/Makefile itself is
# written in the same portable make subset as this file, and so is
# icecreme/Makefile now, so every delegation uses `$(MAKE)` -- the whole
# build runs under either plain `make` (BSD make) or `gmake` here.
#
# Runs BOTH the CPU-workload "bench" suite and the HTTP-benchmarked
# "todo-app" suite, bench first -- pass --only bench / --only todo-app
# yourself (`./bin/creme competition/bench.scm --only ...`) to narrow to
# just one (competition/Makefile's own `build` still prepares everything
# either one could need either way).
bench:
	$(MAKE) -C competition build
	./bin/creme competition/bench.scm

# Same as `bench` above, but also writes a committed, per-machine markdown
# snapshot to benchmarks/<arch>_<os>.md (see competition/bench.scm's own
# --markdown flag, and (creme table)/(creme bench)'s markdown-style/
# bench-table->markdown) -- reruns both suites fresh rather than reusing a
# previous `bench` run's terminal output, since the snapshot is meant to
# reflect a real run on the machine that generates it.
bench-md:
	$(MAKE) -C competition build
	./bin/creme competition/bench.scm --markdown

lib/ameba/bin/ameba:
	shards install

lint: lib/ameba/bin/ameba
	lib/ameba/bin/ameba

fix: lib/ameba/bin/ameba
	lib/ameba/bin/ameba --fix

docs:
	crystal docs

clean:
	rm -rf docs/

# Sync the VERSION constant in src/ to match shard.yml's version field.
# Bump shard.yml's version first, then run `make version`.
version:
	@V=$$(grep '^version:' shard.yml | sed -E 's/^version:[[:space:]]*//'); \
	for f in $$(grep -rl '^[[:space:]]*VERSION[[:space:]]*=[[:space:]]*"[^"]*"' src/ 2>/dev/null); do \
		sed -E "s/^([[:space:]]*VERSION[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\\1\"$$V\"/" "$$f" > "$$f.tmp" && mv "$$f.tmp" "$$f"; \
		echo "updated $$f to $$V"; \
	done

# Create an annotated git tag "vX.Y.Z" from shard.yml's version field.
tag:
	@V=$$(grep '^version:' shard.yml | sed -E 's/^version:[[:space:]]*//'); \
	git tag -a "v$$V" -m "Release v$$V"; \
	echo "tagged v$$V"
