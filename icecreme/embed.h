/* Embedding-convenience API for a host C program linking against
 * libcreme.a — see embed.c's own header comment and icecreme/README.md's
 * "Embedding" section for the full minimal call sequence a host program
 * needs. The functions declared above this header's own "Value/argument
 * helpers" section (`creme_runtime_init`/`creme_register_global`/
 * `creme_run_repl`/`creme_run_scheme_file`) are net-new capabilities for an
 * external embedder, implemented in embed.c and kept out of the CLI
 * binary's own SRCS (main.c never calls them). The `static inline`
 * "Value/argument helpers" section below it, though, is plain header-only
 * code with no link-time footprint — icecreme's own `bi_*` builtins
 * (builtins.c/creme_ffi.c/etc.) use those directly too, to avoid
 * duplicating the same arity/type-check/GC_MALLOC boilerplate this header
 * exists to collect in one place. */
#ifndef CREME_EMBED_H
#define CREME_EMBED_H

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include <gc.h>

#include "vm.h"

/* Bundles every process-global, one-time, order-sensitive runtime-startup
 * step icecreme's own main.c otherwise inlines: GC_INIT(), a default 256MB
 * GC_expand_hp sizing (skipped if GC_INITIAL_HEAP_SIZE is already set,
 * matching main.c's own convention), GC_set_oom_fn, and mp_set_memory_
 * functions redirecting GMP's allocator through Boehm GC. Call this exactly
 * once per process, before creme_alloc_vm and before touching any Scheme
 * rational (mp_set_memory_functions must run before any mpq_init anywhere
 * in the process — GMP has no per-instance allocator, only this one
 * process-wide setting). */
void creme_runtime_init(void);

/* Defines a plain (non-function) Scheme global — the value-side counterpart
 * of creme_register_builtin (vm.h). Mirrors it exactly: interns `name` via
 * creme_global_intern and writes `value`/bound=1 into that slot. Use
 * creme_register_builtin instead for a native C function; use this for a
 * host-defined constant (a version string, a config value already known at
 * startup, etc.). */
void creme_register_global(VM *vm, const char *name, Value value);

/* Runs an interactive REPL against `vm` (reads from stdin, writes to
 * stdout) — a thin wrapper over creme_run_scheme_file("icecreme/repl.scm"),
 * the repo's own 2-line `(creme repl)` shim (see embed.c's own comment for
 * why this compiles it fresh rather than loading a separately precompiled
 * repl.ice directly). Same repo-root-relative-CWD requirement as
 * creme_run_scheme_file below applies. Register whatever builtins/globals
 * the host wants reachable from the REPL BEFORE calling this
 * (creme_register_all_builtins, or creme_register_required_builtins with a
 * specific family list, plus any creme_register_builtin/creme_register_
 * global calls of the host's own) — same ordering rule as
 * creme_run_scheme_file below. */
void creme_run_repl(VM *vm);

/* Compiles and runs a plain `.scm` source file directly — no Crystal
 * `creme --emit-icecreme` step, no `.ice` file for the host to ship. Uses
 * the library's own bundled, precompiled self-hosted-compiler driver
 * (embedded at build time — see embedded_compiler_run.c, generated from
 * icecreme/compiler-run.scm) exactly the way icecreme's own CLI "compiler
 * mode" already does for a file-based driver (main.c) — creme_set_target_
 * path(scm_path), then load-and-run the driver's own chunk, which reads,
 * compiles, and runs the real target internally (recomputing and
 * registering whatever native builtin families THAT script needs along the
 * way — see bootstrap.c's bi_load_chunk_bytes).
 *
 * Register any of the host's OWN native functions/globals (creme_register_
 * builtin/creme_register_global) at any point before calling this — the
 * self-hosted compiler resolves every free identifier to a plain by-name
 * global reference at compile time regardless of whether anything is bound
 * to it yet (no compile-time "known global" check), so the host's names
 * are simply available the moment this call actually starts executing the
 * compiled target, in whatever order they were registered relative to this
 * call, as long as it's before.
 *
 * `scm_path` is resolved relative to the CALLING PROCESS's own current
 * working directory, not this binary's location or scm_path's own
 * directory — the self-hosted compiler looks up every library the script
 * imports via a repo-root-relative path (modules/scheme/ .sld files), same
 * assumption icecreme's own CLI already makes everywhere. A host embedding
 * this outside the repo needs either the repo root as its CWD, or to
 * vendor modules/ (with a matching relative scm_path) alongside its own
 * binary — see icecreme/README.md's "Embedding" section. */
void creme_run_scheme_file(VM *vm, const char *scm_path);

/* ===========================================================================
 * Value/argument helpers for writing a native BuiltinFn (see vm.h/value.h)
 * ===========================================================================
 *
 * The same handful of steps every icecreme-internal `bi_*` function in
 * builtins.c/creme_ffi.c/etc. already hand-rolls at its own call site
 * (validate arity, validate/convert one argument, build a fresh return
 * Value) — collected here as `static inline` helpers so a host's own
 * native functions can skip the boilerplate. `static inline` (not part of
 * embed.c/libcreme.a) since these need no state of their own beyond their
 * arguments — free to inline away entirely, no new link-time surface.
 *
 * Every `creme_arg_*` extractor takes the same four arguments in the same
 * order — `(args, nargs, index, who)`, mirroring a BuiltinFn's own
 * `(vm, args, nargs)` parameter list plus the argument position being
 * read — and aborts via `creme_abort` (vm.h) naming `who` (conventionally
 * the Scheme-visible procedure name, e.g. "host-greet") if `index` is out
 * of range or the argument has the wrong type; there is deliberately no
 * "did this fail" return code to check, matching every other icecreme
 * builtin's own error convention (an out-of-band C error/errno return
 * would be silently ignorable in a way an abort isn't). */

/* Extracts argument `index` as a `T_INT` value's raw `int64_t`. */
static inline int64_t creme_arg_int(Value *args, int nargs, int index, const char *who) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  if (args[index].tag != T_INT) creme_abort("%s: argument %d: expected an integer", who, index + 1);
  return args[index].as.i;
}

/* Extracts argument `index` as a `double`, widening an exact int/rational
 * the same way every numeric builtin already does — see vm.h's own
 * `as_double` (vm.c), which this reuses directly rather than re-deriving
 * the same int/rational/float promotion logic. */
static inline double creme_arg_double(Value *args, int nargs, int index, const char *who) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  return as_double(args[index], who);
}

/* Extracts argument `index` as a `T_BOOL` value's raw truth value (0/1). */
static inline int creme_arg_bool(Value *args, int nargs, int index, const char *who) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  if (args[index].tag != T_BOOL) creme_abort("%s: argument %d: expected a boolean", who, index + 1);
  return args[index].as.b;
}

/* Extracts argument `index` as a `T_STR` value, returned as a fresh,
 * GC_MALLOC'd, NUL-terminated C string (icecreme's own Scheme strings are
 * a pointer+length pair, value.h, not NUL-terminated-guaranteed — see
 * creme_ffi.c's bi_ffi_open for the same copy-out idiom this mirrors). */
static inline const char *creme_arg_cstr(Value *args, int nargs, int index, const char *who) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  if (args[index].tag != T_STR) creme_abort("%s: argument %d: expected a string", who, index + 1);
  int len = args[index].aux;
  char *copy = GC_MALLOC((size_t)len + 1);
  memcpy(copy, args[index].as.chars, (size_t)len);
  copy[len] = '\0';
  return copy;
}

/* Extracts argument `index` as a `T_STR` value's raw `(pointer, length)`
 * slice — no copy, no NUL termination, just the validated Scheme string's
 * own backing bytes exactly as `args[index].as.chars`/`.aux` already hold
 * them. For read-only use (hashing, scanning, anything that doesn't need
 * a real C string handed to an external API) — use creme_arg_cstr instead
 * when a NUL-terminated copy is genuinely needed. */
static inline const char *creme_arg_bytes(Value *args, int nargs, int index, const char *who, int *len_out) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  if (args[index].tag != T_STR) creme_abort("%s: argument %d: expected a string", who, index + 1);
  *len_out = args[index].aux;
  return args[index].as.chars;
}

/* Extracts argument `index` as a `T_VECTOR` value's backing storage
 * directly (no copy needed — Vector, value.h, is already a flat, already-
 * GC-owned `Value*`+length pair). Writes the vector's length to `*len_out`
 * and returns its items pointer; index each element as an ordinary
 * `Value` (use the other `creme_arg_*`-style checks, or a plain `.tag`
 * switch, per element as needed). */
static inline Value *creme_arg_vector(Value *args, int nargs, int index, const char *who, int *len_out) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  if (args[index].tag != T_VECTOR) creme_abort("%s: argument %d: expected a vector", who, index + 1);
  *len_out = args[index].as.vec->len;
  return args[index].as.vec->items;
}

/* Wraps an already NUL-terminated C string into a fresh Scheme string
 * Value (strlen's it, GC_MALLOC's an owned copy, then `v_str`s it) — for
 * returning a plain string (or defining a `creme_register_global` constant)
 * without hand-counting a literal's length the way `v_str("...", N)`
 * otherwise requires. */
static inline Value creme_cstr_value(const char *s) {
  size_t len = strlen(s);
  char *copy = GC_MALLOC(len + 1);
  memcpy(copy, s, len + 1); /* +1: copies the NUL too, harmless (v_str below ignores it) */
  return v_str(copy, (int)len);
}

/* Copies a raw `(pointer, length)` byte slice into a fresh, owned Scheme
 * string Value — the shared, public equivalent of a copy-and-wrap helper
 * several icecreme .c files each used to hand-roll their own private copy
 * of (e.g. builtins.c's own `copy_bytes`) — for building a return value
 * out of a slice that ISN'T already a NUL-terminated C string (that's
 * creme_cstr_value below). `ptr` need not be NUL-terminated and may
 * contain embedded NULs; exactly `len` bytes are copied. */
static inline Value creme_bytes_value(const char *ptr, int len) {
  char *copy = GC_MALLOC((size_t)(len > 0 ? len : 1));
  if (len > 0) memcpy(copy, ptr, (size_t)len);
  return v_str(copy, len);
}

/* Builds a fresh Scheme string Value via a `printf`-style format string —
 * e.g. `creme_format_value("Hello from C, %s!", name)`. Sizes the result
 * with one `vsnprintf(NULL, 0, ...)` pass (per C99, returns the length
 * that WOULD have been written, excluding the NUL), GC_MALLOCs exactly
 * that many bytes + 1, then formats into it for real. */
static inline Value creme_format_value(const char *fmt, ...) {
  va_list args1, args2;
  va_start(args1, fmt);
  va_copy(args2, args1);
  int len = vsnprintf(NULL, 0, fmt, args1);
  va_end(args1);
  char *buf = GC_MALLOC((size_t)len + 1);
  vsnprintf(buf, (size_t)len + 1, fmt, args2);
  va_end(args2);
  return v_str(buf, len);
}

/* Counts a Scheme list Value's own pair spine — the number of leading
 * `T_PAIR` cells before hitting a non-pair (a proper list's own `T_NIL`
 * tail, or anything else for an improper one). Doesn't itself validate
 * properness — pass the result as `max` to creme_list_to_values, which
 * does, to size a stack/GC-allocated buffer before converting. */
static inline int creme_list_length(Value list) {
  int n = 0;
  while (list.tag == T_PAIR) {
    n++;
    list = list.as.pair->cdr;
  }
  return n;
}

/* Copies a proper Scheme list's elements into `out` (caller-provided,
 * room for at least `max` — see creme_list_length to size it first),
 * returning the count actually written. Aborts via `who` if the list
 * isn't a proper one (a non-nil, non-pair tail) or has more than `max`
 * elements — this never silently truncates. */
static inline int creme_list_to_values(Value list, Value *out, int max, const char *who) {
  int n = 0;
  while (list.tag == T_PAIR) {
    if (n >= max) creme_abort("%s: list has more than %d element(s)", who, max);
    out[n++] = list.as.pair->car;
    list = list.as.pair->cdr;
  }
  if (list.tag != T_NIL) creme_abort("%s: expected a proper (nil-terminated) list", who);
  return n;
}

/* Builds a proper Scheme list from a C array of `n` Values, via
 * `creme_cons` (vm.h/vm.c — the VM's own batch-refilled pair freelist,
 * not a raw GC_MALLOC) — the same right-fold-from-the-end idiom vm.c's
 * own list-building call sites already use, so a freshly built list is
 * indistinguishable from one a Scheme program itself `cons`'d together. */
static inline Value creme_list_from_values(VM *vm, Value *items, int n) {
  Value list = v_nil();
  for (int i = n - 1; i >= 0; i--) list = creme_cons(vm, items[i], list);
  return list;
}

/* Builds a fresh Scheme vector from a C array of `n` Values — a straight
 * GC_MALLOC'd copy (Vector, value.h, is a flat, GC-owned `Value*`+length
 * pair, needing no VM state to allocate, unlike creme_list_from_values'
 * own creme_cons; `n == 0` still allocates a valid, zero-length Vector
 * rather than a NULL items pointer, so `vector-length`/etc. on it behave
 * normally). */
static inline Value creme_vector_from_values(Value *items, int n) {
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->items = GC_MALLOC(sizeof(Value) * (size_t)(n > 0 ? n : 1));
  for (int i = 0; i < n; i++) vec->items[i] = items[i];
  vec->len = n;
  return v_vector(vec);
}

#endif
