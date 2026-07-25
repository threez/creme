.PHONY: all clean fmt fmtcheck lint fix docs spec bench version tag

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
