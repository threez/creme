/* cvm — standalone prototype VM entry point. Loads a "SCB1" file (produced
 * by `creme --emit-cvm <file.scm> <out.cvmc>`, see cvm_emitter.cr) — a
 * whole script (plus its transitively-imported pure-Scheme library bodies)
 * compiled into ONE Chunk — and runs it. See cvm/README.md for full scope.
 *
 * Running one combined chunk is also what makes a compiled HTTP server
 * (e.g. competition/scheme/demo-todo/app.scm) run correctly as a genuinely
 * long-running process, with no special-casing needed here: mux.c's
 * mux-listen! runs its own accept loop right there on the calling thread
 * (see that file's own comment) and blocks until it stops (mux-close!, or
 * the process is killed) — so this run simply doesn't return until the
 * server does. Whatever top-level forms come after it in the source (in
 * app.scm's case, (read-line)/mux-close!/sql-close, originally written for
 * the interactive single-process interpreter) still run afterward as
 * ordinary best-effort cleanup once the server actually stops, since
 * they're all part of the same sequential chunk body. */
#include <gc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "actor.h"
#include "bigdecimal.h"
#include "bootstrap.h"
#include "creme_ffi.h"
#include "csv.h"
#include "digest.h"
#include "secure_random.h"
#include "cipher.h"
#include "pkey.h"
#include "x509.h"
#include "hashtable.h"
#include "http.h"
#include "json.h"
#include "yaml.h"
#include "mux.h"
#include "profiler.h"
#include "process.h"
#include "regex.h"
#include "sql.h"
#include "strings.h"
#include "term.h"
#include "treelist.h"
#include "vm.h"

/* Mean instructions between VM-level samples — matches the interval
 * `creme --profile table` itself uses for `(creme prof-vm)` (see
 * src/main.cr's handle_profile). Not currently configurable from the CLI;
 * add a `--profile=<n>` form here if a bench ever needs a different rate. */
#define CVM_PROFILE_DEFAULT_VM_INTERVAL 200

/* Repo-root-relative, matching this project's existing convention for
 * locating cvm itself (e.g. src/main.cr's run_via_cvm hardcodes
 * "cvm/cvm") -- assumes cvm is invoked from the repo root, same
 * assumption every other cvm/creme cross-reference in this project makes. */
#define CVM_COMPILER_DRIVER_PATH "cvm/compiler-run.cvmc"

/* A plain .scm file can never coincidentally start with the 4 bytes
 * "SCB1" (Scheme source always starts with whitespace, `(`, or `;`), so
 * this is a safe, content-based way to tell "already-compiled SCB1
 * binary" apart from "raw Scheme source needing compiler mode" -- no
 * `--compile` flag or file-extension convention needed. A file that
 * can't even be opened returns 0 here too, letting the real error
 * surface later from whichever path actually tries to open it. */
static int is_scb1_file(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  char magic[4];
  size_t n = fread(magic, 1, 4, f);
  fclose(f);
  return n == 4 && memcmp(magic, "SCB1", 4) == 0;
}

/* Maps an SCB1 "required families" name (the third element of a
 * ["creme","builtin",X] library name, per cvm_emitter.cr's `required_families`
 * computation) to the register_fn cvm.c's builtins.c split it into --
 * see builtins.c's/vm.h's per-family cvm_register_*_builtins split and the
 * 14 pre-existing per-file ones. "base" and "write" are deliberately absent
 * here (see register_required_builtins below) even though the compiler side
 * always lists them too (scheme/base.cr's AUTO_IMPORTED_LIBRARIES) -- they're
 * registered unconditionally rather than through this table. */
static const struct {
  const char *name;
  void (*register_fn)(VM *);
} BUILTIN_FAMILIES[] = {
    {"cxr", cvm_register_cxr_builtins},
    {"complex", cvm_register_complex_builtins},
    {"char", cvm_register_char_builtins},
    {"process-context", cvm_register_process_context_builtins},
    {"lazy", cvm_register_lazy_builtins},
    {"math", cvm_register_math_builtins},
    {"introspection", cvm_register_introspection_builtins},
    {"file", cvm_register_file_builtins},
    {"env", cvm_register_env_builtins},
    {"hash-table", cvm_register_hashtable_builtins},
    {"sql", cvm_register_sql_builtins},
    {"mux", cvm_register_mux_builtins},
    {"string", cvm_register_string_builtins},
    {"bootstrap", cvm_register_bootstrap_builtins},
    {"regex", cvm_register_regex_builtins},
    {"process", cvm_register_process_builtins},
    {"csv", cvm_register_csv_builtins},
    {"treelist", cvm_register_treelist_builtins},
    {"actor", cvm_register_actor_builtins},
    {"digest", cvm_register_digest_builtins},
    {"secure-random", cvm_register_secure_random_builtins},
    {"cipher", cvm_register_cipher_builtins},
    {"pkey", cvm_register_pkey_builtins},
    {"x509", cvm_register_x509_builtins},
    {"json", cvm_register_json_builtins},
    {"yaml", cvm_register_yaml_builtins},
    {"bigdecimal", cvm_register_bigdecimal_builtins},
    {"http", cvm_register_http_builtins},
    {"term", cvm_register_term_builtins},
    {"ffi", cvm_register_ffi_builtins},
};
#define N_BUILTIN_FAMILIES (int)(sizeof(BUILTIN_FAMILIES) / sizeof(BUILTIN_FAMILIES[0]))

/* Always calls the two "always on" families (matching scheme/base.cr's
 * AUTO_IMPORTED_LIBRARIES, which every compiled script implicitly imports
 * regardless of what it actually uses), then, for every OTHER name in the
 * compiled file's required-families list, looks it up in BUILTIN_FAMILIES
 * and registers it. A name that isn't "base"/"write" and isn't in
 * BUILTIN_FAMILIES is silently skipped, not an error: cvm implements only a
 * documented subset of the Crystal interpreter's native libraries (see
 * README.md), so a compiled program can legitimately require a family (e.g.
 * "inexact", "random", "time") that has no cvm-side register function at
 * all. If the program actually calls something from that family at run
 * time, it still fails loudly there with the normal "unbound variable"
 * abort -- this loop just must not treat "cvm doesn't implement X" as fatal
 * up front.
 *
 * Non-static (declared in vm.h): also called by bootstrap.c's
 * bi_load_chunk_bytes, for exactly the case this task exists to fix --
 * cvm's own "compiler mode" (see this file's header comment on
 * CVM_COMPILER_DRIVER_PATH) registers builtins ONCE, here, based on the
 * PRECOMPILED compiler-run.cvmc's own required-families metadata --
 * before compiler-run.scm has even read, let alone compiled, the REAL
 * target script main() actually pointed cvm at. compiler-run.cvmc's own
 * imports never include any of BUILTIN_FAMILIES (it needs none of them
 * itself), so relying on this call ALONE would leave every other family
 * permanently unregistered for compiler-mode runs regardless of what the
 * real target actually imports. bi_load_chunk_bytes closes that gap: the
 * self-hosted compiler now tracks the real target's own transitively-
 * required native families (modules/creme/compiler/compiler.sld's
 * required-native-families-list) and bakes them into the SCB1 bytes it
 * hands to load-chunk-bytes, which calls this same function again with
 * THAT real list right before running the loaded chunk. Calling this
 * twice (once here with compiler-run.cvmc's own near-empty list, once
 * from bootstrap.c with the real target's list) is safe -- see
 * vm->registered_family_mask/base_write_registered's own doc comment
 * (vm.h) for why this function is idempotent PER FAMILY PER VM (skips a
 * family, including the always-on base/write pair, it already registered
 * on this exact vm) rather than unconditionally re-running every
 * register_fn on every call: bi_load_chunk_bytes now calls this on EVERY
 * loaded chunk (not just once at process startup) -- every nested self-
 * hosted-compiler library load, every `eval` call -- and re-registering
 * an already-registered name would silently stomp a real Scheme-level
 * redefinition of it (e.g. prim_call_spec.scm's own "deopts + to a
 * runtime redefinition" cases) back to the original native closure.
 *
 * Two of BUILTIN_FAMILIES' own entries get an extra, implied registration
 * beyond their own table lookup -- found empirically while wiring up
 * real required-families tracking for cvm's own self-hosted-compiler
 * path, but affecting the ordinary native --emit-cvm gate too,
 * independent of that: cvm's own C-level register_fn split (builtins.c/
 * strings.c's own file/function boundaries) doesn't line up 1:1 with
 * Crystal's native family grouping (src/scheme/modules/scheme/*.cr's own
 * register_library calls). A program using ONLY (scheme char)
 * legitimately gets required_families = [..., "char"] (Crystal's char.cr
 * registers string-downcase/string-upcase/string-ci-comparisons/string-
 * foldcase under the SAME ["creme","builtin","char"] library as the
 * char-only predicates), but cvm itself splits that same functionality
 * into TWO C functions -- builtins.c's cvm_register_char_builtins (char-
 * only) and strings.c's cvm_register_string_builtins (string-case
 * functions, ALSO covering (creme string)'s own unrelated string-trim/
 * split/join/etc, hence being its own separate family here too) -- so
 * requesting only "char" left string-downcase permanently unbound.
 * Symmetrically, (scheme process-context)'s Crystal registration
 * (process_context.cr) legitimately includes get-environment-variable/
 * set-environment-variable! (derived from the same underlying EnvVars
 * methods (creme env) also exposes under its own separate family), but
 * cvm's own cvm_register_process_context_builtins (builtins.c) only ever
 * registered `exit` -- the env accessors live solely in
 * cvm_register_env_builtins. Requesting "string"/"env" directly still
 * works unchanged (via the ordinary BUILTIN_FAMILIES lookup); these two
 * extra bits (beyond one per BUILTIN_FAMILIES entry) just add the
 * implied registration so "char"/"process-context" alone are enough
 * too.
 *
 * A third case of the same mismatch: native Crystal's (creme file)/
 * (scheme file) (src/scheme/modules/creme/file.cr) groups file-write/
 * delete-file under family "file" alongside file-exists?/open-input-
 * file/etc, but cvm's own file-write/delete-file (bi_file_write/
 * bi_delete_file) are implemented in bootstrap.c and registered only by
 * cvm_register_bootstrap_builtins, gated on family "bootstrap" --
 * requesting only "file" left them permanently unbound. Requesting
 * "bootstrap" directly still works unchanged (via the ordinary
 * BUILTIN_FAMILIES lookup); this third extra bit adds the implied
 * registration so "file" alone is enough too. (cvm_register_bootstrap_
 * builtins also registers several compiler/REPL-only builtins --
 * import!/load-chunk-bytes/etc -- that a plain "file"-only program will
 * simply never call; harmless extra bindings, not a behavior change.) */
#define CVM_EXTRA_BIT_STRING_VIA_CHAR ((uint64_t)1 << N_BUILTIN_FAMILIES)
#define CVM_EXTRA_BIT_ENV_VIA_PROCESS_CONTEXT ((uint64_t)1 << (N_BUILTIN_FAMILIES + 1))
#define CVM_EXTRA_BIT_BOOTSTRAP_VIA_FILE ((uint64_t)1 << (N_BUILTIN_FAMILIES + 2))

void cvm_register_required_builtins(VM *vm, char **families, int n_families) {
  if (!vm->base_write_registered) {
    cvm_register_base_builtins(vm);
    cvm_register_write_builtins(vm);
    vm->base_write_registered = 1;
  }

  for (int i = 0; i < n_families; i++) {
    const char *name = families[i];
    if (strcmp(name, "base") == 0 || strcmp(name, "write") == 0) continue;

    for (int j = 0; j < N_BUILTIN_FAMILIES; j++) {
      if (strcmp(name, BUILTIN_FAMILIES[j].name) == 0) {
        uint64_t bit = (uint64_t)1 << j;
        if (!(vm->registered_family_mask & bit)) {
          BUILTIN_FAMILIES[j].register_fn(vm);
          vm->registered_family_mask |= bit;
        }
        break;
      }
    }

    if (strcmp(name, "char") == 0 && !(vm->registered_family_mask & CVM_EXTRA_BIT_STRING_VIA_CHAR)) {
      cvm_register_string_builtins(vm);
      vm->registered_family_mask |= CVM_EXTRA_BIT_STRING_VIA_CHAR;
    }
    if (strcmp(name, "process-context") == 0 && !(vm->registered_family_mask & CVM_EXTRA_BIT_ENV_VIA_PROCESS_CONTEXT)) {
      cvm_register_env_builtins(vm);
      vm->registered_family_mask |= CVM_EXTRA_BIT_ENV_VIA_PROCESS_CONTEXT;
    }
    if (strcmp(name, "file") == 0 && !(vm->registered_family_mask & CVM_EXTRA_BIT_BOOTSTRAP_VIA_FILE)) {
      cvm_register_bootstrap_builtins(vm);
      vm->registered_family_mask |= CVM_EXTRA_BIT_BOOTSTRAP_VIA_FILE;
    }
  }
}

/* Redirects GMP's own allocator (used by T_RATIONAL's mpq_t, value.h) to
 * Boehm GC -- without this, an mpq_t's internal limb buffers would be
 * malloc'd/realloc'd/freed entirely outside the collector's view: not
 * scanned (harmless, they hold no pointers) but never reclaimed either
 * once their owning Rational wrapper becomes unreachable, a slow leak for
 * any long-running program doing rational arithmetic. `free_func` is
 * deliberately a no-op: Boehm GC reclaims unreachable GC_MALLOC'd memory
 * on its own, so there's nothing for an explicit free to do (and GMP's own
 * free calls happen at points -- e.g. mpq_clear -- where the memory may
 * still be referenced by a Value the collector can see, so actually
 * freeing it here would be unsafe). Must run before ANY mpq_init anywhere
 * in the process (GMP has no per-instance allocator, only this one
 * process-wide setting), so this is the very first thing after GC_INIT(). */
static void *gmp_gc_alloc(size_t size) { return GC_MALLOC(size); }
static void *gmp_gc_realloc(void *ptr, size_t old_size, size_t new_size) {
  (void)old_size;
  return GC_REALLOC(ptr, new_size);
}
static void gmp_gc_free(void *ptr, size_t size) {
  (void)ptr;
  (void)size;
}

/* Reads an environment variable as a positive int, for cvm_alloc_vm's
 * own stack_cap/frames_cap resource-limit overrides below. Unset,
 * empty, non-numeric, or non-positive all fall through to 0 (cvm_alloc_
 * vm's own "use the default" sentinel) -- this is a best-effort CLI
 * convenience, not a validated embedding API, so silently ignoring a
 * malformed value rather than erroring out of the whole run is the
 * right call here. */
static int cvm_getenv_int(const char *name) {
  const char *s = getenv(name);
  if (!s || !*s) return 0;
  char *end;
  long v = strtol(s, &end, 10);
  if (*end != '\0' || v <= 0 || v > INT32_MAX) return 0;
  return (int)v;
}

int main(int argc, char **argv) {
  int profile = 0;
  const char *path = NULL;
  /* The target path and everything after it (contiguous in argv, since
   * --profile can only appear before it) becomes the running script's
   * own (command-line) tail -- see cvm_set_command_line_args below --
   * mirroring native's own (command-line) contract exactly: [PROGRAM_
   * NAME] + ARGV, where Crystal's ARGV still includes the script's own
   * path as its first element (process_context.cr/`command_line` never
   * strips it). */
  int script_argc = 0;
  char **script_argv = NULL;
  for (int i = 1; i < argc; i++) {
    if (path) {
      script_argc++;
    } else if (strcmp(argv[i], "--profile") == 0) {
      profile = 1;
    } else {
      path = argv[i];
      script_argv = &argv[i];
      script_argc = 1;
    }
  }
  if (!path) {
    fprintf(stderr, "usage: %s [--profile] <file.cvmc> [script-args...]\n", argv[0]);
    return 1;
  }
  cvm_set_command_line_args(argv[0], script_argc, script_argv);

  GC_INIT();
  /* Boehm's own env-var handling inside GC_INIT() already honors an
   * explicit GC_INITIAL_HEAP_SIZE, growing the heap to that size before
   * we ever get here -- so only step in with our own default when the
   * caller didn't set one. Benchmarked (doc/optimization-cvm.md's own GC
   * env-var section) across the same 9 competition/bench.scm workloads,
   * median of 11 runs each: unset (libgc's own default) 0.201s total vs.
   * 256M 0.163s (-18.7%), with 1G measuring the same as 256M (no further
   * win). GC_expand_hp only grows libgc's own address-space reservation,
   * not resident memory committed up front, so this costs nothing for
   * the long-running-server case (mux-listen!'s app.scm, see this file's
   * own header comment) either -- pages are still faulted in lazily as
   * the heap is actually used. */
  if (!getenv("GC_INITIAL_HEAP_SIZE")) {
    size_t default_heap = 256 * 1024 * 1024;
    size_t heap_size = GC_get_heap_size();
    if (heap_size < default_heap) GC_expand_hp(default_heap - heap_size);
  }
  GC_set_oom_fn(cvm_gc_oom_handler); /* see vm.h's own doc comment */
  mp_set_memory_functions(gmp_gc_alloc, gmp_gc_realloc, gmp_gc_free);
  /* CVM_STACK_CAP/CVM_FRAMES_CAP: optional resource-limit overrides for
   * this run, read here rather than baked into a recompile -- the
   * concrete, exercisable-today form of cvm_alloc_vm's own embedder-
   * configurable resource limits (see vm.h's doc comment there) until a
   * real embedding API (a linked-in caller passing its own values
   * directly) exists. Unset, empty, or non-positive falls through to
   * cvm_alloc_vm's own CVM_DEFAULT_STACK_CAP/CVM_DEFAULT_FRAMES_CAP
   * default, same as passing 0 directly. */
  VM *vm = cvm_alloc_vm(cvm_getenv_int("CVM_STACK_CAP"), cvm_getenv_int("CVM_FRAMES_CAP"));
  if (!vm) {
    fprintf(stderr, "cvm: out of memory allocating VM state\n");
    return 1;
  }
  cvm_set_current_vm(vm); /* lets cvm_abort reach this VM's guard-handler stack */

  /* Compiler mode: `path` isn't a compiled SCB1 binary at all -- it's the
   * plain Scheme source cvm should compile-and-run, entirely via the
   * bundled self-hosted-compiler driver (see cvm/compiler-run.scm's own
   * header comment), never touching a live Crystal `creme` process. The
   * driver learns the real target path via cvm-target-path, reads and
   * compiles it (expanding any `include`s itself), and runs the result. */
  const char *load_path = path;
  if (!is_scb1_file(path)) {
    cvm_set_target_path(path);
    load_path = CVM_COMPILER_DRIVER_PATH;
  }

  /* Peek the required-families metadata BEFORE the real load: builtins must
   * be registered before cvm_load's resolve_globals pass runs (it needs
   * cvm_global_intern to see already-registered globals -- see
   * resolve_globals's own doc comment in loader.c), but the family list
   * itself only becomes known by parsing the file. cvm_load re-reads (and,
   * since NULL/NULL is passed below, discards) this same section again
   * right after -- see cvm_peek_required_families's doc comment in vm.h/
   * loader.c for why this is a second, separate open rather than sharing a
   * Reader across both calls. */
  char **families = NULL;
  int n_families = 0;
  cvm_peek_required_families(load_path, &families, &n_families);
  cvm_register_required_builtins(vm, families, n_families);

  vm->source_file = load_path;
  Chunk *chunk = cvm_load(load_path, vm, NULL, NULL);

  if (profile) {
    vm->profiler.enabled = 1;
    vm->profiler.vm_interval = CVM_PROFILE_DEFAULT_VM_INTERVAL;
    vm->profiler.vm_countdown = 1 + rand() % (2 * CVM_PROFILE_DEFAULT_VM_INTERVAL);
    /* Shared with every child VM cvm_new_child_vm ever creates from this
     * one (a spawned actor, or one of (creme mux)'s worker-pool/inline
     * dispatch VMs) -- see SharedVmSamples's own doc comment (vm.h) for
     * why a profiled program's "hot Scheme functions" report needs this
     * to reflect work done on threads other than this exact one. */
    vm->profiler.shared_vm_samples = GC_MALLOC(sizeof(SharedVmSamples));
    pthread_mutex_init(&vm->profiler.shared_vm_samples->mu, NULL);
    cvm_profiler_start_native(vm);
  }

  cvm_run_chunk(vm, chunk);

  if (profile) {
    cvm_profiler_stop_native(vm);
    cvm_profiler_report(vm);
  }

  return 0;
}
