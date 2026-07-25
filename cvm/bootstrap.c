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

/* `args[0]` is the whole call form under consideration (e.g. `(sxql-
 * select! conn fields ...)`), same contract as the real interpreter's own
 * expand-if-macro (see modules/creme/compiler/compiler.sld's target-env-
 * macro-expand). Returns `(cons #t expansion)` if `form`'s head resolves,
 * in vm->globals, to a defmacro EXPORTED from a library compiled straight
 * to bytecode (Crystal-native, or this project's own self-hosted compiler
 * ahead of time) -- Op::HelperForm's kind==4 case (vm.c) binds exactly
 * this: a T_MACRO value wrapping the macro's raw (defmacro name
 * (params...) body...) form, e.g. sxql-select! from (creme sxql), the
 * flagship case this exists for. The actual expansion (bind params
 * positionally to the call's own raw, unevaluated argument forms;
 * compile+run the body) is delegated to compiler.sld's own
 * defmacro-expand-form via cvm_apply -- this file has no compiler of
 * its own to do that reentrant compile-and-run step in C, but the self-
 * hosted compiler that's necessarily ALREADY LOADED for expand-if-macro
 * to ever be called at all (it's compiler.sld's own compiled bytecode
 * that calls this) already has exactly the logic needed, in
 * compile-defmacro!'s own transformer -- defmacro-expand-form is that
 * same logic, exported so this builtin can reach it by name.
 *
 * define-syntax (syntax-rules) macros are NOT covered by this: expanding
 * one needs real pattern matching (sr-expand, compiler.sld), which this
 * builtin doesn't attempt to bridge to (unlike defmacro's plain
 * bind-and-run-the-body semantics, a syntax-rules use's own PATTERN needs
 * to be matched before there's even a param/arg correspondence to bind --
 * a real, separate, still-open gap, left for follow-up work). */
static Value bi_expand_if_macro(VM *vm, Value *args, int nargs) {
  if (nargs != 1) cvm_abort("expand-if-macro: expected 1 argument");
  Value form = args[0];
  if (form.tag != T_PAIR) return v_bool(0);
  Value head = form.as.pair->car;
  if (head.tag != T_SYM) return v_bool(0);

  int slot = cvm_global_intern(vm, head.as.str.chars, head.as.str.len);
  if (!vm->globals[slot].bound || vm->globals[slot].value.tag != T_MACRO) return v_bool(0);
  Pair *macro_form = vm->globals[slot].value.as.pair;

  const char *bridge_name = "defmacro-expand-form";
  int bridge_slot = cvm_global_intern(vm, bridge_name, (int)strlen(bridge_name));
  if (!vm->globals[bridge_slot].bound) {
    cvm_abort("expand-if-macro: %s is not loaded (is (creme compiler compiler) imported?)", bridge_name);
  }

  Value bridge_args[2];
  bridge_args[0] = v_pair(macro_form); /* re-tag as an ordinary pair for Scheme code */
  bridge_args[1] = form;
  Value expansion = cvm_apply(vm, vm->globals[bridge_slot].value, bridge_args, 2);
  return cvm_cons(vm, v_bool(1), expansion);
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
