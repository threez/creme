CC ?= cc

# facil.io -- vendored the same way competition/c/demo-todo does (clone the
# pinned tag on first build only; never committed). Backs (creme hash-table)
# (fiobj_hash), (creme string)/(creme format) (fiobj_str), and (creme mux)
# (http.h) -- see FIO_SRC below for exactly which of its own source files
# that needs.
FIO := vendor/facil.io
FIO_LIB := $(FIO)/lib/facil

FIO_SRC := $(FIO_LIB)/fio.c \
           $(wildcard $(FIO_LIB)/fiobj/*.c) \
           $(FIO_LIB)/http/http.c \
           $(FIO_LIB)/http/http1.c \
           $(FIO_LIB)/http/http_internal.c \
           $(FIO_LIB)/http/websockets.c

# Boehm GC (the same collector Crystal itself uses, via the bdwgc/libgc
# package) -- every heap allocation in cvm goes through GC_MALLOC/GC_REALLOC
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
# reader.sld) can run under cvm; see regex.c's own header comment for why
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

# -g -fno-omit-frame-pointer: not for debugging per se, but so --profile's
# SIGPROF sampler (backtrace(3)/dladdr(3) in profiler.c) gets meaningful
# symbol names/unwinding instead of a wall of bare addresses.
CFLAGS ?= -std=c11 -O2 -g -fno-omit-frame-pointer -Wall -Wextra -Wno-missing-field-initializers \
          -I$(FIO_LIB) -I$(FIO_LIB)/fiobj -I$(FIO_LIB)/http -I$(FIO_LIB)/http/parsers \
          $(GC_CFLAGS) $(PCRE2_CFLAGS) $(GMP_CFLAGS) $(CRYPTO_CFLAGS)
# -rdynamic: exports the executable's own (non-imported) symbols into its
# dynamic symbol table so dladdr(3) can resolve them on Linux/glibc — a no-op
# on Darwin, where dladdr already sees the main binary's local symbol table.
LDFLAGS ?= -rdynamic
LDLIBS := -lm -lpthread -lsqlite3 $(GC_LIBS) $(PCRE2_LIBS) $(GMP_LIBS) $(CRYPTO_LIBS)

SRCS = main.c loader.c vm.c builtins.c hashtable.c sql.c mux.c strings.c profiler.c bootstrap.c regex.c process.c csv.c treelist.c actor.c
OBJS = $(SRCS:.c=.o)
BIN = cvm

.PHONY: all clean
all: $(BIN)

$(FIO_LIB)/fio.c:
	git clone --branch 0.7.6 --depth 1 https://github.com/boazsegev/facil.io $(FIO)

$(BIN): $(OBJS) $(FIO_LIB)/fio.c
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(FIO_SRC) $(LDFLAGS) $(LDLIBS)

%.o: %.c *.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(BIN)
