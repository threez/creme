# Standalone example: builds host_demo against ../../icecreme/libcreme.a,
# deliberately NOT folded into the main project's Makefile/icecreme/Makefile
# -- this is meant to read like what an external consumer of libcreme.a
# would actually write themselves, include path/link flags and all. See
# icecreme/README.md's "Embedding" section and this directory's own README.
#
# The pkg-config lines below duplicate icecreme/Makefile's own (same
# dependency set libcreme.a itself was built against — a static archive
# carries no transitive link flags, so any consumer must reproduce them);
# keep the two in sync if icecreme/Makefile's own dependency list ever
# changes.
CC ?= cc
ROOT := ../..
ICECREME := $(ROOT)/icecreme

GC_CFLAGS := $(shell pkg-config --cflags bdw-gc-threaded 2>/dev/null || pkg-config --cflags bdw-gc 2>/dev/null) -DGC_THREADS
GC_LIBS := $(shell pkg-config --libs bdw-gc-threaded 2>/dev/null || pkg-config --libs bdw-gc 2>/dev/null || echo -lgc)
PCRE2_LIBS := $(shell pkg-config --libs libpcre2-8 2>/dev/null || echo -lpcre2-8)
GMP_CFLAGS := $(shell pkg-config --cflags gmp 2>/dev/null)
GMP_LIBS := $(shell pkg-config --libs gmp 2>/dev/null || echo -lgmp)
CRYPTO_LIBS := $(shell pkg-config --libs libcrypto 2>/dev/null || echo -lcrypto)
SSL_LIBS := $(shell pkg-config --libs libssl 2>/dev/null || echo -lssl)
FFI_LIBS := $(shell pkg-config --libs libffi 2>/dev/null || echo -lffi)
YAML_LIBS := $(shell pkg-config --libs yaml-0.1 2>/dev/null || echo -lyaml)
EXECINFO_LIBS := $(if $(filter FreeBSD,$(shell uname -s)),-lexecinfo)

CFLAGS ?= -std=c11 -O2 -g -Wall -Wextra -I$(ROOT) $(GC_CFLAGS) $(GMP_CFLAGS)
LDFLAGS ?= -rdynamic
LDLIBS := -lm -lpthread -lsqlite3 -ldl $(GC_LIBS) $(PCRE2_LIBS) $(GMP_LIBS) $(CRYPTO_LIBS) $(SSL_LIBS) $(FFI_LIBS) $(YAML_LIBS) $(EXECINFO_LIBS)

.PHONY: all clean
all: host_demo

$(ICECREME)/libcreme.a:
	$(MAKE) -C $(ICECREME) lib

host_demo: host_demo.c $(ICECREME)/libcreme.a
	$(CC) $(CFLAGS) -o $@ host_demo.c $(ICECREME)/libcreme.a $(LDFLAGS) $(LDLIBS)

clean:
	rm -f host_demo
