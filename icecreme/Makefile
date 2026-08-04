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
# is a no-op there anyway, required on glibc Linux systems older than the
# libc/libdl merge -- gated below alongside -lffi (CREME_WITH_FFI), since
# creme_ffi.c is the only consumer of either.
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
# ---- Optional native builtin families (icecreme/builtin_config.h) ---------
# Each of these gates one family's .c file down to an empty translation
# unit (that file's own `#if CREME_WITH_<NAME>` wrapper) and its
# BUILTIN_FAMILIES table row (builtin_families.c) -- defaulting to 1
# (included), matching every prior release's "everything always in"
# behavior. Override on the command line or via an exported env var, e.g.
# `make lib CREME_WITH_SQL=0 CREME_WITH_HTTP=0` for a trimmed libcreme.a
# (see examples/libcream/Makefile for a full minimal-dependency build, and
# icecreme/README.md's "Embedding" section for the complete family list).
# Flipping these off for the default `all`/CLI target works too, but isn't
# the primary use case -- the CLI is meant to stay full-featured; these
# knobs exist mainly for `make lib` embedders who want a trimmed library.
CREME_WITH_SQL ?= 1
CREME_WITH_HTTP ?= 1
CREME_WITH_CIPHER ?= 1
CREME_WITH_PKEY ?= 1
CREME_WITH_X509 ?= 1
CREME_WITH_DIGEST ?= 1
CREME_WITH_SECURE_RANDOM ?= 1
CREME_WITH_ACTOR ?= 1
CREME_WITH_FFI ?= 1
CREME_WITH_YAML ?= 1
CREME_WITH_MUX ?= 1
CREME_WITH_CSV ?= 1
CREME_WITH_TREELIST ?= 1
CREME_WITH_JSON ?= 1
CREME_WITH_BIGDECIMAL ?= 1
CREME_WITH_TERM ?= 1
CREME_WITH_PROCESS ?= 1
CREME_WITH_STRING ?= 1

FEATURE_DEFINES := \
  -DCREME_WITH_SQL=$(CREME_WITH_SQL) -DCREME_WITH_HTTP=$(CREME_WITH_HTTP) \
  -DCREME_WITH_CIPHER=$(CREME_WITH_CIPHER) -DCREME_WITH_PKEY=$(CREME_WITH_PKEY) \
  -DCREME_WITH_X509=$(CREME_WITH_X509) -DCREME_WITH_DIGEST=$(CREME_WITH_DIGEST) \
  -DCREME_WITH_SECURE_RANDOM=$(CREME_WITH_SECURE_RANDOM) -DCREME_WITH_ACTOR=$(CREME_WITH_ACTOR) \
  -DCREME_WITH_FFI=$(CREME_WITH_FFI) -DCREME_WITH_YAML=$(CREME_WITH_YAML) \
  -DCREME_WITH_MUX=$(CREME_WITH_MUX) -DCREME_WITH_CSV=$(CREME_WITH_CSV) \
  -DCREME_WITH_TREELIST=$(CREME_WITH_TREELIST) -DCREME_WITH_JSON=$(CREME_WITH_JSON) \
  -DCREME_WITH_BIGDECIMAL=$(CREME_WITH_BIGDECIMAL) -DCREME_WITH_TERM=$(CREME_WITH_TERM) \
  -DCREME_WITH_PROCESS=$(CREME_WITH_PROCESS) -DCREME_WITH_STRING=$(CREME_WITH_STRING)

# Link-time gating to match: -lcrypto stays linked if ANY openssl-touching
# family is on; -lssl only if http (the sole TLS consumer) is on. `filter-
# out 0` drops every disabled entry from the list -- if anything survives,
# at least one relevant family is enabled. -lpthread/$(GC_LIBS)/-lgmp/
# -lpcre2-8 stay unconditional (pthread is tied to GC_THREADS regardless of
# actor/mux; pcre2 because `regex` is a hard, non-gateable dependency of
# the bundled self-hosted compiler).
CRYPTO_FAMILIES_ON := $(filter-out 0,$(CREME_WITH_HTTP) $(CREME_WITH_CIPHER) $(CREME_WITH_PKEY) \
                                      $(CREME_WITH_X509) $(CREME_WITH_DIGEST) $(CREME_WITH_SECURE_RANDOM) \
                                      $(CREME_WITH_ACTOR))
CRYPTO_LIBS := $(if $(strip $(CRYPTO_FAMILIES_ON)),$(CRYPTO_LIBS))
SSL_LIBS := $(if $(filter-out 0,$(CREME_WITH_HTTP)),$(SSL_LIBS))
SQL_LDLIBS := $(if $(filter-out 0,$(CREME_WITH_SQL)),-lsqlite3)
FFI_LDLIBS := $(if $(filter-out 0,$(CREME_WITH_FFI)),$(FFI_LIBS) -ldl)
YAML_LDLIBS := $(if $(filter-out 0,$(CREME_WITH_YAML)),$(YAML_LIBS))

CFLAGS ?= -std=c11 -O2 -g -fno-omit-frame-pointer -Wall -Wextra -Wno-missing-field-initializers \
          -Ivendor/verstable -Ivendor/sds -Ivendor/picohttpparser \
          $(GC_CFLAGS) $(PCRE2_CFLAGS) $(GMP_CFLAGS) $(CRYPTO_CFLAGS) $(SSL_CFLAGS) $(FFI_CFLAGS) $(YAML_CFLAGS) \
          $(FEATURE_DEFINES)
# -rdynamic: exports the executable's own (non-imported) symbols into its
# dynamic symbol table so dladdr(3) can resolve them on Linux/glibc — a no-op
# on Darwin, where dladdr already sees the main binary's local symbol table.
LDFLAGS ?= -rdynamic
# backtrace(3)/execinfo.h (profiler.c's SIGPROF sampler) ship inside libc on
# Linux/glibc and Darwin, but FreeBSD splits them into their own libexecinfo
# (part of the base system, not a package) — link it there only, so this
# stays a no-op everywhere else.
EXECINFO_LIBS := $(if $(filter FreeBSD,$(shell uname -s)),-lexecinfo)
LDLIBS := -lm -lpthread $(SQL_LDLIBS) $(GC_LIBS) $(PCRE2_LIBS) $(GMP_LIBS) $(CRYPTO_LIBS) $(SSL_LIBS) $(FFI_LDLIBS) $(YAML_LDLIBS) $(EXECINFO_LIBS)

# embedded_icecreme.c (bin2c of icecreme.ice, generated below) is in
# the CLI's own SRCS now, not just the library's: main.c's no-args REPL mode
# loads the compiler-mode driver from these embedded bytes rather than reading
# icecreme/icecreme.ice off disk (the file-based compiler mode below still
# reads it from disk, unchanged). This makes `make all` depend on regenerating
# icecreme.ice via ./bin/creme, same build-time dependency the `lib` target
# already had.
SRCS = main.c loader.c vm.c builtins.c hashtable.c sql.c mux.c strings.c profiler.c bootstrap.c regex.c process.c csv.c treelist.c actor.c digest.c json.c bigdecimal.c http.c term.c creme_ffi.c yaml.c secure_random.c cipher.c pkey.c x509.c builtin_families.c embedded_icecreme.c \
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
# the ICE bytecode deserializer, the one place icecreme treats a byte blob as
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
# instead of linked into a binary -- one monolithic library, gated by the
# same CREME_WITH_<NAME> family macros as the CLI build above (a caller
# building just `lib` can pass a trimmed CREME_WITH_*=0 set without
# touching `all`'s own object files at all, since .lib.o is its own
# distinct object suffix -- see examples/libcream/Makefile for a concrete
# minimal build). -fPIC on its own object suffix (.lib.o, distinct from
# plain .o/.san.o/.fuzz.o) costs nothing today and leaves the door open to
# a future .so from the same objects.
#
# embed.c/embedded_icecreme.c are library-ONLY additions -- deliberately
# not part of $(SRCS)/the CLI binary, which keeps its own existing
# file-based compiler-mode (main.c's CREME_COMPILER_DRIVER_PATH) completely
# unchanged. Only the self-hosted-compiler driver gets bundled as embedded
# bytes, not the REPL too -- creme_run_repl (embed.c) instead compiles
# icecreme/repl.scm fresh through the same bundled-compiler mechanism at
# call time (a precompiled repl.ice loaded standalone is missing
# interaction-environment -- see embed.c's own comment on creme_run_repl).
tools/bin2c: tools/bin2c.c
	$(CC) -O2 -o $@ $<

# ---- Self-hosting bootstrap -------------------------------------------------
# The whole icecreme.scm CLI program (self-hosted compiler + disassembler +
# dispatcher) is compiled to one ICE chunk and bin2c'd into the binary. That
# compilation is done BY ICECREME ITSELF -- the shipped compiler image is
# self-hosted, not produced by the native Crystal bin/creme. Because building
# the binary needs the chunk and self-compiling the chunk needs a binary, the
# cycle is broken with a throwaway bootstrap binary:
#
#   stage 0  icecreme-boot : an intermediate binary whose embedded chunk WAS
#                            compiled by bin/creme (the one remaining use of the
#                            native compiler, only to bootstrap).
#   stage 1  icecreme      : the real binary, whose embedded chunk icecreme-boot
#                            --emit-icecreme --static-compiled from the SAME
#                            icecreme.scm. `--static` inlines every imported .sld
#                            so the image is self-contained (what native's
#                            IcecremeEmitter does too).
#
# Soundness rests on the byte-for-byte fixpoint -- icecreme compiling itself
# yields an identical chunk (spec/creme/compiler_self_host_spec.scm). Both the
# boot and final chunks depend on icecreme.scm AND every .sld the self-hosted
# compiler bundles (recursively under modules/creme/), so a change to e.g.
# compiler.sld/bytecode.sld regenerates them and the binary -- never a stale
# image. `make bootstrap-clean` (below) drops just the stage-0 artifacts to
# force a fresh native bootstrap if the self-compile ever diverges.
ICECREME_COMPILER_SLDS := $(shell find ../modules/creme -name '*.sld')

# stage 0: bin/creme compiles the chunk, bin2c'd (under the SAME symbol) into a
# bootstrap binary. This binary is never shipped -- only used to self-compile.
icecreme-boot.ice: icecreme.scm $(ICECREME_COMPILER_SLDS)
	cd .. && ./bin/creme --emit-icecreme icecreme/icecreme.scm icecreme/icecreme-boot.ice

embedded_icecreme_boot.c: icecreme-boot.ice tools/bin2c
	tools/bin2c icecreme-boot.ice creme_embedded_icecreme_ice > $@

BOOT_OBJS := $(filter-out embedded_icecreme.o,$(OBJS)) embedded_icecreme_boot.o
icecreme-boot: $(BOOT_OBJS)
	$(CC) $(CFLAGS) -o $@ $(BOOT_OBJS) $(LDFLAGS) $(LDLIBS)

# stage 1: the bootstrap binary self-compiles the shipped chunk (--static, so
# self-contained). This is what makes the build self-hosting.
icecreme.ice: icecreme.scm $(ICECREME_COMPILER_SLDS) icecreme-boot
	cd .. && ./icecreme/icecreme-boot --emit-icecreme --static icecreme/icecreme.scm icecreme/icecreme.ice

embedded_icecreme.c: icecreme.ice tools/bin2c
	tools/bin2c icecreme.ice creme_embedded_icecreme_ice > $@

# embedded_icecreme.c already comes in via $(SRCS) now (see its comment
# above), so it's not repeated here -- only embed.c stays a library-only
# addition (main.c never calls its creme_run_scheme_file/creme_run_repl API).
LIBCREME_SRCS := $(filter-out main.c,$(SRCS)) embed.c
LIBCREME_OBJS := $(LIBCREME_SRCS:.c=.lib.o)

.PHONY: lib
lib: libcreme.a

libcreme.a: $(LIBCREME_OBJS)
	ar rcs $@ $(LIBCREME_OBJS)

%.lib.o: %.c *.h
	$(CC) $(CFLAGS) -fPIC -c -o $@ $<

# Drops ONLY the stage-0 bootstrap artifacts (see the self-hosting section
# above), forcing the next build to re-bootstrap the embedded chunk from a fresh
# bin/creme --emit-icecreme. Use this if a self-compile ever diverges from the
# native bootstrap (a real compiler bug the OLD binary can't compile past).
.PHONY: bootstrap-clean
bootstrap-clean:
	rm -f icecreme-boot icecreme-boot.ice embedded_icecreme_boot.c embedded_icecreme_boot.o

clean:
	rm -f $(OBJS) $(SANITIZE_OBJS) $(FUZZ_OBJS) $(LIBCREME_OBJS) $(BIN) $(SANBIN) $(FUZZBIN) libcreme.a
	rm -f tools/bin2c embedded_icecreme.c
	rm -f icecreme-boot icecreme-boot.ice embedded_icecreme_boot.c embedded_icecreme_boot.o icecreme.ice
	rm -rf fuzz/corpus
