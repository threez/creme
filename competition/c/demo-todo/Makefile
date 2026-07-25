CC ?= cc
FIO := vendor/facil.io
FIO_LIB := $(FIO)/lib/facil

CFLAGS := -std=c11 -O3 -Wall -Wextra -Wno-missing-field-initializers \
          -I$(FIO_LIB) -I$(FIO_LIB)/fiobj -I$(FIO_LIB)/http -I$(FIO_LIB)/http/parsers
LDLIBS := -lsqlite3 -lpthread -lm

FIO_SRC := $(FIO_LIB)/fio.c \
           $(wildcard $(FIO_LIB)/fiobj/*.c) \
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
