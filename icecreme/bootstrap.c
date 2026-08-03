/* (creme bootstrap) — see bootstrap.h.
 *
 * The icecreme-side counterpart of src/creme/modules/creme/bootstrap.cr's
 * `load-chunk-bytes`/`import!`/(indirectly) `expand-if-macro` — same
 * names/contracts, so the self-hosted compiler (modules/creme/compiler/
 * {reader,bytecode,compiler}.sld) and anything built on top of it (e.g. a
 * REPL driver) run unmodified under either backend: compile source into
 * an ICE1-format bytevector, then load-and-run it against the SAME
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
 * compiler running under icecreme needs both names to at least exist. */
#include <limits.h>
#include <stdio.h>
#include <string.h>

#include <gc.h>

#include "bootstrap.h"
#include "builtin_families.h"
#include "embed.h"

/* Set once by main.c before running the compiler driver (icecreme/compiler-
 * run.scm) in compiler mode -- the path it decided needs compiling, exposed
 * to that running Scheme program via `icecreme-target-path`. Mirrors vm.c's own
 * g_current_vm / profiler.c's g_profiled_vm pattern (a fixed C API with no
 * room for an extra parameter, reaching process-wide state via one static
 * global) rather than a general command-line/argv-exposing mechanism the
 * driver doesn't otherwise need. */
static const char *g_target_path = NULL;

void creme_set_target_path(const char *path) {
  g_target_path = path;
}

/* args[0] must be a bytevector holding ICE1 bytes (typically the self-
 * hosted compiler's own compile-source-to-bytes output). Loads it against
 * THIS running program's global table (creme_load_from_bytes interns by
 * name into the same vm->globals every other chunk already shares) and
 * runs it reentrantly (creme_run_loaded_chunk), returning its value -- same
 * contract as the Crystal-side load-chunk-bytes builtin. */
static Value bi_load_chunk_bytes(VM *vm, Value *args, int nargs) {
  if (nargs != 1 || args[0].tag != T_BYTEVECTOR) {
    creme_abort("load-chunk-bytes: expected a bytevector");
  }
  Bytevector *bv = args[0].as.bv;
  /* Unlike the NULL/NULL this used to pass unconditionally, now read the
   * real required-families metadata out of these bytes and register
   * whichever native builtin families it names -- the crucial case being
   * icecreme's own "compiler mode" (main.c), where main() itself only ever
   * registers builtins based on precompiled compiler-run.ice's own
   * (near-empty) required-families list, never the REAL target script's:
   * that target isn't even read, let alone compiled, until well after
   * main()'s one-time startup registration already ran. The self-hosted
   * compiler (modules/creme/compiler/compiler.sld's required-native-
   * families-list) now tracks the real target's own transitively-required
   * native families and bakes them into exactly these bytes (see (creme
   * bytecode)'s chunk->bytes), so registering them here -- right before
   * actually running the loaded chunk -- closes that gap. See
   * creme_register_required_builtins's own doc comment (vm.h) for why
   * calling it twice (once in main.c, once here) is harmless. */
  char **families = NULL;
  int n_families = 0;
  Chunk *chunk = creme_load_from_bytes(vm, bv->bytes, (size_t)bv->len, &families, &n_families);
  creme_register_required_builtins(vm, families, n_families);
  return creme_run_loaded_chunk(vm, chunk);
}

/* (scheme eval)'s environment/null-environment/eval-2-arg support --
 * see icecreme/compiler-run.scm's own `environment`/`null-environment`/`eval`
 * for how these three primitives are actually used together (all real
 * import-set resolution -- only/except/prefix/rename, library-export
 * lookups -- stays in Scheme, reusing modules/creme/compiler/
 * compiler.sld's already-existing machinery; these just cross the VM
 * boundary a pure-Scheme primitive can't). */

/* (make-environment) -- a fresh, completely empty environment (a genuine
 * separate VM, creme_new_empty_vm, wrapped as a T_BOX so Scheme can hold
 * and pass it around) -- see that function's own doc comment (vm.c) for
 * why "empty" already correctly models null-environment, and how
 * `environment`'s own import-sets populate one afterward. */
static Value bi_make_environment(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return v_box(creme_new_empty_vm(), BOX_KIND_ENVIRONMENT);
}

static VM *as_environment_vm(Value v, const char *who) {
  return (VM *)creme_arg_box(&v, 1, 0, BOX_KIND_ENVIRONMENT, who);
}

/* (environment-copy-global! env-box external-name internal-name) --
 * copies internal-name's CURRENT value in the CALLING vm (whichever VM
 * this builtin itself was invoked from -- i.e. the environment the
 * `environment`/`eval` call making this request is itself running in)
 * into env-box's own separate global table, under external-name. This
 * is how `environment`'s own import-sets actually populate a fresh
 * environment (icecreme/compiler-run.scm) -- once Scheme-side import-set
 * resolution (only/except/prefix/rename, library-export-alist) has
 * decided WHICH names map to WHICH, this is the one primitive that
 * actually moves a value across the VM boundary. A quiet no-op (NOT an
 * abort) if internal-name isn't bound in the calling vm at all -- a
 * library's own export list can legitimately include a SYNTAX keyword
 * (`and`/`or`/`when`/...), which icecreme never binds as a global at all
 * (special forms are handled by the compiler directly, not vm->globals
 * entries) -- there is nothing to copy for those, but the keyword is
 * still genuinely usable in the new environment regardless (compiled
 * forms recognize special-form syntax unconditionally, independent of
 * which environment they're eval'd against), so this must not treat
 * that as an error. */
static Value bi_environment_copy_global(VM *vm, Value *args, int nargs) {
  if (nargs != 3 || args[1].tag != T_STR || args[2].tag != T_STR) {
    creme_abort("environment-copy-global!: expected (env-box external-name internal-name)");
  }
  VM *target = as_environment_vm(args[0], "environment-copy-global!");
  int src_slot = creme_global_intern(vm, args[2].as.chars, args[2].aux);
  if (!vm->globals[src_slot].bound) return v_nil();
  Value value = vm->globals[src_slot].value;
  int dst_slot = creme_global_intern(target, args[1].as.chars, args[1].aux);
  target->globals[dst_slot].value = value;
  target->globals[dst_slot].bound = 1;
  return v_nil();
}

/* (environment-bound? env-box name-string) -- #t iff name-string is
 * currently bound as a global in env-box's own separate table. Added so
 * `eval` can tell, for a given target environment, which of the fusable
 * primitive names (+, cons, vector-ref, ...) `environment`'s own only/
 * except filtering actually left OUT -- see icecreme/compiler-run.scm's
 * `eval` and compiler.sld's `mark-redefined!`/`unmark-redefined!`: a
 * fused opcode (e.g. Add for `(+ 1 2)` in call position) never consults
 * any environment at all, so without this check `except`-excluding `+`
 * could never stop a CALL to it, only a bare reference. */
static Value bi_environment_bound(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[1].tag != T_STR) {
    creme_abort("environment-bound?: expected (env-box name-string)");
  }
  VM *target = as_environment_vm(args[0], "environment-bound?");
  int slot = creme_global_intern(target, args[1].as.chars, args[1].aux);
  return v_bool(target->globals[slot].bound);
}

/* (current-environment) -- wraps THIS running VM directly (not a copy)
 * as a T_BOX(BOX_KIND_ENVIRONMENT) -- backs both scheme-report-
 * environment (mirroring native's own deliberate non-isolation there,
 * see r5rs.cr's own comment) and interaction-environment (native's own
 * literally IS @global). Evaluating against the result behaves exactly
 * like eval's own 1-arg form, since it's the SAME vm. */
static Value bi_current_environment(VM *vm, Value *args, int nargs) {
  (void)args;
  (void)nargs;
  return v_box(vm, BOX_KIND_ENVIRONMENT);
}

/* (load-chunk-bytes-into env-box bytes) -- same contract as
 * load-chunk-bytes (bi_load_chunk_bytes, right below) but loads+runs
 * the given ICE1 bytes against env-box's own separate VM instead of the
 * currently-running one. This is what makes `eval`'s 2-arg form
 * actually evaluate against the GIVEN environment rather than always
 * the one real global table (icecreme/README.md's own previous "eval ignores
 * its own environment argument" limitation) -- compiling `form` still
 * happens the ordinary way (against the CALLING environment's own
 * compiler state -- macros/syntax are still resolved lexically, only
 * global VARIABLE reads/writes inside the compiled form resolve against
 * env-box's table once loaded here), then the resulting bytecode is
 * loaded+run against env-box's own table, so any GetGlobal/DefGlobal it
 * contains resolves there, not against the calling environment. */
static Value bi_load_chunk_bytes_into(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 2 || args[1].tag != T_BYTEVECTOR) {
    creme_abort("load-chunk-bytes-into: expected (env-box bytevector)");
  }
  VM *target = as_environment_vm(args[0], "load-chunk-bytes-into");
  Bytevector *bv = args[1].as.bv;
  char **families = NULL;
  int n_families = 0;
  Chunk *chunk = creme_load_from_bytes(target, bv->bytes, (size_t)bv->len, &families, &n_families);
  creme_register_required_builtins(target, families, n_families);
  return creme_run_loaded_chunk(target, chunk);
}

/* icecreme's global table is already unconditionally flat -- no per-import
 * filtering/prefixing/renaming applies at icecreme's own runtime level
 * regardless of backend, so "importing" a library whose bindings are
 * already in vm->globals has nothing to do at THIS layer. But only/
 * except/prefix/rename filters DO introduce genuinely new alias names
 * (e.g. a prefix import-set's `rx:regexp-matches?`), which icecreme has no
 * compiler of its own to synthesize -- so, same pattern as expand-if-
 * macro bridging to compiler.sld's defmacro-expand-form/define-syntax-
 * expand-form, this bridges out to that same self-hosted compiler's
 * import!-apply-aliases! (compiler.sld), built on its existing alias-
 * defines-for-specs, now genuinely EXECUTING each computed `(define new
 * old)` form via `eval` instead of just returning it as data for a
 * compile pass to emit bytecode from.
 *
 * This bridge is safe specifically because it's ONLY ever reached for a
 * bare runtime call to `import!` as an ordinary procedure (e.g. directly
 * in a test) -- compile-import! (compiler.sld), which handles the actual
 * `(import ...)` special form, never emits a call to import!-apply-
 * aliases! itself, so there's no re-entrant risk of the alias bridge
 * firing before the target library's exports exist. An EARLIER attempt
 * at this (see git history) bridged import! itself unconditionally and
 * broke a previously-passing prefix-import case, because compile-
 * import!'s own emitted runtime sequence used to call import! BEFORE
 * ensure-libraries-loaded! -- fixed by reordering that sequence (see
 * compile-import!'s own comment) so a pure-Scheme library's real exports
 * are already loaded as globals by the time THIS bridge (triggered from
 * that same emitted import! call) would ever run.
 *
 * If import!-apply-aliases! isn't loaded (i.e. (creme compiler compiler)
 * itself isn't part of this program -- never true for icecreme's own
 * compiler-mode driver, which always bundles the whole toolchain, but
 * cheap to guard for anyway), this quietly falls back to the original
 * no-op rather than aborting. */
static Value bi_import_bang(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 1, "import!");
  const char *bridge_name = "import!-apply-aliases!";
  int bridge_slot = creme_global_intern(vm, bridge_name, (int)strlen(bridge_name));
  if (!vm->globals[bridge_slot].bound) return v_nil();
  creme_apply(vm, vm->globals[bridge_slot].value, args, 1);
  return v_nil();
}

static int sym_is(Value v, const char *s) {
  size_t len = strlen(s);
  return v.tag == T_SYM && (size_t)v.aux == len && memcmp(v.as.chars, s, len) == 0;
}

/* icecreme has no per-library grouping of its own flat global table at all --
 * every builtin from every conceptual "library" (regex.c, sql.c, ...) is
 * just registered into the same vm->globals via creme_register_builtin, with
 * no record of which C file/module it came from. This is a small, hand-
 * maintained table of the (external . internal) export pairs (always the
 * same name on both sides here -- icecreme's own native registration never
 * renames) for libraries this project's own spec/creme test suite actually
 * exercises via an only/except/prefix/rename import-set against a NATIVE
 * library (today: just (creme regex), for bootstrap_spec.scm's own
 * "import! applies ... filters" case) -- deliberately NOT a general
 * mechanism mirroring every native library's real export surface (native
 * Crystal's own SchemeLibrary#exports, exposed the same way via (creme
 * introspection)'s library-exports, already covers that properly; icecreme has
 * no equivalent runtime bookkeeping to draw the same table from
 * automatically). Extend this if a future spec needs another native
 * library aliased under icecreme specifically. `name` is the quoted library
 * name (e.g. '(creme regex)) -- returns #f for anything not in this table,
 * same contract as native's own library-exports when the library isn't
 * registered. */
static Value bi_library_exports(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 1, "library-exports");
  Value name = args[0];
  if (name.tag != T_PAIR) return v_bool(0);
  Value first = name.as.pair->car;
  Value rest = name.as.pair->cdr;
  if (!sym_is(first, "creme") || rest.tag != T_PAIR) return v_bool(0);
  Value second = rest.as.pair->car;
  if (rest.as.pair->cdr.tag != T_NIL) return v_bool(0);

  static const char *regex_exports[] = {"regexp", "regexp-matches?"};
  const char **exports = NULL;
  int n_exports = 0;
  if (sym_is(second, "regex")) {
    exports = regex_exports;
    n_exports = (int)(sizeof(regex_exports) / sizeof(regex_exports[0]));
  }
  if (!exports) return v_bool(0);

  Value result = v_nil();
  for (int i = n_exports - 1; i >= 0; i--) {
    Value sym = creme_sym_lit(exports[i]);
    result = creme_cons(vm, creme_cons(vm, sym, sym), result);
  }
  return result;
}

/* `args[0]` is the whole call form under consideration (e.g. `(sxql-
 * select! conn fields ...)`), same contract as the real interpreter's own
 * expand-if-macro (see modules/creme/compiler/compiler.sld's target-env-
 * macro-expand). Returns `(cons #t expansion)` if `form`'s head resolves,
 * in vm->globals, to a defmacro OR define-syntax macro EXPORTED from a
 * library compiled straight to bytecode (Crystal-native, or this
 * project's own self-hosted compiler ahead of time) -- Op::HelperForm's
 * kind==3/kind==4 cases (vm.c) both bind exactly this: a T_MACRO value
 * wrapping the macro's own raw top-level form, e.g. sxql-select! from
 * (creme sxql), the flagship case this exists for. The actual expansion
 * is delegated out to compiler.sld's own defmacro-expand-form/define-
 * syntax-expand-form via creme_apply, picked by the wrapped form's own
 * head symbol -- this file has no compiler (or syntax-rules pattern
 * matcher) of its own to do that reentrant work in C, but the self-
 * hosted compiler that's necessarily ALREADY LOADED for expand-if-macro
 * to ever be called at all (it's compiler.sld's own compiled bytecode
 * that calls this) already has exactly the logic needed in each of
 * compile-defmacro!/compile-define-syntax!'s own transformers -- those
 * two exported procedures are that same logic, exported so this builtin
 * can reach either by name. */
static Value bi_expand_if_macro(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 1, "expand-if-macro");
  Value form = args[0];
  if (form.tag != T_PAIR) return v_bool(0);
  Value head = form.as.pair->car;
  if (head.tag != T_SYM) return v_bool(0);

  int slot = creme_global_intern(vm, head.as.chars, head.aux);
  if (!vm->globals[slot].bound || vm->globals[slot].value.tag != T_MACRO) return v_bool(0);
  Pair *macro_form = vm->globals[slot].value.as.pair;

  Value macro_head = macro_form->car;
  int is_define_syntax = macro_head.tag == T_SYM && macro_head.aux == 13 &&
                         memcmp(macro_head.as.chars, "define-syntax", 13) == 0;
  const char *bridge_name = is_define_syntax ? "define-syntax-expand-form" : "defmacro-expand-form";
  int bridge_slot = creme_global_intern(vm, bridge_name, (int)strlen(bridge_name));
  if (!vm->globals[bridge_slot].bound) {
    creme_abort("expand-if-macro: %s is not loaded (is (creme compiler compiler) imported?)", bridge_name);
  }

  Value bridge_args[2];
  bridge_args[0] = v_pair(macro_form); /* re-tag as an ordinary pair for Scheme code */
  bridge_args[1] = form;
  Value expansion = creme_apply(vm, vm->globals[bridge_slot].value, bridge_args, 2);
  return creme_cons(vm, v_bool(1), expansion);
}

/* Reads `path`'s entire contents into one T_STR -- icecreme's only other file-
 * reading capability (read-line) is hardwired to stdin, so compiler mode
 * (icecreme/compiler-run.scm) needs this to read the target script (and any
 * file it (include ...)s) at all. */
static Value bi_read_whole_file(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 1, "read-whole-file");
  const char *path = creme_arg_cstr(args, nargs, 0, "read-whole-file");

  FILE *f = fopen(path, "rb");
  if (!f) creme_abort("read-whole-file: cannot open %s", path);
  if (fseek(f, 0, SEEK_END) != 0) creme_abort("read-whole-file: cannot seek %s", path);
  long size = ftell(f);
  if (size < 0) creme_abort("read-whole-file: cannot determine size of %s", path);
  /* Scheme strings carry an int length (v_str's aux); a file past INT_MAX would
   * be truncated to a negative/wrong length that then flows into byte math. */
  if (size > INT_MAX) creme_abort("read-whole-file: %s is too large (%ld bytes)", path, size);
  rewind(f);

  char *buf = GC_MALLOC((size_t)(size ? size : 1));
  size_t got = fread(buf, 1, (size_t)size, f);
  fclose(f);
  if ((long)got != size) creme_abort("read-whole-file: truncated read of %s", path);

  return v_str(buf, (int)size);
}

/* (creme file)'s file-write/delete-file -- needed by spec/creme/
 * compiler_libraries_spec.scm's "imports a library file written by an
 * earlier form in the same program" case, which writes then deletes a
 * throwaway generated .sld file. Whole-file write (create/truncate),
 * matching src/creme/modules/creme/file.cr's own file-write contract. */
static Value bi_file_write(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 2, "file-write");
  const char *path = creme_arg_cstr(args, nargs, 0, "file-write");
  int content_len;
  const char *content = creme_arg_bytes(args, nargs, 1, "file-write", &content_len);

  FILE *f = fopen(path, "wb");
  if (!f) creme_abort("file-write: cannot open %s for writing", path);
  size_t wrote = fwrite(content, 1, (size_t)content_len, f);
  fclose(f);
  if ((int)wrote != content_len) creme_abort("file-write: truncated write of %s", path);
  return v_nil();
}

static Value bi_delete_file(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 1, "delete-file");
  const char *path = creme_arg_cstr(args, nargs, 0, "delete-file");
  if (remove(path) != 0) creme_abort("delete-file: cannot remove %s", path);
  return v_nil();
}

/* Returns whatever path main.c decided needs compiling (see
 * creme_set_target_path) -- the compiler driver's only way to learn what to
 * compile, since icecreme has no general command-line/argv exposure. */
static Value bi_cvm_target_path(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  if (!g_target_path) creme_abort("icecreme-target-path: no target path set (not running in compiler mode)");
  return v_str(g_target_path, (int)strlen(g_target_path));
}

void creme_register_bootstrap_builtins(VM *vm) {
  creme_register_builtin(vm, "load-chunk-bytes", bi_load_chunk_bytes);
  creme_register_builtin(vm, "make-environment", bi_make_environment);
  creme_register_builtin(vm, "environment-copy-global!", bi_environment_copy_global);
  creme_register_builtin(vm, "environment-bound?", bi_environment_bound);
  creme_register_builtin(vm, "load-chunk-bytes-into", bi_load_chunk_bytes_into);
  creme_register_builtin(vm, "current-environment", bi_current_environment);
  creme_register_builtin(vm, "import!", bi_import_bang);
  creme_register_builtin(vm, "library-exports", bi_library_exports);
  creme_register_builtin(vm, "expand-if-macro", bi_expand_if_macro);
  creme_register_builtin(vm, "read-whole-file", bi_read_whole_file);
  creme_register_builtin(vm, "icecreme-target-path", bi_cvm_target_path);
  /* (creme file)'s own file-read has an identical (path) -> whole-file-
   * as-a-string contract to this file's own read-whole-file -- same C
   * function registered under the extra name, no new logic needed.
   * Needed by modules/creme/compiler/spec-helper.sld's own
   * library-body-source (used by spec/creme/compiler_self_host_spec.scm). */
  creme_register_builtin(vm, "file-read", bi_read_whole_file);
  creme_register_builtin(vm, "file-write", bi_file_write);
  creme_register_builtin(vm, "delete-file", bi_delete_file);
}
