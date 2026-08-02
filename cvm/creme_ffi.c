/* (creme ffi) — see creme_ffi.h.
 *
 * A generic dlopen/libffi bridge instead of a hand-written native module
 * per C library (this file's siblings — regex.c/sql.c/csv.c/etc. — each
 * expose one specific library's own fixed surface; this one lets Scheme
 * code call ANY native function by name/signature at runtime). Mirrors
 * src/creme/modules/creme/ffi.cr's own surface exactly:
 *
 *   (ffi-open "libm.so.6")                          -> lib handle (box)
 *   (ffi-function lib "sqrt" 'double '(double))      -> func handle (box)
 *   (ffi-call fn (list 4.0))                         -> 2.0
 *   (ffi-close lib)
 *   (ffi-pointer-ref ptr offset 'int32)              -> read a struct field
 *   (ffi-pointer-set! ptr offset 'int32 42)          -> write a struct field
 *   (ffi-type-size 'int32)                           -> 4
 *   (ffi-gc-malloc 16)                               -> GC-owned scratch pointer
 *   (ffi-gc-free ptr)                                -> optional early release
 *
 * MVP type-marshalling scope, deliberately narrow (matches the Crystal
 * side): 'void (return only, and not valid for ffi-pointer-ref/-set!),
 * 'int32, 'int64, 'double, 'bool, 'string (char*, copy-in/copy-out),
 * 'pointer (an opaque box round-tripped through BOX_KIND_FFI_POINTER).
 * NOT supported, by design: passing/returning a whole struct BY VALUE as
 * a single ffi-call argument/return value (there's no type symbol for
 * "struct"), and passing a Scheme closure as a C callback (a function
 * pointer INTO Scheme) — both real, documented non-goals, not silent
 * gaps. ffi-pointer-ref/ffi-pointer-set! DO let a script read/write an
 * individual struct FIELD, given a pointer to the struct and that
 * field's byte offset — but this bridge never computes a struct's
 * layout (alignment/padding) for you; offsets/sizes must come from the
 * real C ABI being targeted (e.g. a C `offsetof`/`sizeof` reference),
 * same as (creme foreign)'s define-foreign-struct macro documents.
 * ffi-gc-malloc gives a script scratch memory backed by THIS process's own
 * Boehm GC heap (the same allocator every other cvm Value already lives
 * in — see value.h's own header comment) instead of libc's malloc,
 * reclaimed automatically once unreachable, no matching free ever
 * required; ffi-gc-free is an optional early release, valid ONLY on a
 * pointer ffi-gc-malloc itself returned (never on a libc-malloc'd pointer
 * or one a C function handed back, e.g. a FILE*) — see bi_ffi_gc_free's
 * own comment below for why.
 *
 * SECURITY: this hands a guest script genuine native code execution and
 * every memory-safety risk that comes with it (bad signature declarations
 * corrupt the stack/heap same as in C itself, ffi-pointer-ref/-set! are
 * raw offset+type memory access with no bounds checking whatsoever, and
 * ffi-gc-free on the wrong pointer corrupts the GC's own heap bookkeeping)
 * — an embedder MUST exclude "creme ffi" from any allowed_libraries
 * allowlist for untrusted guest scripts, exactly like (creme tui)/
 * (creme rfc8439)/etc. are already documented to be. */
#include <dlfcn.h>
#include <ffi.h>
#include <gc.h>
#include <string.h>

#include "creme_ffi.h"

enum {
  FFI_T_VOID = 0,
  FFI_T_INT32,
  FFI_T_INT64,
  FFI_T_DOUBLE,
  FFI_T_BOOL,
  FFI_T_STRING,
  FFI_T_POINTER,
};

typedef struct {
  void *fnptr;
  ffi_cif cif;
  int n_args;
  int ret_kind;
  int *arg_kinds;    /* GC-owned, n_args entries */
  ffi_type **arg_types; /* GC-owned, n_args entries -- kept alive for cif */
} FfiFunc;

static int ffi_type_kind_from_sym(Value v, const char *who) {
  if (v.tag != T_SYM) cvm_abort("%s: expected a type symbol", who);
  const char *s = v.as.chars;
  int len = v.aux;
#define MATCH(lit) (len == (int)(sizeof(lit) - 1) && memcmp(s, lit, len) == 0)
  if (MATCH("void")) return FFI_T_VOID;
  if (MATCH("int32")) return FFI_T_INT32;
  if (MATCH("int64")) return FFI_T_INT64;
  if (MATCH("double")) return FFI_T_DOUBLE;
  if (MATCH("bool")) return FFI_T_BOOL;
  if (MATCH("string")) return FFI_T_STRING;
  if (MATCH("pointer")) return FFI_T_POINTER;
#undef MATCH
  cvm_abort("%s: unknown ffi type '%.*s' (expected void/int32/int64/double/bool/string/pointer)", who, len, s);
}

static ffi_type *libffi_type_for_kind(int kind) {
  switch (kind) {
  case FFI_T_VOID: return &ffi_type_void;
  case FFI_T_INT32: return &ffi_type_sint32;
  case FFI_T_INT64: return &ffi_type_sint64;
  case FFI_T_DOUBLE: return &ffi_type_double;
  case FFI_T_BOOL: return &ffi_type_sint32;
  case FFI_T_STRING: return &ffi_type_pointer;
  case FFI_T_POINTER: return &ffi_type_pointer;
  default: cvm_abort("ffi: internal: bad type kind %d", kind);
  }
}

static Value bi_ffi_open(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_STR) cvm_abort("ffi-open: expected a library path/name string");
  char *path = GC_MALLOC((size_t)args[0].aux + 1);
  memcpy(path, args[0].as.chars, (size_t)args[0].aux);
  path[args[0].aux] = '\0';
  dlerror();
  void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (!handle) {
    const char *err = dlerror();
    cvm_abort("ffi-open: %s: %s", path, err ? err : "dlopen failed");
  }
  return v_box(handle, BOX_KIND_FFI_LIB);
}

static Value bi_ffi_close(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_BOX || args[0].aux != BOX_KIND_FFI_LIB) {
    cvm_abort("ffi-close: expected a value from ffi-open");
  }
  dlclose(args[0].as.ptr);
  return v_nil();
}

static Value bi_ffi_function(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 4 || args[0].tag != T_BOX || args[0].aux != BOX_KIND_FFI_LIB || args[1].tag != T_STR) {
    cvm_abort("ffi-function: expected (lib name-string ret-type-symbol arg-type-symbol-list)");
  }
  void *handle = args[0].as.ptr;
  char *name = GC_MALLOC((size_t)args[1].aux + 1);
  memcpy(name, args[1].as.chars, (size_t)args[1].aux);
  name[args[1].aux] = '\0';

  dlerror();
  void *fnptr = dlsym(handle, name);
  const char *err = dlerror();
  if (err) cvm_abort("ffi-function: %s: %s", name, err);

  int ret_kind = ffi_type_kind_from_sym(args[2], "ffi-function");

  int n_args = 0;
  for (Value cur = args[3]; cur.tag == T_PAIR; cur = cur.as.pair->cdr) n_args++;

  int *arg_kinds = GC_MALLOC(sizeof(int) * (size_t)(n_args ? n_args : 1));
  ffi_type **arg_types = GC_MALLOC(sizeof(ffi_type *) * (size_t)(n_args ? n_args : 1));
  int i = 0;
  for (Value cur = args[3]; cur.tag == T_PAIR; cur = cur.as.pair->cdr, i++) {
    arg_kinds[i] = ffi_type_kind_from_sym(cur.as.pair->car, "ffi-function");
    arg_types[i] = libffi_type_for_kind(arg_kinds[i]);
  }

  FfiFunc *f = GC_MALLOC(sizeof(FfiFunc));
  f->fnptr = fnptr;
  f->n_args = n_args;
  f->ret_kind = ret_kind;
  f->arg_kinds = arg_kinds;
  f->arg_types = arg_types;

  ffi_status status = ffi_prep_cif(&f->cif, FFI_DEFAULT_ABI, (unsigned int)n_args,
                                    libffi_type_for_kind(ret_kind), arg_types);
  if (status != FFI_OK) cvm_abort("ffi-function: %s: ffi_prep_cif failed (status %d)", name, (int)status);

  return v_box(f, BOX_KIND_FFI_FUNC);
}

/* Fixed-size storage big enough for any one MVP scalar argument/return
 * value -- libffi hands/expects a `void *` per value that points to
 * correctly-sized+aligned storage for that value's own ffi_type, so each
 * argument (and the return value) gets one of these, addressed by
 * pointer, never copied by value into the args/rvalue arrays libffi
 * itself receives. */
typedef union {
  int32_t i32;
  int64_t i64;
  double d;
  void *ptr;
} FfiSlot;

static void marshal_arg_into(Value v, int kind, FfiSlot *slot, const char *who) {
  switch (kind) {
  case FFI_T_INT32:
    if (v.tag != T_INT) cvm_abort("%s: expected an integer argument", who);
    slot->i32 = (int32_t)v.as.i;
    return;
  case FFI_T_INT64:
    if (v.tag != T_INT) cvm_abort("%s: expected an integer argument", who);
    slot->i64 = v.as.i;
    return;
  case FFI_T_DOUBLE:
    if (v.tag == T_FLOAT) { slot->d = v.as.f; return; }
    if (v.tag == T_INT) { slot->d = (double)v.as.i; return; }
    cvm_abort("%s: expected a real-number argument", who);
  case FFI_T_BOOL:
    if (v.tag != T_BOOL) cvm_abort("%s: expected a boolean argument", who);
    slot->i32 = v.as.b ? 1 : 0;
    return;
  case FFI_T_STRING: {
    if (v.tag == T_BOOL && !v.as.b) { slot->ptr = NULL; return; } /* #f -> NULL */
    if (v.tag != T_STR) cvm_abort("%s: expected a string (or #f) argument", who);
    char *buf = GC_MALLOC((size_t)v.aux + 1);
    memcpy(buf, v.as.chars, (size_t)v.aux);
    buf[v.aux] = '\0';
    slot->ptr = buf;
    return;
  }
  case FFI_T_POINTER:
    if (v.tag == T_BOOL && !v.as.b) { slot->ptr = NULL; return; } /* #f -> NULL */
    if (v.tag != T_BOX || v.aux != BOX_KIND_FFI_POINTER) cvm_abort("%s: expected a pointer (or #f) argument", who);
    slot->ptr = v.as.ptr;
    return;
  default:
    cvm_abort("%s: internal: bad type kind %d", who, kind);
  }
}

static Value marshal_return(int kind, FfiSlot *slot) {
  switch (kind) {
  case FFI_T_VOID: return v_nil();
  case FFI_T_INT32: return v_int(slot->i32);
  case FFI_T_INT64: return v_int(slot->i64);
  case FFI_T_DOUBLE: return v_float(slot->d);
  case FFI_T_BOOL: return v_bool(slot->i32 != 0);
  case FFI_T_STRING: {
    if (!slot->ptr) return v_bool(0);
    const char *s = (const char *)slot->ptr;
    int len = (int)strlen(s);
    char *buf = GC_MALLOC((size_t)(len ? len : 1));
    memcpy(buf, s, (size_t)len);
    return v_str(buf, len);
  }
  case FFI_T_POINTER:
    if (!slot->ptr) return v_bool(0);
    return v_box(slot->ptr, BOX_KIND_FFI_POINTER);
  default:
    cvm_abort("ffi-call: internal: bad return type kind %d", kind);
  }
}

static Value bi_ffi_call(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[0].tag != T_BOX || args[0].aux != BOX_KIND_FFI_FUNC) {
    cvm_abort("ffi-call: expected (func arg-list)");
  }
  FfiFunc *f = (FfiFunc *)args[0].as.ptr;

  int given = 0;
  for (Value cur = args[1]; cur.tag == T_PAIR; cur = cur.as.pair->cdr) given++;
  if (given != f->n_args) cvm_abort("ffi-call: expected %d argument(s), got %d", f->n_args, given);

  FfiSlot *slots = GC_MALLOC(sizeof(FfiSlot) * (size_t)(f->n_args ? f->n_args : 1));
  void **arg_ptrs = GC_MALLOC(sizeof(void *) * (size_t)(f->n_args ? f->n_args : 1));
  int i = 0;
  for (Value cur = args[1]; cur.tag == T_PAIR; cur = cur.as.pair->cdr, i++) {
    marshal_arg_into(cur.as.pair->car, f->arg_kinds[i], &slots[i], "ffi-call");
    arg_ptrs[i] = &slots[i];
  }

  FfiSlot ret_slot;
  ffi_call(&f->cif, FFI_FN(f->fnptr), &ret_slot, arg_ptrs);
  return marshal_return(f->ret_kind, &ret_slot);
}

/* Shared by ffi-pointer-ref/ffi-pointer-set! -- extracts the raw base
 * pointer a struct-field access starts from, rejecting both a non-pointer
 * argument and a NULL one (dereferencing NULL is definitionally a crash;
 * this is the one guard against the single most common mistake, not a
 * general safety net -- an arbitrary offset+type still reads/writes
 * anywhere, same as real C). */
static void *ffi_pointer_base_arg(Value v, const char *who) {
  if (v.tag == T_BOOL && !v.as.b) cvm_abort("%s: pointer is null", who);
  if (v.tag != T_BOX || v.aux != BOX_KIND_FFI_POINTER) cvm_abort("%s: expected a pointer argument", who);
  if (!v.as.ptr) cvm_abort("%s: pointer is null", who);
  return v.as.ptr;
}

static Value bi_ffi_pointer_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 3 || args[1].tag != T_INT) cvm_abort("ffi-pointer-ref: expected (pointer offset type-symbol)");
  void *base = ffi_pointer_base_arg(args[0], "ffi-pointer-ref");
  int kind = ffi_type_kind_from_sym(args[2], "ffi-pointer-ref");
  if (kind == FFI_T_VOID) cvm_abort("ffi-pointer-ref: type must not be void");
  FfiSlot *slot = (FfiSlot *)((char *)base + args[1].as.i);
  return marshal_return(kind, slot);
}

static Value bi_ffi_pointer_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 4 || args[1].tag != T_INT) cvm_abort("ffi-pointer-set!: expected (pointer offset type-symbol value)");
  void *base = ffi_pointer_base_arg(args[0], "ffi-pointer-set!");
  int kind = ffi_type_kind_from_sym(args[2], "ffi-pointer-set!");
  if (kind == FFI_T_VOID) cvm_abort("ffi-pointer-set!: type must not be void");
  FfiSlot *slot = (FfiSlot *)((char *)base + args[1].as.i);
  marshal_arg_into(args[3], kind, slot, "ffi-pointer-set!");
  return v_nil();
}

static Value bi_ffi_type_size(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1) cvm_abort("ffi-type-size: expected a type symbol");
  int kind = ffi_type_kind_from_sym(args[0], "ffi-type-size");
  switch (kind) {
  case FFI_T_INT32: return v_int(4);
  case FFI_T_BOOL: return v_int(4);
  case FFI_T_INT64: case FFI_T_DOUBLE: case FFI_T_STRING: case FFI_T_POINTER: return v_int(8);
  default: cvm_abort("ffi-type-size: 'void has no size");
  }
}

/* (ffi-gc-malloc size) -- scratch memory allocated through THIS process's
 * own Boehm GC heap (the same allocator every other cvm Value already
 * lives in, see value.h's own header comment), instead of libc's malloc.
 * GC_MALLOC zero-inits, same as everywhere else it's used in this codebase.
 * Reclaimed automatically once the returned pointer becomes unreachable --
 * no matching free is ever REQUIRED, unlike a libc-malloc'd buffer. */
static Value bi_ffi_gc_malloc(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_INT || args[0].as.i < 0) cvm_abort("ffi-gc-malloc: expected a non-negative size");
  return v_box(GC_MALLOC((size_t)args[0].as.i), BOX_KIND_FFI_POINTER);
}

/* (ffi-gc-free ptr) -- an OPTIONAL early release of memory ffi-gc-malloc
 * itself returned, so a script can hand a large buffer back before the
 * next collection cycle would otherwise reclaim it. Only ever valid on a
 * pointer ffi-gc-malloc returned -- calling this on a libc-malloc'd
 * pointer, or one a C function handed back (a FILE*, a sqlite3*, ...),
 * corrupts Boehm's own heap bookkeeping, exactly as calling libc's free()
 * on memory it didn't allocate would. After this call the pointer must
 * never be read/written/passed to another call again -- the same
 * use-after-free risk as any manual C memory management, consistent with
 * this bridge's existing no-bounds-checking SECURITY posture. */
static Value bi_ffi_gc_free(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1) cvm_abort("ffi-gc-free: expected a pointer");
  void *ptr = ffi_pointer_base_arg(args[0], "ffi-gc-free");
  GC_FREE(ptr);
  return v_nil();
}

static Value bi_ffi_lib_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("ffi-lib?: expected an argument");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_FFI_LIB);
}

static Value bi_ffi_function_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("ffi-function?: expected an argument");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_FFI_FUNC);
}

static Value bi_ffi_pointer_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("ffi-pointer?: expected an argument");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_FFI_POINTER);
}

static Value bi_ffi_null_pointer_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_BOX || args[0].aux != BOX_KIND_FFI_POINTER) {
    cvm_abort("ffi-null-pointer?: expected a pointer");
  }
  return v_bool(args[0].as.ptr == NULL);
}

void cvm_register_ffi_builtins(VM *vm) {
  cvm_register_builtin(vm, "ffi-open", bi_ffi_open);
  cvm_register_builtin(vm, "ffi-close", bi_ffi_close);
  cvm_register_builtin(vm, "ffi-function", bi_ffi_function);
  cvm_register_builtin(vm, "ffi-call", bi_ffi_call);
  cvm_register_builtin(vm, "ffi-pointer-ref", bi_ffi_pointer_ref);
  cvm_register_builtin(vm, "ffi-pointer-set!", bi_ffi_pointer_set);
  cvm_register_builtin(vm, "ffi-type-size", bi_ffi_type_size);
  cvm_register_builtin(vm, "ffi-gc-malloc", bi_ffi_gc_malloc);
  cvm_register_builtin(vm, "ffi-gc-free", bi_ffi_gc_free);
  cvm_register_builtin(vm, "ffi-lib?", bi_ffi_lib_p);
  cvm_register_builtin(vm, "ffi-function?", bi_ffi_function_p);
  cvm_register_builtin(vm, "ffi-pointer?", bi_ffi_pointer_p);
  cvm_register_builtin(vm, "ffi-null-pointer?", bi_ffi_null_pointer_p);
}
