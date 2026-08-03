CC ?= cc

# Boehm GC (the same collector Crystal itself uses, via the bdwgc/libgc
# package) -- every heap allocation in icecreme goes through GC_MALLOC/GC_REALLOC
# instead of a hand-rolled arena; see vm.h's VM struct doc comment for why
# the VM struct itself is GC_MALLOC'd rather than calloc'd.
#
# (creme actor) (actor.c) needs the THREADED build specifically --
# GC_register_my_thread/GC_pthread_create etc. are compiled out of a
# plain (non-threaded) libgc entirely. Some distros bake pthread support
# into their one bdw-gc package unconditionally; others (e.g. this
# project's own FreeBSD dev environment) ship it as a separate
# bdw-gc-threaded package/pkg-config name -- try that first, falling back
# to plain bdw-gc for the former. -DGC_THREADS makes gc.h itself expose
# the thread-registration API's declarations (gated behind that macro);
# if it's defined but the linked libgc DOESN'T actually have pthread
# support compiled in, that's a real, loud link error (undefined
# GC_register_my_thread) rather than a silent runtime one -- correct
# behavior, since actor.c genuinely cannot work without it.
GC_CFLAGS := $(shell pkg-config --cflags bdw-gc-threaded 2>/dev/null || pkg-config --cflags bdw-gc 2>/dev/null) -DGC_THREADS
GC_LIBS := $(shell pkg-config --libs bdw-gc-threaded 2>/dev/null || pkg-config --libs bdw-gc 2>/dev/null || echo -lgc)

# PCRE2 -- backs (creme regex)'s `regexp`/`regexp-matches?` (regex.c),
# needed only so the self-hosted reader (modules/creme/compiler/
# reader.sld) can run under icecreme; see regex.c's own header comment for why
# PCRE2 specifically (matches the real Crystal Regex class's own flavor).
PCRE2_CFLAGS := $(shell pkg-config --cflags libpcre2-8 2>/dev/null)
PCRE2_LIBS := $(shell pkg-config --libs libpcre2-8 2>/dev/null || echo -lpcre2-8)

# GMP -- backs T_RATIONAL's arbitrary-precision mpq_t (value.h); see
# builtins.c's num_add/num_div/etc. and main.c's mp_set_memory_functions
# call (redirects GMP's own allocator to GC_MALLOC/GC_REALLOC so an mpq_t's
# limbs are reclaimed by the same Boehm GC as everything else here).
GMP_CFLAGS := $(shell pkg-config --cflags gmp 2>/dev/null)
GMP_LIBS := $(shell pkg-config --libs gmp 2>/dev/null || echo -lgmp)

# OpenSSL libcrypto -- backs (creme actor)'s TCP/Unix transport HMAC-SHA256
# handshake (actor.c's Phase 4, HMAC()/RAND_bytes()), mirroring native's own
# openssl/hmac + random/secure usage (actor.cr).
CRYPTO_CFLAGS := $(shell pkg-config --cflags libcrypto 2>/dev/null)
CRYPTO_LIBS := $(shell pkg-config --libs libcrypto 2>/dev/null || echo -lcrypto)

# OpenSSL libssl -- (creme http)'s HTTPS client path (http.c), the actual
# SSL/TLS layer that project used to leave untouched (libcrypto above was
# already linked, just never for TLS itself).
SSL_CFLAGS := $(shell pkg-config --cflags libssl 2>/dev/null)
SSL_LIBS := $(shell pkg-config --libs libssl 2>/dev/null || echo -lssl)

# libffi -- backs (creme ffi)'s ffi-function/ffi-call (creme_ffi.c), the
# generic dlopen/native-call bridge. dlopen/dlsym/dlclose themselves come
# from libc directly on this project's FreeBSD dev environment, but -ldl
# is still linked unconditionally (a no-op there, required on glibc Linux
# systems older than the libc/libdl merge) rather than guarded, matching
# how -lsqlite3 above is also linked unconditionally.
FFI_CFLAGS := $(shell pkg-config --cflags libffi 2>/dev/null)
FFI_LIBS := $(shell pkg-config --libs libffi 2>/dev/null || echo -lffi)

# libyaml (MIT) -- backs (creme yaml)'s yaml-read/yaml-write (yaml.c),
# same pkg-config-with-a-fallback pattern as PCRE2/GMP/OpenSSL/libffi
# above. Native's own (creme yaml) (src/creme/modules/creme/yaml.cr)
# leans on Crystal's bundled `YAML` stdlib module, itself a libyaml
# wrapper -- so both backends end up linking the same underlying C
# library either way; see yaml.c's own header comment.
YAML_CFLAGS := $(shell pkg-config --cflags yaml-0.1 2>/dev/null)
YAML_LIBS := $(shell pkg-config --libs yaml-0.1 2>/dev/null || echo -lyaml)

# Verstable (vendor/verstable/verstable.h, MIT, single header, no deps) --
# backs (creme hash-table)'s Value->Value map (hashtable.c). Header-only, so
# no separate object file, just an include path (below).
#
# sds (vendor/sds/{sds.c,sds.h,sdsalloc.h}, BSD-2-Clause) -- backs (creme
# string)/(creme format)'s growable string-building buffer (strings.c) AND
# mux.c's own request-read/response-write buffers (see mux.c's own header
# comment). sdsalloc.h is edited in-tree to route s_malloc/s_realloc/s_free
# through GC_MALLOC/GC_REALLOC/GC_FREE instead of libc, since every sds
# buffer here is only ever reachable from a plain GC_MALLOC'd Value or a
# short-lived C stack variable.
#
# picohttpparser (vendor/picohttpparser/{picohttpparser.c,.h}, MIT/Perl
# dual-licensed, no deps) -- backs (creme mux)'s HTTP/1.1 request-line/
# header parsing (mux.c), which multiplexes every connection through a
# single poll(2) loop (see mux.c's own header comment for the full
# dispatch design, including its optional worker-VM pool).
CFLAGS ?= -std=c11 -O2 -g -fno-omit-frame-pointer -Wall -Wextra -Wno-missing-field-initializers \
          -Ivendor/verstable -Ivendor/sds -Ivendor/picohttpparser \
          $(GC_CFLAGS) $(PCRE2_CFLAGS) $(GMP_CFLAGS) $(CRYPTO_CFLAGS) $(SSL_CFLAGS) $(FFI_CFLAGS) $(YAML_CFLAGS)
# -rdynamic: exports the executable's own (non-imported) symbols into its
# dynamic symbol table so dladdr(3) can resolve them on Linux/glibc — a no-op
# on Darwin, where dladdr already sees the main binary's local symbol table.
LDFLAGS ?= -rdynamic
# backtrace(3)/execinfo.h (profiler.c's SIGPROF sampler) ship inside libc on
# Linux/glibc and Darwin, but FreeBSD splits them into their own libexecinfo
# (part of the base system, not a package) — link it there only, so this
# stays a no-op everywhere else.
EXECINFO_LIBS := $(if $(filter FreeBSD,$(shell uname -s)),-lexecinfo)
LDLIBS := -lm -lpthread -lsqlite3 -ldl $(GC_LIBS) $(PCRE2_LIBS) $(GMP_LIBS) $(CRYPTO_LIBS) $(SSL_LIBS) $(FFI_LIBS) $(YAML_LIBS) $(EXECINFO_LIBS)

SRCS = main.c loader.c vm.c builtins.c hashtable.c sql.c mux.c strings.c profiler.c bootstrap.c regex.c process.c csv.c treelist.c actor.c digest.c json.c bigdecimal.c http.c term.c creme_ffi.c yaml.c secure_random.c cipher.c pkey.c x509.c builtin_families.c \
       vendor/sds/sds.c vendor/picohttpparser/picohttpparser.c
OBJS = $(SRCS:.c=.o)
BIN = icecreme

# ASAN+UBSAN diagnostic build -- a separate object suffix (.san.o) and
# binary (icecreme-sanitize) so `make` and `make sanitize` never share/clobber
# each other's objects and both can exist side by side. -fno-sanitize-
# recover=all: a caught UB/memory error aborts immediately with its report
# instead of letting execution limp on past it (this is a diagnostic build,
# not something meant to run past its first finding). Boehm GC's own
# conservative stack/heap scanning is known to coexist with ASAN in
# practice (both are widely used together upstream); if a run surfaces
# GC-vs-ASAN false positives rather than real bugs, that's the first thing
# to check before treating a report as a genuine icecreme defect.
SANITIZE_FLAGS := -fsanitize=address,undefined -fno-sanitize-recover=all
SANITIZE_OBJS := $(SRCS:.c=.san.o)
SANBIN := icecreme-sanitize

.PHONY: all clean sanitize
all: $(BIN)

$(BIN): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDFLAGS) $(LDLIBS)

%.o: %.c *.h
	$(CC) $(CFLAGS) -c -o $@ $<

sanitize: $(SANBIN)

$(SANBIN): $(SANITIZE_OBJS)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -o $@ $(SANITIZE_OBJS) $(LDFLAGS) $(LDLIBS)

%.san.o: %.c *.h
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -c -o $@ $<

# libFuzzer harness (fuzz/fuzz_loader.c) targeting creme_load_from_bytes --
# the ICE1 bytecode deserializer, the one place icecreme treats a byte blob as
# trusted input (see that file's own header comment). Needs clang
# specifically (libFuzzer ships as part of clang's compiler-rt, not a
# separate package, and isn't available through plain gcc/$(CC)) -- a
# distinct object suffix (.fuzz.o) and every non-main .c file re-linked
# in, since fuzz_loader.c supplies its own LLVMFuzzerTestOneInput instead
# of main(). ASAN is included alongside the fuzzer instrumentation so a
# memory-safety bug the fuzzer triggers is caught immediately, not just a
# logic-level "wrong output".
FUZZ_SRCS := $(filter-out main.c,$(SRCS))
FUZZ_OBJS := $(FUZZ_SRCS:.c=.fuzz.o)
FUZZBIN := fuzz-loader

.PHONY: fuzz
fuzz: $(FUZZBIN)

$(FUZZBIN): $(FUZZ_OBJS) fuzz/fuzz_loader.c
	clang $(CFLAGS) -fsanitize=fuzzer,address -o $@ $(FUZZ_OBJS) fuzz/fuzz_loader.c $(LDFLAGS) $(LDLIBS)

%.fuzz.o: %.c *.h
	clang $(CFLAGS) -fsanitize=fuzzer,address -c -o $@ $<

# ---- libcreme.a: an embeddable static library, plus a self-contained -------
# ---- compiler+REPL bundle, for a host C program (see examples/libcream/) ---
#
# Same `filter-out main.c` shape as the fuzz target above, archived (ar rcs)
# instead of linked into a binary -- one monolithic library, same full
# dependency set as the CLI binary itself (no per-feature opt-out exists in
# this build, so libcreme.a doesn't invent one either). -fPIC on its own
# object suffix (.lib.o, distinct from plain .o/.san.o/.fuzz.o) costs
# nothing today and leaves the door open to a future .so from the same
# objects.
#
# embed.c/embedded_compiler_run.c are library-ONLY additions -- deliberately
# not part of $(SRCS)/the CLI binary, which keeps its own existing
# file-based compiler-mode (main.c's CREME_COMPILER_DRIVER_PATH) completely
# unchanged. Only the self-hosted-compiler driver gets bundled as embedded
# bytes, not the REPL too -- creme_run_repl (embed.c) instead compiles
# icecreme/repl.scm fresh through the same bundled-compiler mechanism at
# call time (a precompiled repl.ice loaded standalone is missing
# interaction-environment -- see embed.c's own comment on creme_run_repl).
tools/bin2c: tools/bin2c.c
	$(CC) -O2 -o $@ $<

# Regenerated whenever compiler-run.scm changes, via a live bin/creme
# --emit-icecreme (the project's own Crystal compiler) -- same rule shape
# competition/Makefile already uses for compiler-run.ice.
compiler-run.ice: compiler-run.scm
	cd .. && ./bin/creme --emit-icecreme icecreme/compiler-run.scm icecreme/compiler-run.ice

embedded_compiler_run.c: compiler-run.ice tools/bin2c
	tools/bin2c compiler-run.ice creme_embedded_compiler_run_ice > $@

LIBCREME_SRCS := $(filter-out main.c,$(SRCS)) embed.c embedded_compiler_run.c
LIBCREME_OBJS := $(LIBCREME_SRCS:.c=.lib.o)

.PHONY: lib
lib: libcreme.a

libcreme.a: $(LIBCREME_OBJS)
	ar rcs $@ $(LIBCREME_OBJS)

%.lib.o: %.c *.h
	$(CC) $(CFLAGS) -fPIC -c -o $@ $<

clean:
	rm -f $(OBJS) $(SANITIZE_OBJS) $(FUZZ_OBJS) $(LIBCREME_OBJS) $(BIN) $(SANBIN) $(FUZZBIN) libcreme.a
	rm -f tools/bin2c embedded_compiler_run.c
	rm -rf fuzz/corpus
