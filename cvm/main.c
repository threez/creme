/* cvm — standalone prototype VM entry point. Loads a .cvmc file (produced by
 * `creme --emit-cvm <file.scm> <out.cvmc>`) and runs each of its top-level
 * chunks in order, exactly like Scheme::BytecodeCompiler.run_program runs
 * each top-level form of a real script — except globals persist across
 * chunks via one shared VM/global table while registers/frames reset per
 * chunk (mirroring dump_bytecode's one-fresh-VM-per-form pattern; see
 * cvm_serializer.cr's own doc comment). See cvm/README.md for full scope.
 *
 * This same "run each chunk in order" loop is also what makes a compiled
 * HTTP server (e.g. competition/scheme/demo-todo/app.scm) run correctly as
 * a genuinely long-running process, with no special-casing needed here:
 * mux.c's mux-listen! calls facil.io's fio_start() itself (see that file's
 * own comment) and blocks right there until the reactor stops (SIGINT/
 * SIGTERM) — so this loop simply doesn't advance past that chunk until the
 * server does. Whatever top-level forms come after (in app.scm's case,
 * (read-line)/mux-close!/sql-close, originally written for the interactive
 * single-process interpreter) still run afterward as ordinary best-effort
 * cleanup once the server actually stops. */
#include <gc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hashtable.h"
#include "mux.h"
#include "profiler.h"
#include "sql.h"
#include "strings.h"
#include "vm.h"

/* Mean instructions between VM-level samples — matches the interval
 * `creme --profile table` itself uses for `(creme prof-vm)` (see
 * src/main.cr's handle_profile). Not currently configurable from the CLI;
 * add a `--profile=<n>` form here if a bench ever needs a different rate. */
#define CVM_PROFILE_DEFAULT_VM_INTERVAL 200

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
  cvm_register_builtins(vm);
  cvm_register_hashtable_builtins(vm);
  cvm_register_sql_builtins(vm);
  cvm_register_mux_builtins(vm);
  cvm_register_string_builtins(vm);

  int n_chunks = 0;
  Chunk **chunks = cvm_load(path, &n_chunks, vm);

  if (profile) {
    vm->profiler.enabled = 1;
    vm->profiler.vm_interval = CVM_PROFILE_DEFAULT_VM_INTERVAL;
    vm->profiler.vm_countdown = 1 + rand() % (2 * CVM_PROFILE_DEFAULT_VM_INTERVAL);
    cvm_profiler_start_native(vm);
  }

  for (int i = 0; i < n_chunks; i++) {
    cvm_run_chunk(vm, chunks[i]);
  }

  if (profile) {
    cvm_profiler_stop_native(vm);
    cvm_profiler_report(vm);
  }

  return 0;
}
