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

spec: $(NEON_OBJ)
	crystal spec -v

# Run-only: assumes bin/creme is already built (shards build --release
# --no-debug). Runs every *_spec.scm under spec/creme/ -- (creme spec)-
# based tests, written and run entirely in Scheme (see modules/creme/
# spec.sld) -- through bin/creme, failing the whole target if any one
# file's own process exits non-zero (each file calls (spec-summary!) as
# its last form, which itself does that per-file exit).
creme-spec:
	@status=0; \
	for f in spec/creme/*_spec.scm; do \
		echo "== $$f =="; \
		./bin/creme "$$f" || status=1; \
	done; \
	exit $$status

# Run-only: assumes bin/creme and cvm/cvm are already built (`make -C
# cvm`). Rebuilds cvm/compiler-run.cvmc fresh (the precompiled self-
# hosted-compiler image cvm's own "compiler mode" needs -- see cvm/
# compiler-run.scm's own header comment) since a stale one would silently
# run against old compiler/builtin behavior, then runs every *_spec.scm
# under spec/creme/ through `./cvm/cvm` directly -- cvm reentrant-
# compiling+running each file with the SELF-HOSTED compiler, entirely
# inside cvm, no native Crystal process involved at run time (NOT `./
# bin/creme --cvm`, an unrelated native-compile-then-run-on-cvm path).
#
# compiler_numeric_tower_spec.scm is deliberately excluded -- see its own
# header comment: cvm has no rational/complex number support at all (a
# real numeric tower is out of scope for this prototype VM), so that
# file can't even start under cvm (compile-program compiles a whole
# script as one upfront chunk; one unparseable literal aborts the entire
# file). Every OTHER file now passes in full EXCEPT reader_literals_spec.
# scm (7 complex-number cases, same root cause) and bootstrap_spec.scm
# (2 cases: one harmless environment artifact, one narrow import!-
# called-as-a-bare-procedure-with-filters gap) -- each explained in its
# own file's header comment, NOT regressions. call/cc/dynamic-wind/with-
# exception-handler and define-syntax's own runtime-visibility gap (both
# previously on this list) are now real cvm features/fixes -- see cvm/
# README.md's "Compiler mode" section. This target still propagates
# failure like `creme-spec` does (so a REGRESSION -- a NEW failure beyond
# today's known baseline -- doesn't go unnoticed), but a nonzero exit
# here isn't automatically a problem; check which specific case failed
# against the affected file's own documented list before assuming
# something broke.
creme-spec-cvm:
	./bin/creme --emit-cvm cvm/compiler-run.scm cvm/compiler-run.cvmc
	@status=0; \
	for f in spec/creme/*_spec.scm; do \
		case "$$f" in \
			*compiler_numeric_tower_spec.scm) continue ;; \
		esac; \
		echo "== $$f =="; \
		./cvm/cvm "$$f" || status=1; \
	done; \
	exit $$status

# Run-only: assumes bin/creme is already built (shards build --release
# --no-debug) and, for the native-Crystal comparison column, bin/bench_cr is
# already built too (crystal build --release bench/bench.cr -o bin/bench_cr).
# Same for the cvm column: cvm/cvm built (make -C cvm) -- bench.scm itself
# regenerates cvm/compiler-run.cvmc (the precompiled self-hosted-compiler
# image cvm's compiler mode needs) every run, so no separate emit step here.
# Ruby/Racket/Guile/Node/cvm columns fall back to "n/a" if those aren't built
# or installed.
bench:
	./bin/creme bench/bench.scm

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
