/* (creme ffi) — a generic dlopen/libffi-backed foreign-function bridge, so
 * Scheme code can call into an arbitrary native C library instead of
 * needing a hand-written native module (like this file's own siblings —
 * regex.c/sql.c/etc.) per library. See creme_ffi.c's own header comment for
 * the MVP type-marshalling scope and its deliberate non-goals. Named
 * creme_ffi.h/.c rather than ffi.h/.c to avoid colliding with system
 * libffi's own <ffi.h>, which this file includes directly. */
#ifndef CREME_CREME_FFI_H
#define CREME_CREME_FFI_H

#include "vm.h"

void creme_register_ffi_builtins(VM *vm);

#endif
