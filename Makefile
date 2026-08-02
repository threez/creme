.PHONY: all clean fmt fmtcheck lint fix docs spec creme-spec creme-spec-cvm bench version tag

UNAME_M != uname -m
NEON_OBJ != case "$(UNAME_M)" in arm64|aarch64) echo lib/rfc8439/ext/chacha20_neon.o ;; esac

all: clean fmt lint docs spec

fmt:
	crystal tool format

fmtcheck:
	crystal tool format --check

# rfc8439's NEON C extension (aarch64 only) isn't built by `shards install`;
# compile it once so `crystal spec`/`shards build` can link against it.
lib/rfc8439/ext/chacha20_neon.o: lib/rfc8439/ext/chacha20_neon.c lib/rfc8439/ext/chacha20_neon.h
	$(CC) -O3 -march=armv8-a+simd -c -o $@ $<

# (creme ffi)'s small precompiled dlopen/libffi shim (see that file's own
# header comment for why) -- unlike NEON_OBJ, needed on every platform, so
# it's an unconditional bin/creme prerequisite below rather than arch-
# gated. -I/usr/local/include is a no-op where it doesn't exist (BSD's
# base cc already searches it by default; Linux distros installing
# libffi-dev under /usr/include don't need it either) and covers this
# project's own FreeBSD dev environment, where libffi's headers live
# under /usr/local/include specifically (a ports/pkg convention).
FFI_SHIM_OBJ = src/creme/modules/creme/ffi_shim.o

src/creme/modules/creme/ffi_shim.o: src/creme/modules/creme/ffi_shim.c
	$(CC) -O2 -I/usr/local/include -c -o $@ $<

spec: $(NEON_OBJ) $(FFI_SHIM_OBJ)
	crystal spec -v

# bin/creme itself, the one binary everything else in this project (creme-
# spec/creme-spec-cvm above, competition/Makefile's own `creme` delegation
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

# Run-only: assumes bin/creme and cvm/cvm are already built (`make -C
# cvm`). Rebuilds cvm/compiler-run.cvmc fresh (the precompiled self-
# hosted-compiler image cvm's own "compiler mode" needs -- see cvm/
# compiler-run.scm's own header comment) since a stale one would silently
# run against old compiler/builtin behavior, then runs spec/creme/
# main_spec.scm --cvm, which spawns `./cvm/cvm <file>` (cvm reentrant-
# compiling+running each file with the SELF-HOSTED compiler, entirely
# inside cvm, no native Crystal process involved at run time -- NOT `./
# bin/creme --cvm`, an unrelated native-compile-then-run-on-cvm path) for
# every spec/creme/*_spec.scm file except reader_native_spec.scm (see
# that file's own header comment: (creme reader)'s lex-tokens/tokens->
# forms are native-Crystal-only, no cvm equivalent at all), and reports
# ONE combined total the same way creme-spec does.
#
# Every file now passes in full, including compiler_numeric_tower_spec.
# scm (cvm/value.h's T_RATIONAL, GMP-backed, and T_COMPLEX -- see cvm/
# README.md's "numeric tower" note for exactly what this does and
# doesn't cover), reader_literals_spec.scm's own 7 complex-number cases,
# and bootstrap_spec.scm's "import! applies only/except/prefix import-
# set filters" case (cvm/bootstrap.c's import! bridge, plus a small
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
creme-spec-cvm:
	./bin/creme --emit-cvm cvm/compiler-run.scm cvm/compiler-run.cvmc
	./bin/creme spec/creme/main_spec.scm --cvm

# Every artifact competition/bench.scm's two suites need (bin/creme and
# cvm/cvm themselves, the self-hosted-compiler image, both suites' native-
# code comparison floors, and every todo-app twin) is now a real,
# prerequisite-tracked target owned by competition/Makefile -- see its own
# header comment for why (a hand-built, wrong-flags binary used to be able
# to sit unrebuilt indefinitely; a target's only path to existing now is
# through that Makefile's own recipe). competition/Makefile itself is
# written in the same portable make subset as this file (works under
# either plain `make` or `gmake` here) -- it only reaches for `gmake`
# explicitly, internally, for the one delegation (cvm/Makefile) that
# actually needs GNU-only syntax; see its own header comment.
#
# Runs BOTH the CPU-workload "bench" suite and the HTTP-benchmarked
# "todo-app" suite, bench first -- pass --only bench / --only todo-app
# yourself (`./bin/creme competition/bench.scm --only ...`) to narrow to
# just one (competition/Makefile's own `build` still prepares everything
# either one could need either way).
bench:
	$(MAKE) -C competition build
	./bin/creme competition/bench.scm

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
