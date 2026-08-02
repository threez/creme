/* A tiny, stable-ABI C shim libffi/dlopen bridge for (creme ffi)'s native
 * Crystal side (ffi_shim.cr) — mirrors this project's existing precedent
 * for linking a small precompiled C helper into bin/creme (lib/rfc8439's
 * chacha20_neon.o, lib/prof's libunwind/execinfo bindings). Crystal has no
 * built-in way to call a native function whose signature is only known at
 * RUNTIME (a `lib`/`@[Link]` binding is always a fixed, compile-time-known
 * signature) — libffi provides that, but faithfully declaring its own
 * `ffi_cif`/`ffi_type` struct layouts in Crystal would be fragile (ABI/
 * platform-dependent sizes) for no real benefit, since nothing outside
 * this shim ever needs to inspect their fields. This shim keeps every
 * libffi/dlopen detail behind five simple, scalar-argument functions and
 * hands back only an opaque `void *` handle, exactly like cvm's own
 * creme_ffi.c (cvm/creme_ffi.c) does independently on that side — the two
 * implementations share the design (same type-kind enum, same
 * marshalling shape) but not code, since Crystal's own SchemeValue
 * marshalling happens in ffi_shim.cr, not here.
 *
 * Type-kind ints (shared with ffi_shim.cr's own Kind enum): 0 void,
 * 1 int32, 2 int64, 3 double, 4 bool, 5 string (char*), 6 pointer. */
#include <dlfcn.h>
#include <ffi.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  void *fnptr;
  ffi_cif cif;
  ffi_type **arg_types;
  int n_args;
} CremeFfiFunc;

static ffi_type *creme_ffi_type_for_kind(int kind) {
  switch (kind) {
  case 0: return &ffi_type_void;
  case 1: return &ffi_type_sint32;
  case 2: return &ffi_type_sint64;
  case 3: return &ffi_type_double;
  case 4: return &ffi_type_sint32;
  case 5: return &ffi_type_pointer;
  case 6: return &ffi_type_pointer;
  default: return NULL;
  }
}

void *creme_ffi_dlopen(const char *path) {
  dlerror();
  return dlopen(path, RTLD_NOW | RTLD_GLOBAL);
}

/* Returns the most recent dlopen/dlsym error on this thread, or NULL if
 * the last call succeeded — callers must check immediately, before any
 * other dl* call, matching dlerror(3)'s own one-shot-per-call contract. */
const char *creme_ffi_last_error(void) {
  return dlerror();
}

void creme_ffi_dlclose(void *handle) {
  if (handle) dlclose(handle);
}

/* Resolves `name` in `handle` and prepares a libffi call interface for it.
 * Returns NULL (with creme_ffi_last_error() or a bad-type-kind explaining
 * why) on any failure — an unknown type kind can't happen from
 * ffi_shim.cr's own Kind enum, but is still checked defensively since a
 * NULL ffi_type* fed to ffi_prep_cif would otherwise crash instead of
 * failing loudly. */
void *creme_ffi_prepare(void *handle, const char *name, int ret_kind, const int *arg_kinds, int n_args) {
  dlerror();
  void *fnptr = dlsym(handle, name);
  if (dlerror()) return NULL;

  ffi_type *ret_type = creme_ffi_type_for_kind(ret_kind);
  if (!ret_type) return NULL;

  CremeFfiFunc *f = malloc(sizeof(CremeFfiFunc));
  if (!f) return NULL;
  f->fnptr = fnptr;
  f->n_args = n_args;
  f->arg_types = malloc(sizeof(ffi_type *) * (size_t)(n_args ? n_args : 1));
  if (!f->arg_types) { free(f); return NULL; }
  for (int i = 0; i < n_args; i++) {
    f->arg_types[i] = creme_ffi_type_for_kind(arg_kinds[i]);
    if (!f->arg_types[i]) { free(f->arg_types); free(f); return NULL; }
  }

  if (ffi_prep_cif(&f->cif, FFI_DEFAULT_ABI, (unsigned int)n_args, ret_type, f->arg_types) != FFI_OK) {
    free(f->arg_types);
    free(f);
    return NULL;
  }
  return f;
}

/* `arg_values[i]` must point to correctly-sized storage for prepared arg
 * i's own type (an 8-byte slot is always enough for every MVP scalar kind
 * here); `ret_value` likewise for the prepared return type — ffi_call
 * itself enforces nothing beyond what was declared to ffi_prep_cif. */
void creme_ffi_invoke(void *prepared, void **arg_values, void *ret_value) {
  CremeFfiFunc *f = (CremeFfiFunc *)prepared;
  ffi_call(&f->cif, FFI_FN(f->fnptr), ret_value, arg_values);
}

void creme_ffi_release(void *prepared) {
  CremeFfiFunc *f = (CremeFfiFunc *)prepared;
  if (!f) return;
  free(f->arg_types);
  free(f);
}
