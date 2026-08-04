/* icecreme — entry point for the C11 bytecode VM. This is a deliberately thin
 * launcher: it does the one-time C-only startup (GC/GMP/VM init, register the
 * native builtins), then loads and runs ONE embedded chunk — the CLI program
 * icecreme/icecreme.scm (compiled to icecreme.ice and baked in via the Makefile's
 * bin2c rule). Everything a user sees — parsing the command line, the REPL,
 * running a .scm source or a precompiled .ice, --emit-icecreme/--static,
 * -S/--dump-bytecode, --disassemble, --version, --help — lives in that Scheme
 * program (which bundles the self-hosted compiler and disassembler), reached
 * here purely via (command-line). main.c itself understands only `--profile`,
 * because that drives the native C profiler wrapping the whole run.
 *
 * Because the whole program is one chunk running on one VM, a compiled HTTP
 * server (e.g. competition/scheme/demo-todo/app.scm) runs correctly as a
 * genuinely long-running process with no special-casing: mux.c's mux-listen!
 * runs its own accept loop on the calling thread and blocks until it stops, so
 * the run simply doesn't return until the server does. See icecreme/README.md. */
#include <gc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "builtin_families.h"
#include "profiler.h"
#include "vm.h"

/* Mean instructions between VM-level samples — matches the interval
 * `creme --profile table` itself uses for `(creme prof-vm)` (see
 * src/main.cr's handle_profile). Not currently configurable from the CLI;
 * add a `--profile=<n>` form here if a bench ever needs a different rate. */
#define CREME_PROFILE_DEFAULT_VM_INTERVAL 200

/* The CLI program's (icecreme/icecreme.scm) ICE bytes, embedded into the binary
 * at build time by icecreme/Makefile's bin2c rule (embedded_icecreme.c). This is
 * the ONE chunk main() runs; it reads (command-line) and does everything else. */
extern const unsigned char creme_embedded_icecreme_ice[];
extern const size_t creme_embedded_icecreme_ice_len;

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
  /* Leading `--profile` (optionally followed by a `table` report-format token,
   * accepted for symmetry with native `creme --profile table <file>`) is the
   * one flag main.c handles itself -- it drives the native C profiler, which
   * wraps the whole run below. Everything from the first remaining token onward
   * is forwarded verbatim to icecreme.scm via (command-line): IT parses
   * --emit-icecreme/--static/-S/--disassemble/--version/--help/`--`/stdin/run/
   * REPL. That same forwarded slice is also the running script's own
   * (command-line) tail, matching native's contract exactly ([PROGRAM_NAME] +
   * ARGV, ARGV still including the script's own path as its first element --
   * process_context.cr never strips it). */
  int profile = 0;
  int i = 1;
  if (i < argc && strcmp(argv[i], "--profile") == 0) {
    profile = 1;
    i++;
    if (i < argc && strcmp(argv[i], "table") == 0) i++;
  }
  int fwd_argc = argc - i;
  char **fwd_argv = (fwd_argc > 0) ? &argv[i] : NULL;
  creme_set_command_line_args(argv[0], fwd_argc, fwd_argv);

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

  /* Register every builtin family up front: icecreme.scm may REPL/compile/emit/
   * disassemble/run arbitrary code, so all of them must be available, and its
   * own chunk's resolve_globals pass runs inside creme_load_from_bytes below,
   * which needs them already present. "Everything on" is the simplest correct
   * choice (same as examples/libcream/host_demo.c). The ~500KB icecreme.ice's
   * top-level defines the whole self-hosted toolchain in a few milliseconds --
   * fast enough that there is no separate "run a precompiled .ice without the
   * compiler" path here; a precompiled .ice is just one of the things
   * icecreme.scm loads-and-runs. */
  creme_register_all_builtins(vm);
  vm->source_file = "<icecreme>";
  Chunk *chunk = creme_load_from_bytes(vm, creme_embedded_icecreme_ice,
                                       creme_embedded_icecreme_ice_len, NULL, NULL);

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
