/* cvm — standalone prototype VM entry point. Loads a "SCB1" file (produced
 * by `creme --emit-cvm <file.scm> <out.cvmc>`, see cvm_emitter.cr) — a
 * whole script (plus its transitively-imported pure-Scheme library bodies)
 * compiled into ONE Chunk — and runs it. See cvm/README.md for full scope.
 *
 * Running one combined chunk is also what makes a compiled HTTP server
 * (e.g. competition/scheme/demo-todo/app.scm) run correctly as a genuinely
 * long-running process, with no special-casing needed here: mux.c's
 * mux-listen! calls facil.io's fio_start() itself (see that file's own
 * comment) and blocks right there until the reactor stops (SIGINT/
 * SIGTERM) — so this run simply doesn't return until the server does.
 * Whatever top-level forms come after it in the source (in app.scm's case,
 * (read-line)/mux-close!/sql-close, originally written for the interactive
 * single-process interpreter) still run afterward as ordinary best-effort
 * cleanup once the server actually stops, since they're all part of the
 * same sequential chunk body. */
#include <gc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bootstrap.h"
#include "hashtable.h"
#include "mux.h"
#include "profiler.h"
#include "process.h"
#include "regex.h"
#include "sql.h"
#include "strings.h"
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

int main(int argc, char **argv) {
  int profile = 0;
  const char *path = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--profile") == 0) {
      profile = 1;
    } else if (!path) {
      path = argv[i];
    } else {
      path = NULL;
      break;
    }
  }
  if (!path) {
    fprintf(stderr, "usage: %s [--profile] <file.cvmc>\n", argv[0]);
    return 1;
  }

  GC_INIT();
  mp_set_memory_functions(gmp_gc_alloc, gmp_gc_realloc, gmp_gc_free);
  /* GC_MALLOC, not calloc -- so the collector's mark phase can find and
   * scan `stack`/`frames` itself (see vm.h's own VM struct doc comment for
   * why a plain malloc'd VM would make everything reachable only through a
   * register look unreachable to Boehm). GC_MALLOC zero-inits, matching
   * calloc's own guarantee. */
  VM *vm = GC_MALLOC(sizeof(VM));
  if (!vm) {
    fprintf(stderr, "cvm: out of memory allocating VM state\n");
    return 1;
  }
  cvm_set_current_vm(vm); /* lets cvm_abort reach this VM's guard-handler stack */
  cvm_register_builtins(vm);
  cvm_register_hashtable_builtins(vm);
  cvm_register_sql_builtins(vm);
  cvm_register_mux_builtins(vm);
  cvm_register_string_builtins(vm);
  cvm_register_bootstrap_builtins(vm);
  cvm_register_regex_builtins(vm);
  cvm_register_process_builtins(vm);

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

  vm->source_file = load_path;
  Chunk *chunk = cvm_load(load_path, vm);

  if (profile) {
    vm->profiler.enabled = 1;
    vm->profiler.vm_interval = CVM_PROFILE_DEFAULT_VM_INTERVAL;
    vm->profiler.vm_countdown = 1 + rand() % (2 * CVM_PROFILE_DEFAULT_VM_INTERVAL);
    cvm_profiler_start_native(vm);
  }

  cvm_run_chunk(vm, chunk);

  if (profile) {
    cvm_profiler_stop_native(vm);
    cvm_profiler_report(vm);
  }

  return 0;
}
