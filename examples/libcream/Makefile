# Standalone example: builds host_demo against ../../icecreme/libcreme.a,
# deliberately NOT folded into the main project's Makefile/icecreme/Makefile
# -- this is meant to read like what an external consumer of libcreme.a
# would actually write themselves, include path/link flags and all. See
# icecreme/README.md's "Embedding" section and this directory's own README.
#
# host_demo.scm only imports (scheme base)/(scheme write), so this demo
# builds libcreme.a with every optional native builtin family
# (icecreme/builtin_config.h) compiled OUT -- see the CREME_WITH_* flags
# passed to `$(MAKE) -C $(ICECREME) lib` below -- demonstrating the
# smallest dependency set an embedder can get. Only what's left
# unconditional in icecreme/Makefile survives: libm, pthread (tied to GC
# threading), Boehm GC, GMP (T_RATIONAL), and PCRE2 (regex is a hard,
# non-gateable dependency of the bundled self-hosted compiler) -- no
# sqlite3/openssl/libffi/libyaml. A host wanting one of those families back
# just drops its CREME_WITH_<NAME>=0 override below (or overrides it back
# to =1) and adds the matching pkg-config lines/LDLIBS, same as
# icecreme/Makefile's own.
#
# The pkg-config lines below duplicate icecreme/Makefile's own trimmed
# dependency set (the same one libcreme.a itself was built against here —
# a static archive carries no transitive link flags, so any consumer must
# reproduce them); keep the two in sync if icecreme/Makefile's own
# dependency list ever changes.
CC ?= cc
ROOT := ../..
ICECREME := $(ROOT)/icecreme

# `!=` (shell-output assignment), not GNU-only `$(shell ...)`/`$(if $(filter ...))`
# -- same portable BSD+GNU subset as icecreme/Makefile, so this demo builds under
# either `make` or `gmake`. -DGC_THREADS is joined at the make level (outside the
# shell command) rather than appended inside `$(shell ...)`.
GC_PKG_CFLAGS != pkg-config --cflags bdw-gc-threaded 2>/dev/null || pkg-config --cflags bdw-gc 2>/dev/null
GC_CFLAGS = $(GC_PKG_CFLAGS) -DGC_THREADS
GC_LIBS != pkg-config --libs bdw-gc-threaded 2>/dev/null || pkg-config --libs bdw-gc 2>/dev/null || echo -lgc
PCRE2_LIBS != pkg-config --libs libpcre2-8 2>/dev/null || echo -lpcre2-8
GMP_CFLAGS != pkg-config --cflags gmp 2>/dev/null
GMP_LIBS != pkg-config --libs gmp 2>/dev/null || echo -lgmp
# libzstd is a REQUIRED core dependency: the embedded compiler image is a
# zstd-compressed ICE container, so libcreme.a's loader always decompresses --
# it must be linked even for this minimal build.
ZSTD_CFLAGS != pkg-config --cflags libzstd 2>/dev/null
ZSTD_LIBS != pkg-config --libs libzstd 2>/dev/null || echo -lzstd
EXECINFO_LIBS != case "$$(uname -s)" in FreeBSD) echo -lexecinfo;; esac

# Every optional family off -- host_demo.scm needs none of them.
MINIMAL_FAMILY_FLAGS := \
  CREME_WITH_SQL=0 CREME_WITH_HTTP=0 CREME_WITH_CIPHER=0 CREME_WITH_PKEY=0 CREME_WITH_X509=0 \
  CREME_WITH_DIGEST=0 CREME_WITH_SECURE_RANDOM=0 CREME_WITH_ACTOR=0 CREME_WITH_FFI=0 CREME_WITH_YAML=0 \
  CREME_WITH_MUX=0 CREME_WITH_CSV=0 CREME_WITH_TREELIST=0 CREME_WITH_JSON=0 CREME_WITH_BIGDECIMAL=0 \
  CREME_WITH_TERM=0 CREME_WITH_PROCESS=0 CREME_WITH_STRING=0

# Mandatory flags kept in their own variable (applied as `$(CREME_CFLAGS)
# $(CFLAGS)`), not in a `CFLAGS ?=` default: BSD make predefines CFLAGS (to
# `-O2 -pipe`), which would defeat `?=` and drop the -std/-I flags. User
# $(CFLAGS)/$(LDFLAGS) still append on top. Same idiom as icecreme/Makefile.
CREME_CFLAGS = -std=c11 -O2 -g -Wall -Wextra -I$(ROOT) $(GC_CFLAGS) $(GMP_CFLAGS) $(ZSTD_CFLAGS)
CREME_LDFLAGS = -rdynamic
LDLIBS := -lm -lpthread $(GC_LIBS) $(PCRE2_LIBS) $(GMP_LIBS) $(ZSTD_LIBS) $(EXECINFO_LIBS)

.PHONY: all clean
all: host_demo

$(ICECREME)/libcreme.a:
	$(MAKE) -C $(ICECREME) lib $(MINIMAL_FAMILY_FLAGS)

host_demo: host_demo.c $(ICECREME)/libcreme.a
	$(CC) $(CREME_CFLAGS) $(CFLAGS) -o $@ host_demo.c $(ICECREME)/libcreme.a $(CREME_LDFLAGS) $(LDFLAGS) $(LDLIBS)

clean:
	rm -f host_demo
