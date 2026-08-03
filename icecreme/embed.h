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
#include <stdint.h>
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
 * would be silently ignorable in a way an abort isn't).
 *
 * `creme_check_min_args`/`creme_check_exact_args` cover the plain arity-only
 * check every variadic-style builtin (`+`, `-`, `/`, `<`, list/vector
 * constructors, etc.) already hand-rolls as a bare `if (nargs < N)
 * creme_abort(...)` or `if (nargs != N) creme_abort(...)`, with no argument
 * extraction alongside it — unlike every `creme_arg_*` above, these check
 * arity alone and return nothing. */

/* Aborts via `who` if `nargs` is less than `min`. */
static inline void creme_check_min_args(int nargs, int min, const char *who) {
  if (nargs < min) creme_abort("%s: expected at least %d argument%s, got %d", who, min, min == 1 ? "" : "s", nargs);
}

/* Aborts via `who` if `nargs` isn't exactly `exact`. */
static inline void creme_check_exact_args(int nargs, int exact, const char *who) {
  if (nargs != exact) creme_abort("%s: expected exactly %d argument%s, got %d", who, exact, exact == 1 ? "" : "s", nargs);
}

/* Extracts argument `index` as a `T_INT` value's raw `int64_t`. */
static inline int64_t creme_arg_int(Value *args, int nargs, int index, const char *who) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  if (args[index].tag != T_INT) creme_abort("%s: argument %d: expected an integer", who, index + 1);
  return args[index].as.i;
}

/* Extracts argument `index` as a `T_CHAR` value's raw codepoint (an
 * `int64_t`, stored in the same `.as.i` field as `T_INT` — a distinct tag
 * from it, though, so this is NOT the same check as `creme_arg_int`: a
 * plain integer argument where a char was expected (or vice versa) must
 * still abort). */
static inline int64_t creme_arg_char(Value *args, int nargs, int index, const char *who) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  if (args[index].tag != T_CHAR) creme_abort("%s: argument %d: expected a char", who, index + 1);
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

/* Copies a raw `(pointer, length)` byte slice into a fresh, GC_MALLOC'd,
 * NUL-terminated C string — the plain-C-string equivalent of
 * creme_bytes_value below (which wraps the identical copy as a Scheme
 * Value instead). Several icecreme .c files each hand-rolled this exact
 * copy-and-NUL-terminate helper under their own name (actor.c's and
 * http.c's own `dupn`, x509.c's own `gc_strndup`) for building an owned C
 * string out of a Value's own (not-NUL-terminated-guaranteed) backing
 * bytes, a substring, or any other raw slice needing a real C string
 * handed to an external API — `creme_arg_cstr` below is built on this
 * directly. */
static inline char *creme_dupn(const char *s, int len) {
  char *out = GC_MALLOC((size_t)(len > 0 ? len : 1) + 1);
  if (len > 0) memcpy(out, s, (size_t)len);
  out[len > 0 ? len : 0] = '\0';
  return out;
}

/* Overflow-checked array allocation: GC_MALLOC(count * elem) after verifying
 * the product can't wrap size_t. Several builtins compute `count * sizeof(T)`
 * from a user-supplied count (make-vector, make-bytevector, ...) or double a
 * capacity (`cap * 2`) in narrow int arithmetic, both of which silently wrap
 * for large sizes and hand GC_MALLOC a bogus (tiny or huge) length -> heap
 * overflow or spurious OOM. Route any `count * elem` allocation whose count
 * isn't already bounded (e.g. by the loader's read_count cap) through here.
 * `count == 0` allocates one element so callers never see a NULL/zero-size
 * object, matching the `n ? n : 1` idiom these sites already used. */
static inline void *creme_alloc_array(size_t count, size_t elem, const char *who) {
  if (count == 0) count = 1;
  if (count > SIZE_MAX / elem) creme_abort("%s: allocation size overflow", who);
  return GC_MALLOC(count * elem);
}

/* Extracts argument `index` as a `T_STR` value, returned as a fresh,
 * GC_MALLOC'd, NUL-terminated C string (icecreme's own Scheme strings are
 * a pointer+length pair, value.h, not NUL-terminated-guaranteed — see
 * creme_ffi.c's bi_ffi_open for the same copy-out idiom this mirrors). */
static inline const char *creme_arg_cstr(Value *args, int nargs, int index, const char *who) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  if (args[index].tag != T_STR) creme_abort("%s: argument %d: expected a string", who, index + 1);
  return creme_dupn(args[index].as.chars, args[index].aux);
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

/* Extracts argument `index` as a `T_STR` OR `T_BYTEVECTOR` value's raw
 * `(pointer, length)` bytes, whichever it is — no copy either way — for
 * a builtin that accepts a "blob" interchangeably (a string used as raw
 * bytes, or an actual bytevector; a key/message is often raw binary
 * straight from e.g. (creme secure-random), not always a T_STR). Several
 * icecreme .c files each hand-rolled an identical private `value_bytes`
 * helper for exactly this union before this shared version existed
 * (cipher.c/pkey.c's own, byte-for-byte identical; digest.c's own,
 * differing only in the output pointer's exact type) — unlike
 * creme_arg_bytes above (T_STR only), this accepts either type. */
static inline const unsigned char *creme_arg_blob(Value *args, int nargs, int index, const char *who, int *len_out) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  Value v = args[index];
  if (v.tag == T_STR) {
    *len_out = v.aux;
    return (const unsigned char *)v.as.chars;
  }
  if (v.tag == T_BYTEVECTOR) {
    *len_out = v.as.bv->len;
    return v.as.bv->bytes;
  }
  creme_abort("%s: argument %d: expected a blob (string or bytevector)", who, index + 1);
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

/* Extracts argument `index` as a `T_PORT` value's `Port *` directly (no
 * copy — a `Port` is already a GC-owned struct, value.h). Does not itself
 * check the port's `kind` (input vs. output, string vs. file/stdio) —
 * callers needing a specific direction/backing still check `->kind`
 * themselves afterward, same as every existing `bi_*` port builtin does. */
static inline Port *creme_arg_port(Value *args, int nargs, int index, const char *who) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  if (args[index].tag != T_PORT) creme_abort("%s: argument %d: expected a port", who, index + 1);
  return args[index].as.port;
}

/* Extracts argument `index` as a `T_BOX` value's opaque `void *` payload,
 * validating it's specifically a box of `expected_kind` (one of value.h's
 * own `BOX_KIND_*` constants — the same second discriminant every existing
 * `args[i].tag != T_BOX || args[i].aux != BOX_KIND_X` check already tests).
 * A box's kind constants are defined per-feature-file, not by embed.h
 * itself, so `expected_kind` is a plain `int` here rather than a named
 * enum — pass the file's own `BOX_KIND_*` constant at each call site. */
static inline void *creme_arg_box(Value *args, int nargs, int index, int expected_kind, const char *who) {
  if (index >= nargs) creme_abort("%s: missing argument %d", who, index + 1);
  if (args[index].tag != T_BOX || args[index].aux != expected_kind) creme_abort("%s: argument %d: unexpected type", who, index + 1);
  return args[index].as.ptr;
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

/* Wraps a genuine STATIC STRING LITERAL (or any other buffer guaranteed
 * to outlive the VM and never be freed/mutated) directly as a Scheme
 * string Value — zero-copy, unlike creme_cstr_value above. T_STR is
 * mutable via `string-set!`, so passing anything other than a true
 * `.rodata` literal here risks a crash the moment Scheme code mutates it
 * (or silent aliasing if two Values end up sharing one buffer) — several
 * icecreme .c files each hand-rolled this exact one-liner for their own
 * fixed alist-key/tag-name literals (e.g. cipher.c/x509.c's own
 * `str_lit`, term.c's `term_lit_str`) before this shared version existed;
 * use creme_cstr_value instead for anything that ISN'T a compile-time
 * literal. */
static inline Value creme_str_lit(const char *s) { return v_str(s, (int)strlen(s)); }

/* Wraps a genuine static string literal directly as a Scheme SYMBOL
 * Value — zero-copy, the `T_SYM` equivalent of `creme_str_lit` above.
 * Safer than `creme_str_lit`'s own zero-copy wrap in one respect:
 * symbols are immutable (no `string-set!`-equivalent mutator exists for
 * `T_SYM`, see value.h's own comment — "only ever loaded into a register
 * and discarded"), so there's no mutation-aliasing risk to worry about,
 * only the ordinary "the buffer must outlive the VM" requirement every
 * zero-copy wrap here already has. */
static inline Value creme_sym_lit(const char *s) { return v_sym(s, (int)strlen(s)); }

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

/* Copies a raw `(pointer, length)` byte slice into a fresh Scheme SYMBOL
 * Value — the `T_SYM` equivalent of `creme_bytes_value` above, for
 * building a symbol out of a slice that ISN'T a genuine static literal
 * (that's `creme_sym_lit` above) — e.g. `string->symbol`, or the
 * self-hosted reader's own number-vs-symbol-token fallback. */
static inline Value creme_sym_value(const char *ptr, int len) {
  char *copy = GC_MALLOC((size_t)(len > 0 ? len : 1));
  if (len > 0) memcpy(copy, ptr, (size_t)len);
  return v_sym(copy, len);
}

/* Wraps an already-owned raw byte buffer as a fresh Bytevector Value —
 * zero-copy, the Bytevector equivalent of creme_str_lit above (unlike
 * T_STR, a Bytevector's own bytes aren't inline in the Value itself —
 * value.h's Bytevector is a separate GC-owned `unsigned char*`+length
 * struct, so even a "just wrap this pointer" constructor still needs to
 * allocate that one small struct). `bytes` should be a buffer nothing
 * else holds a reference to (typically one just GC_MALLOC'd for exactly
 * this purpose, e.g. cipher/RAND_bytes output) — for a foreign or shared
 * buffer that must not be aliased, use creme_bytevector_value below
 * instead, which copies. */
static inline Value creme_bytevector_wrap(unsigned char *bytes, int len) {
  Bytevector *bv = GC_MALLOC(sizeof(Bytevector));
  bv->bytes = bytes;
  bv->len = len;
  return v_bytevector(bv);
}

/* Copies a raw `(pointer, length)` byte slice into a fresh, owned
 * Bytevector Value — the Bytevector equivalent of creme_bytes_value
 * (T_STR) above. */
static inline Value creme_bytevector_value(const unsigned char *ptr, int len) {
  unsigned char *copy = GC_MALLOC((size_t)(len > 0 ? len : 1));
  if (len > 0) memcpy(copy, ptr, (size_t)len);
  return creme_bytevector_wrap(copy, len);
}

/* Encodes a raw `(pointer, length)` byte slice as a fresh, lowercase hex
 * Scheme string Value (2 hex chars per byte) — digest.c's own
 * `hex_encode_into` and secure_random.c's own inline encoding loop each
 * hand-rolled this identical nibble-to-hexchar table before this shared
 * version existed. */
static inline Value creme_hex_value(const unsigned char *bytes, int len) {
  static const char hexchars[] = "0123456789abcdef";
  /* (size_t)len * 2: computing `len * 2` in int overflows for len > ~1 GiB and
   * would under-allocate. */
  char *buf = GC_MALLOC(len > 0 ? (size_t)len * 2 : 1);
  for (int i = 0; i < len; i++) {
    buf[2 * i] = hexchars[bytes[i] >> 4];
    buf[2 * i + 1] = hexchars[bytes[i] & 0xf];
  }
  return v_str(buf, len * 2);
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

/* Builds a single cons pair via a raw GC_MALLOC — NOT through the VM's
 * own batch-refilled pair freelist (that's `creme_cons`, vm.h/vm.c,
 * preferred whenever a `VM*` is already in scope and freelist reuse
 * matters). Several icecreme .c files each hand-rolled this identical
 * 4-line `GC_MALLOC(sizeof(Pair))`+`->car`/`->cdr`+`v_pair` pattern in a
 * context with no `VM*` handy at all (e.g. cipher.c/x509.c's own
 * per-file `cons2`, or a parser/decoder building a result value-by-value
 * with no VM reference threaded through, json.c/yaml.c/actor.c) —
 * needing no `vm` argument is the point, not an oversight. */
static inline Value creme_raw_cons(Value car, Value cdr) {
  Pair *p = GC_MALLOC(sizeof(Pair));
  p->car = car;
  p->cdr = cdr;
  return v_pair(p);
}

/* Builds one `(key . value)` alist entry — `creme_cons(vm, ...)`'s raw,
 * no-`VM*`-needed equivalent for the single most common shape a boxed
 * Value's own alist-returning builtin constructs: a C-string key plus an
 * arbitrary Value. `key` is always copied (via creme_cstr_value, not
 * creme_str_lit) even when it happens to be a literal, deliberately —
 * several per-file `alist_pair` helpers this replaces (cipher.c/x509.c)
 * used to zero-copy-wrap literal keys directly into `.rodata`, which is
 * an aliasing/crash risk the moment Scheme code mutates a returned
 * alist's own key via `string-set!`; copying every key removes that risk
 * for a cost too small to matter (alist keys are short and this isn't a
 * hot path). Combine with `creme_list` to build a whole alist in one
 * expression: `creme_list(vm, creme_alist_pair("status", v_int(200)),
 * creme_alist_pair("body", body_val))`. */
static inline Value creme_alist_pair(const char *key, Value value) { return creme_raw_cons(creme_cstr_value(key), value); }

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

/* Builds a proper Scheme list from a fixed, statically-known set of
 * Values in one call — `creme_list(vm, a, b, c)` instead of nested
 * `creme_cons(vm, a, creme_cons(vm, b, creme_cons(vm, c, v_nil())))`. A
 * macro, not a true variadic function: the element count is derived at
 * compile time via `sizeof` on a `(Value[]){...}` compound literal (the
 * same array-literal idiom this codebase's own call sites already use,
 * e.g. builtins.c's `(Value[]){args[0], entry.as.pair->car}`), which
 * needs no sentinel value (that could collide with a real list element)
 * and no separate count argument to keep in sync with the argument list.
 * Safe against double-evaluating an argument with side effects (e.g.
 * `read_datum(vm, p)`, which advances the reader's own position) even
 * though the compound literal appears twice in the expansion: `sizeof`'s
 * operand is never evaluated for a non-VLA type (C11 6.5.3.4p2), so only
 * the ONE compound literal actually passed as `creme_list_from_values`'s
 * `items` argument runs its element expressions — the one inside
 * `sizeof` contributes only its type/size, nothing at runtime. Delegates
 * to `creme_list_from_values` above for the actual cons chain. */
#define creme_list(vm, ...) \
  creme_list_from_values((vm), (Value[]){__VA_ARGS__}, (int)(sizeof((Value[]){__VA_ARGS__}) / sizeof(Value)))

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

/* ===========================================================================
 * Boxed-type convenience helpers (hash-table/treelist/bigdecimal/regex/
 * sql/actor-ref)
 * ===========================================================================
 *
 * A `T_BOX` Value's own payload struct (`CremeHashTable`/`RRBNode`/
 * `BigDecimal`/`pcre2_code`/`sqlite3`/`ActorRef`) is `static`/private to
 * the one `.c` file that defines it (hashtable.c/treelist.c/bigdecimal.c/
 * regex.c/sql.c/actor.c) — embed.h has no access to any of them directly,
 * nor should it duplicate that logic. Instead, every helper below bridges
 * through that type's own already-registered Scheme-level procedure by
 * name, via `creme_call_global` — the same lookup-and-call sequence a
 * plain `(hash-table-set! table key value)` call from Scheme itself goes
 * through, just issued from C. This means every helper below works
 * exactly the same regardless of which `CREME_WITH_<NAME>` macros
 * (builtin_config.h) a build was compiled with: calling e.g.
 * `creme_sql_open` against a build with `CREME_WITH_SQL=0` simply aborts
 * at runtime with `creme_call_global`'s own "unbound global" message,
 * same degrade-gracefully behavior any other compiled-out family already
 * has — no `#ifdef` needed here.
 *
 * Each type gets a small, fixed CORE set (create/get/set/length-style
 * essentials), not full parity with every one of e.g. treelist's ~60
 * Scheme-level procedures — call `creme_call_global` directly by name for
 * anything beyond what's covered here. */

/* Looks up `name` as a global (interning it if not already present, same
 * as `creme_register_builtin`/`creme_register_global` do at registration
 * time) and applies it to `args`/`nargs` — the generic primitive every
 * boxed-type helper below is built on. Aborts if `name` isn't actually
 * bound to anything (creme_global_intern itself only interns a slot, it
 * doesn't fail on an unknown name, so this adds the missing check). Also
 * useful directly for calling any Scheme-level procedure by name that
 * doesn't have its own dedicated `creme_*` wrapper below. */
static inline Value creme_call_global(VM *vm, const char *name, Value *args, int nargs) {
  int slot = creme_global_intern(vm, name, (int)strlen(name));
  if (!vm->globals[slot].bound) creme_abort("creme_call_global: unbound global \"%s\"", name);
  return creme_apply(vm, vm->globals[slot].value, args, nargs);
}

/* Tag-check predicates for each boxed type below — a plain `T_BOX` +
 * `BOX_KIND_*` check, no VM/global lookup needed (mirrors each type's own
 * internal `bi_*_p` predicate). */
static inline int creme_hash_table_p(Value v) { return v.tag == T_BOX && v.aux == BOX_KIND_HASHTABLE; }
static inline int creme_treelist_p(Value v) { return v.tag == T_BOX && v.aux == BOX_KIND_TREELIST; }
static inline int creme_bigdecimal_p(Value v) { return v.tag == T_BOX && v.aux == BOX_KIND_BIGDECIMAL; }
static inline int creme_regexp_p(Value v) { return v.tag == T_BOX && v.aux == BOX_KIND_REGEX; }
static inline int creme_sql_connection_p(Value v) { return v.tag == T_BOX && v.aux == BOX_KIND_SQL; }
static inline int creme_actor_ref_p(Value v) { return v.tag == T_BOX && v.aux == BOX_KIND_ACTOR_REF; }

/* ---- hash-table (hashtable.c, always-on -- a hard dependency of the
 * bundled self-hosted compiler, see builtin_config.h) ---- */

/* `(make-hash-table)`. */
static inline Value creme_hash_table_new(VM *vm) { return creme_call_global(vm, "make-hash-table", NULL, 0); }

/* `(hash-table-set! table key value)`. */
static inline void creme_hash_table_set(VM *vm, Value table, Value key, Value value) {
  Value args[3] = {table, key, value};
  creme_call_global(vm, "hash-table-set!", args, 3);
}

/* `(hash-table-ref table key default)` -- the 3-arg form, so a missing
 * key returns `default_val` (verbatim, unless it's itself a closure/
 * builtin, in which case hash-table-ref calls it as a thunk, same as
 * calling this from Scheme would) rather than aborting. */
static inline Value creme_hash_table_get(VM *vm, Value table, Value key, Value default_val) {
  Value args[3] = {table, key, default_val};
  return creme_call_global(vm, "hash-table-ref", args, 3);
}

/* `(hash-table-contains? table key)`. */
static inline int creme_hash_table_contains(VM *vm, Value table, Value key) {
  Value args[2] = {table, key};
  return !v_falsy(creme_call_global(vm, "hash-table-contains?", args, 2));
}

/* `(hash-table-delete! table key)`. */
static inline void creme_hash_table_delete(VM *vm, Value table, Value key) {
  Value args[2] = {table, key};
  creme_call_global(vm, "hash-table-delete!", args, 2);
}

/* No native `hash-table-length` exists -- computed via `(hash-table-keys
 * table)` (a plain list) then `creme_list_length` on the result. */
static inline int creme_hash_table_length(VM *vm, Value table) {
  Value args[1] = {table};
  return creme_list_length(creme_call_global(vm, "hash-table-keys", args, 1));
}

/* ---- treelist (treelist.c, gated by CREME_WITH_TREELIST) ----
 * Immutable treelists (BOX_KIND_TREELIST) only -- mutable-treelist
 * (BOX_KIND_MUTABLE_TREELIST) is a separate box kind, not covered here. */

/* `(vector->treelist v)`, built from a plain C array via the existing
 * creme_vector_from_values. */
static inline Value creme_treelist_from_values(VM *vm, Value *items, int n) {
  Value args[1] = {creme_vector_from_values(items, n)};
  return creme_call_global(vm, "vector->treelist", args, 1);
}

/* `(treelist-length tl)`. */
static inline int creme_treelist_length(VM *vm, Value tl) {
  Value args[1] = {tl};
  return (int)creme_call_global(vm, "treelist-length", args, 1).as.i;
}

/* `(treelist-ref tl index)`. */
static inline Value creme_treelist_ref(VM *vm, Value tl, int index) {
  Value args[2] = {tl, v_int(index)};
  return creme_call_global(vm, "treelist-ref", args, 2);
}

/* Copies a treelist's elements into `out` (caller-provided, room for at
 * least `max` -- see creme_treelist_length to size it first) via
 * `(treelist->vector tl)` + creme_arg_vector, mirroring creme_list_to_
 * values' own copy-into-caller-buffer shape. Aborts via `who` if the
 * treelist has more than `max` elements. */
static inline int creme_treelist_to_values(VM *vm, Value tl, Value *out, int max, const char *who) {
  Value args[1] = {tl};
  Value vec = creme_call_global(vm, "treelist->vector", args, 1);
  int len;
  Value *items = creme_arg_vector(&vec, 1, 0, who, &len);
  if (len > max) creme_abort("%s: treelist has more than %d element(s)", who, max);
  for (int i = 0; i < len; i++) out[i] = items[i];
  return len;
}

/* ---- bigdecimal (bigdecimal.c, gated by CREME_WITH_BIGDECIMAL) ---- */

/* `(string->bigdecimal s)`. */
static inline Value creme_bigdecimal_from_cstr(VM *vm, const char *s) {
  Value args[1] = {creme_cstr_value(s)};
  return creme_call_global(vm, "string->bigdecimal", args, 1);
}

/* `(integer->bigdecimal n)`. */
static inline Value creme_bigdecimal_from_int(VM *vm, int64_t n) {
  Value args[1] = {v_int(n)};
  return creme_call_global(vm, "integer->bigdecimal", args, 1);
}

static inline Value creme_bigdecimal_add(VM *vm, Value a, Value b) {
  Value args[2] = {a, b};
  return creme_call_global(vm, "bigdecimal-add", args, 2);
}
static inline Value creme_bigdecimal_sub(VM *vm, Value a, Value b) {
  Value args[2] = {a, b};
  return creme_call_global(vm, "bigdecimal-sub", args, 2);
}
static inline Value creme_bigdecimal_mul(VM *vm, Value a, Value b) {
  Value args[2] = {a, b};
  return creme_call_global(vm, "bigdecimal-mul", args, 2);
}
static inline Value creme_bigdecimal_div(VM *vm, Value a, Value b) {
  Value args[2] = {a, b};
  return creme_call_global(vm, "bigdecimal-div", args, 2);
}

/* `(bigdecimal->string bd)` -- returns the resulting Scheme string Value
 * directly; use creme_arg_cstr/creme_arg_bytes on it if a real C string
 * is needed. */
static inline Value creme_bigdecimal_to_value(VM *vm, Value bd) {
  Value args[1] = {bd};
  return creme_call_global(vm, "bigdecimal->string", args, 1);
}

/* ---- regex (regex.c, always-on -- a hard dependency of the bundled
 * self-hosted compiler, see builtin_config.h) ---- */

/* `(regexp pattern)`, taking a plain C string pattern. */
static inline Value creme_regexp_compile(VM *vm, const char *pattern) {
  Value args[1] = {creme_cstr_value(pattern)};
  return creme_call_global(vm, "regexp", args, 1);
}

/* `(regexp-matches? re subject)`, taking a plain C string subject. */
static inline int creme_regexp_matches(VM *vm, Value re, const char *subject) {
  Value args[2] = {re, creme_cstr_value(subject)};
  return !v_falsy(creme_call_global(vm, "regexp-matches?", args, 2));
}

/* ---- sql (sql.c, gated by CREME_WITH_SQL) -- no bound-parameter support
 * in this core cut; call creme_call_global directly with a params list
 * for that. ---- */

/* `(sql-open path)`, taking a plain C string path (":memory:" for an
 * in-memory database). */
static inline Value creme_sql_open(VM *vm, const char *path) {
  Value args[1] = {creme_cstr_value(path)};
  return creme_call_global(vm, "sql-open", args, 1);
}

/* `(sql-close conn)`. */
static inline void creme_sql_close(VM *vm, Value conn) {
  Value args[1] = {conn};
  creme_call_global(vm, "sql-close", args, 1);
}

/* `(sql-execute conn sql)`, taking a plain C string SQL statement. */
static inline Value creme_sql_execute(VM *vm, Value conn, const char *sql) {
  Value args[2] = {conn, creme_cstr_value(sql)};
  return creme_call_global(vm, "sql-execute", args, 2);
}

/* `(sql-query conn sql)`. */
static inline Value creme_sql_query(VM *vm, Value conn, const char *sql) {
  Value args[2] = {conn, creme_cstr_value(sql)};
  return creme_call_global(vm, "sql-query", args, 2);
}

/* `(sql-scalar conn sql)`. */
static inline Value creme_sql_scalar(VM *vm, Value conn, const char *sql) {
  Value args[2] = {conn, creme_cstr_value(sql)};
  return creme_call_global(vm, "sql-scalar", args, 2);
}

/* ---- actor-ref (actor.c, gated by CREME_WITH_ACTOR) -- deliberately no
 * `spawn` wrapper here: it takes a Scheme closure argument a C host
 * rarely has ready-made; spawning is expected to happen from within the
 * running script itself, or via creme_call_global directly with a
 * closure Value the host already has. ---- */

/* `(send! target message)`. */
static inline void creme_actor_send(VM *vm, Value target, Value message) {
  Value args[2] = {target, message};
  creme_call_global(vm, "send!", args, 2);
}

/* `(actor-ref-id ref)` -- returns the id as a Scheme string Value. */
static inline Value creme_actor_ref_id(VM *vm, Value ref) {
  Value args[1] = {ref};
  return creme_call_global(vm, "actor-ref-id", args, 1);
}

#endif
