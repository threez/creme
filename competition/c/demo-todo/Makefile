CC ?= cc
FIO := vendor/facil.io
FIO_LIB := $(FIO)/lib/facil

# pkg-config, not a hardcoded -lsqlite3, since sqlite3.h/libsqlite3 don't
# always live on the compiler's default search path (e.g. /usr/local on
# this project's own FreeBSD dev box) -- falls back to the old bare
# -lsqlite3 if pkg-config doesn't know about it, same "degrade, don't
# fail outright" convention cvm/Makefile's own pkg-config lookups use.
SQLITE3_CFLAGS != pkg-config --cflags sqlite3 2>/dev/null
SQLITE3_LIBS != pkg-config --libs sqlite3 2>/dev/null || echo -lsqlite3

CFLAGS := -std=c11 -O3 -Wall -Wextra -Wno-missing-field-initializers \
          -I$(FIO_LIB) -I$(FIO_LIB)/fiobj -I$(FIO_LIB)/http -I$(FIO_LIB)/http/parsers \
          $(SQLITE3_CFLAGS)
LDLIBS := $(SQLITE3_LIBS) -lpthread -lm

# `!=` + `find | tr` (not GNU-only $(wildcard ...), which BSD make doesn't
# just mis-parse but outright fails a build on -- see competition/
# Makefile's own header comment for the same portable idiom) -- joined to
# one space-separated line since a `!=` variable holding find's default
# newline-separated output breaks BSD make's own prerequisite parsing.
FIOBJ_SRC != find $(FIO_LIB)/fiobj -name '*.c' | tr '\n' ' '

FIO_SRC := $(FIO_LIB)/fio.c \
           $(FIOBJ_SRC) \
           $(FIO_LIB)/http/http.c \
           $(FIO_LIB)/http/http1.c \
           $(FIO_LIB)/http/http_internal.c \
           $(FIO_LIB)/http/websockets.c

$(FIO_LIB)/fio.c:
	git clone --branch 0.7.6 --depth 1 https://github.com/boazsegev/facil.io $(FIO)

bin/app: $(FIO_LIB)/fio.c main.c
	mkdir -p bin
	$(CC) $(CFLAGS) -o bin/app main.c $(FIO_SRC) $(LDLIBS)

.PHONY: clean
clean:
	rm -rf bin
