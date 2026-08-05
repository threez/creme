/* (creme zstd) -- zstd-compress/zstd-decompress, backed by libzstd
 * (facebook/zstd, BSD-3-Clause). See zstd.c's own header comment, and native's
 * own (creme zstd) implementation (src/creme/modules/creme/zstd.cr, which binds
 * the same libzstd one-shot API). */
#ifndef CREME_ZSTD_H
#define CREME_ZSTD_H

#include "vm.h"

void creme_register_zstd_builtins(VM *vm);

#endif
