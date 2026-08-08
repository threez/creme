CC ?= cc
FIO := vendor/facil.io
FIO_LIB := $(FIO)/lib/facil

CFLAGS := -std=c11 -O3 -Wall -Wextra -Wno-missing-field-initializers \
          -I$(FIO_LIB) -I$(FIO_LIB)/fiobj -I$(FIO_LIB)/http -I$(FIO_LIB)/http/parsers

FIO_SRC := $(FIO_LIB)/fio.c \
           $(FIO_LIB)/http/http.c \
           $(FIO_LIB)/http/http1.c \
           $(FIO_LIB)/http/http_internal.c \
           $(FIO_LIB)/http/websockets.c

$(FIO_LIB)/fio.c:
	git clone --branch 0.7.6 --depth 1 https://github.com/boazsegev/facil.io $(FIO)

# sqlite3 cflags/libs and fiobj/*.c's file list used to be `!=`-assigned
# Make variables (pkg-config, not a hardcoded -lsqlite3, since sqlite3.h/
# libsqlite3 don't always live on the compiler's default search path --
# e.g. /usr/local on this project's own FreeBSD dev box; `find` for fiobj's
# .c files since facil.io's own layout there can gain/lose files across
# versions). `!=` isn't supported by every make this project runs under
# (specifically, Apple's stock macOS make, a GNU Make frozen at 3.81 for
# licensing reasons, predates `!=` -- added in GNU Make 4.0), so both are
# computed in THIS recipe's own shell instead -- neither ever appears in a
# prerequisite list (only inside this one recipe's command line), so unlike
# icecreme/Makefile's HDRS/ICECREME_COMPILER_SLDS (which do, and need a real
# ./configure probe -- see icecreme/configure.ac), a plain recipe-time shell
# snippet is sufficient here.
bin/app: $(FIO_LIB)/fio.c main.c
	mkdir -p bin
	sqlite3_cflags=`pkg-config --cflags sqlite3 2>/dev/null`; \
	sqlite3_libs=`pkg-config --libs sqlite3 2>/dev/null || echo -lsqlite3`; \
	fiobj_src=`find $(FIO_LIB)/fiobj -name '*.c'`; \
	$(CC) $(CFLAGS) $$sqlite3_cflags -o bin/app main.c $(FIO_SRC) $$fiobj_src $$sqlite3_libs -lpthread -lm

.PHONY: clean
clean:
	rm -rf bin
