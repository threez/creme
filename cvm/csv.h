/* (creme csv) -- a small, self-contained RFC4180-ish CSV reader/writer,
 * both bulk (whole string in/out, csv.cr's csv-read/csv-write/
 * csv-read-headers/csv-write-headers) and streaming (row-by-row over a
 * port, csv-reader-open/csv-reader-read!/csv-writer-open/
 * csv-writer-row!). See csv.c's own header comment for the parser/writer
 * design and how it compares to native's own (creme csv) implementation
 * (src/scheme/modules/creme/csv.cr). */
#ifndef CVM_CSV_H
#define CVM_CSV_H

#include "vm.h"

void cvm_register_csv_builtins(VM *vm);

#endif
