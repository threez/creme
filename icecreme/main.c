/* icecreme — standalone prototype VM entry point. Loads an "ICE1" file (produced
 * by `creme --emit-icecreme <file.scm> <out.ice>`, see icecreme_emitter.cr) — a
 * whole script (plus its transitively-imported pure-Scheme library bodies)
 * compiled into ONE Chunk — and runs it. See icecreme/README.md for full scope.
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

#include "bootstrap.h"
#include "builtin_families.h"
#include "profiler.h"
#include "vm.h"

/* Mean instructions between VM-level samples — matches the interval
 * `creme --profile table` itself uses for `(creme prof-vm)` (see
 * src/main.cr's handle_profile). Not currently configurable from the CLI;
 * add a `--profile=<n>` form here if a bench ever needs a different rate. */
#define CREME_PROFILE_DEFAULT_VM_INTERVAL 200

/* Repo-root-relative, matching this project's existing convention for
 * locating icecreme itself (e.g. src/main.cr's run_via_cvm hardcodes
 * "icecreme/icecreme") -- assumes icecreme is invoked from the repo root, same
 * assumption every other icecreme/creme cross-reference in this project makes. */
#define CREME_COMPILER_DRIVER_PATH "icecreme/compiler-run.ice"

/* A plain .scm file can never coincidentally start with the 4 bytes
 * "ICE1" (Scheme source always starts with whitespace, `(`, or `;`), so
 * this is a safe, content-based way to tell "already-compiled ICE1
 * binary" apart from "raw Scheme source needing compiler mode" -- no
 * `--compile` flag or file-extension convention needed. A file that
 * can't even be opened returns 0 here too, letting the real error
 * surface later from whichever path actually tries to open it. */
static int is_ice1_file(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  char magic[4];
  size_t n = fread(magic, 1, 4, f);
  fclose(f);
  return n == 4 && memcmp(magic, "ICE1", 4) == 0;
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

/* Reads an environment variable as a positive int, for creme_alloc_vm's
 * own stack_cap/frames_cap resource-limit overrides below. Unset,
 * empty, non-numeric, or non-positive all fall through to 0 (creme_alloc_
 * vm's own "use the default" sentinel) -- this is a best-effort CLI
 * convenience, not a validated embedding API, so silently ignoring a
 * malformed value rather than erroring out of the whole run is the
 * right call here. */
static int creme_getenv_int(const char *name) {
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
   * own (command-line) tail -- see creme_set_command_line_args below --
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
    fprintf(stderr, "usage: %s [--profile] <file.ice> [script-args...]\n", argv[0]);
    return 1;
  }
  creme_set_command_line_args(argv[0], script_argc, script_argv);

  GC_INIT();
  /* Boehm's own env-var handling inside GC_INIT() already honors an
   * explicit GC_INITIAL_HEAP_SIZE, growing the heap to that size before
   * we ever get here -- so only step in with our own default when the
   * caller didn't set one. Benchmarked (doc/optimization-icecreme.md's own GC
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
  GC_set_oom_fn(creme_gc_oom_handler); /* see vm.h's own doc comment */
  mp_set_memory_functions(gmp_gc_alloc, gmp_gc_realloc, gmp_gc_free);
  /* ICECREME_STACK_CAP/ICECREME_FRAMES_CAP: optional resource-limit overrides for
   * this run, read here rather than baked into a recompile -- the
   * concrete, exercisable-today form of creme_alloc_vm's own embedder-
   * configurable resource limits (see vm.h's doc comment there) until a
   * real embedding API (a linked-in caller passing its own values
   * directly) exists. Unset, empty, or non-positive falls through to
   * creme_alloc_vm's own CREME_DEFAULT_STACK_CAP/CREME_DEFAULT_FRAMES_CAP
   * default, same as passing 0 directly. */
  VM *vm = creme_alloc_vm(creme_getenv_int("ICECREME_STACK_CAP"), creme_getenv_int("ICECREME_FRAMES_CAP"));
  if (!vm) {
    fprintf(stderr, "icecreme: out of memory allocating VM state\n");
    return 1;
  }
  creme_set_current_vm(vm); /* lets creme_abort reach this VM's guard-handler stack */

  /* Compiler mode: `path` isn't a compiled ICE1 binary at all -- it's the
   * plain Scheme source icecreme should compile-and-run, entirely via the
   * bundled self-hosted-compiler driver (see icecreme/compiler-run.scm's own
   * header comment), never touching a live Crystal `creme` process. The
   * driver learns the real target path via icecreme-target-path, reads and
   * compiles it (expanding any `include`s itself), and runs the result. */
  const char *load_path = path;
  if (!is_ice1_file(path)) {
    creme_set_target_path(path);
    load_path = CREME_COMPILER_DRIVER_PATH;
  }

  /* Peek the required-families metadata BEFORE the real load: builtins must
   * be registered before creme_load's resolve_globals pass runs (it needs
   * creme_global_intern to see already-registered globals -- see
   * resolve_globals's own doc comment in loader.c), but the family list
   * itself only becomes known by parsing the file. creme_load re-reads (and,
   * since NULL/NULL is passed below, discards) this same section again
   * right after -- see creme_peek_required_families's doc comment in vm.h/
   * loader.c for why this is a second, separate open rather than sharing a
   * Reader across both calls. */
  char **families = NULL;
  int n_families = 0;
  creme_peek_required_families(load_path, &families, &n_families);
  creme_register_required_builtins(vm, families, n_families);

  vm->source_file = load_path;
  Chunk *chunk = creme_load(load_path, vm, NULL, NULL);

  if (profile) {
    vm->profiler.enabled = 1;
    vm->profiler.vm_interval = CREME_PROFILE_DEFAULT_VM_INTERVAL;
    vm->profiler.vm_countdown = 1 + rand() % (2 * CREME_PROFILE_DEFAULT_VM_INTERVAL);
    /* Shared with every child VM creme_new_child_vm ever creates from this
     * one (a spawned actor, or one of (creme mux)'s worker-pool/inline
     * dispatch VMs) -- see SharedVmSamples's own doc comment (vm.h) for
     * why a profiled program's "hot Scheme functions" report needs this
     * to reflect work done on threads other than this exact one. */
    vm->profiler.shared_vm_samples = GC_MALLOC(sizeof(SharedVmSamples));
    pthread_mutex_init(&vm->profiler.shared_vm_samples->mu, NULL);
    creme_profiler_start_native(vm);
  }

  creme_run_chunk(vm, chunk);

  if (profile) {
    creme_profiler_stop_native(vm);
    creme_profiler_report(vm);
  }

  return 0;
}
