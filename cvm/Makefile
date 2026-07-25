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
GC_CFLAGS := $(shell pkg-config --cflags bdw-gc 2>/dev/null)
GC_LIBS := $(shell pkg-config --libs bdw-gc 2>/dev/null || echo -lgc)

# -g -fno-omit-frame-pointer: not for debugging per se, but so --profile's
# SIGPROF sampler (backtrace(3)/dladdr(3) in profiler.c) gets meaningful
# symbol names/unwinding instead of a wall of bare addresses.
CFLAGS ?= -std=c11 -O2 -g -fno-omit-frame-pointer -Wall -Wextra -Wno-missing-field-initializers \
          -I$(FIO_LIB) -I$(FIO_LIB)/fiobj -I$(FIO_LIB)/http -I$(FIO_LIB)/http/parsers \
          $(GC_CFLAGS)
# -rdynamic: exports the executable's own (non-imported) symbols into its
# dynamic symbol table so dladdr(3) can resolve them on Linux/glibc — a no-op
# on Darwin, where dladdr already sees the main binary's local symbol table.
LDFLAGS ?= -rdynamic
LDLIBS := -lm -lpthread -lsqlite3 $(GC_LIBS)

SRCS = main.c loader.c vm.c builtins.c hashtable.c sql.c mux.c strings.c profiler.c
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
