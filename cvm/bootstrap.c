/* (creme bootstrap) — see bootstrap.h.
 *
 * The cvm-side counterpart of src/scheme/modules/creme/bootstrap.cr's
 * `load-chunk-bytes`/`import!`/(indirectly) `expand-if-macro` — same
 * names/contracts, so the self-hosted compiler (modules/creme/compiler/
 * {reader,bytecode,compiler}.sld) and anything built on top of it (e.g. a
 * REPL driver) run unmodified under either backend: compile source into
 * an SCB1-format bytevector, then load-and-run it against the SAME
 * running program's own global table, entirely inside this one process --
 * no live Crystal `creme` process involved after the one-time image that
 * bundled the compiler itself was built.
 *
 * `import!` and `expand-if-macro` are here (not stubbed as "unimplemented
 * opcode"-style aborts) because the self-hosted compiler's own
 * compile-import!/compile-form! call them UNCONDITIONALLY -- import! for
 * every `(import ...)` it compiles, expand-if-macro for every ordinary
 * function call (checking whether the head resolves to a macro before
 * falling back to an ordinary Call) -- so any REPL-style use of the
 * compiler running under cvm needs both names to at least exist. */
#include <stdio.h>
#include <string.h>

#include <gc.h>

#include "bootstrap.h"

/* Set once by main.c before running the compiler driver (cvm/compiler-
 * run.scm) in compiler mode -- the path it decided needs compiling, exposed
 * to that running Scheme program via `cvm-target-path`. Mirrors vm.c's own
 * g_current_vm / profiler.c's g_profiled_vm pattern (a fixed C API with no
 * room for an extra parameter, reaching process-wide state via one static
 * global) rather than a general command-line/argv-exposing mechanism the
 * driver doesn't otherwise need. */
static const char *g_target_path = NULL;

void cvm_set_target_path(const char *path) {
  g_target_path = path;
}

/* args[0] must be a bytevector holding SCB1 bytes (typically the self-
 * hosted compiler's own compile-source-to-bytes output). Loads it against
 * THIS running program's global table (cvm_load_from_bytes interns by
 * name into the same vm->globals every other chunk already shares) and
 * runs it reentrantly (cvm_run_loaded_chunk), returning its value -- same
 * contract as the Crystal-side load-chunk-bytes builtin. */
static Value bi_load_chunk_bytes(VM *vm, Value *args, int nargs) {
  if (nargs != 1 || args[0].tag != T_BYTEVECTOR) {
    cvm_abort("load-chunk-bytes: expected a bytevector");
  }
  Bytevector *bv = args[0].as.bv;
  Chunk *chunk = cvm_load_from_bytes(vm, bv->bytes, (size_t)bv->len);
  return cvm_run_loaded_chunk(vm, chunk);
}

/* A no-op, not an error. cvm's global table is already unconditionally
 * flat -- no per-import filtering/prefixing/renaming applies at cvm's
 * runtime level regardless of backend, so "importing" a library whose
 * bindings are already in vm->globals (which is everything reachable at
 * all, since cvm has no dynamic library-loading machinery of its own) has
 * nothing left to do. A real dynamic import of a library NOT already
 * baked into the running image isn't supported -- code that tries will
 * simply hit "unbound variable" on first use of a name that was never
 * registered, same as it would without this builtin existing at all. */
static Value bi_import_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return v_nil();
}

/* Always #f -- and this is the actually correct answer, not a stub.
 * cvm's value model has no runtime Macro/SchemeSyntaxRules representation
 * at all: define-syntax/defmacro are analyze-time-only regardless of
 * backend, and their own top-level form already compiles to a no-op
 * (OP_HELPERFORM's c=3/c=4 cases -- see cvm/README.md's "Deliberate
 * cuts"). Nothing vm->globals can ever contain IS a macro, so this can
 * never truthfully find one. Real consequence: a REPL session can define
 * and use its OWN define-syntax/defmacro macros (the self-hosted
 * compiler's own macro-table is an ordinary mutable Scheme variable in
 * the loaded image, so it persists naturally across separate
 * load-chunk-bytes calls in the same process), but can never use one
 * that was only defined inside a flattened/precompiled library (e.g.
 * sxql-select! from (creme sxql)) -- that library's own macro definition
 * never produced a runtime value under cvm in the first place. */
static Value bi_expand_if_macro(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return v_bool(0);
}

/* Reads `path`'s entire contents into one T_STR -- cvm's only other file-
 * reading capability (read-line) is hardwired to stdin, so compiler mode
 * (cvm/compiler-run.scm) needs this to read the target script (and any
 * file it (include ...)s) at all. */
static Value bi_read_whole_file(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_STR) cvm_abort("read-whole-file: expected a path string");
  char *path = GC_MALLOC((size_t)args[0].as.str.len + 1);
  memcpy(path, args[0].as.str.chars, (size_t)args[0].as.str.len);
  path[args[0].as.str.len] = '\0';

  FILE *f = fopen(path, "rb");
  if (!f) cvm_abort("read-whole-file: cannot open %s", path);
  if (fseek(f, 0, SEEK_END) != 0) cvm_abort("read-whole-file: cannot seek %s", path);
  long size = ftell(f);
  if (size < 0) cvm_abort("read-whole-file: cannot determine size of %s", path);
  rewind(f);

  char *buf = GC_MALLOC((size_t)(size ? size : 1));
  size_t got = fread(buf, 1, (size_t)size, f);
  fclose(f);
  if ((long)got != size) cvm_abort("read-whole-file: truncated read of %s", path);

  return v_str(buf, (int)size);
}

/* Returns whatever path main.c decided needs compiling (see
 * cvm_set_target_path) -- the compiler driver's only way to learn what to
 * compile, since cvm has no general command-line/argv exposure. */
static Value bi_cvm_target_path(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  if (!g_target_path) cvm_abort("cvm-target-path: no target path set (not running in compiler mode)");
  return v_str(g_target_path, (int)strlen(g_target_path));
}

void cvm_register_bootstrap_builtins(VM *vm) {
  cvm_register_builtin(vm, "load-chunk-bytes", bi_load_chunk_bytes);
  cvm_register_builtin(vm, "import!", bi_import_bang);
  cvm_register_builtin(vm, "expand-if-macro", bi_expand_if_macro);
  cvm_register_builtin(vm, "read-whole-file", bi_read_whole_file);
  cvm_register_builtin(vm, "cvm-target-path", bi_cvm_target_path);
}
