/* libFuzzer harness for creme_load_from_bytes (loader.c) -- the ICE
 * bytecode deserializer, the concrete untrusted-input boundary an
 * embedder crosses whenever it loads a precompiled .ice/bytevector it
 * didn't itself just compile (see icecreme/README.md's embedding notes).
 * Every OTHER icecreme entry point (raw .scm source) goes through the self-
 * hosted/native COMPILER first, which never accepts arbitrary untrusted
 * bytes in the first place -- this loader is the one place a byte blob
 * is trusted at face value.
 *
 * Build: `gmake -C icecreme fuzz` (needs clang; libFuzzer ships with clang's
 * own compiler-rt, no separate package). No seed corpus is committed to
 * this repo -- point a run at an empty directory to start from scratch,
 * or seed it yourself first from any real .ice files you have locally
 * (e.g. `gmake -C icecreme all` produces icecreme/icecreme.ice, or
 * `bin/creme --emit-icecreme <script.scm> <out.ice>` on any script). Example:
 * `mkdir -p icecreme/fuzz/corpus && icecreme/fuzz-loader -max_total_time=300
 * icecreme/fuzz/corpus`. Add `-jobs=N`/`-workers=N` for a parallel run, or a
 * plain `-runs=N` for a quick, bounded, deterministic pass. Not yet
 * wired into CI (no CI exists yet at all) -- run it locally for now
 * after any loader.c change.
 *
 * Each iteration gets its OWN fresh VM (GC_MALLOC zero-inits every
 * field), so no state (globals table, handler stack) leaks between
 * fuzz iterations sharing this one persistent process. has_actor_unwind
 * + a local setjmp is the same mechanism actor.c's own spawned-actor
 * threads use to confine an uncaught creme_abort to just their own
 * unwind point instead of exit()ing the whole process (see vm.h's own
 * has_actor_unwind doc comment) -- exactly what a persistent, many-
 * iterations-per-process fuzzer needs: a malformed input's expected
 * "icecreme: corrupt bytecode..." abort must be caught right here, not tear
 * down the entire fuzzing run. */
#include <setjmp.h>
#include <stdint.h>
#include <string.h>

#include <gc.h>

#include "../builtin_families.h"
#include "../vm.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  VM *vm = GC_MALLOC(sizeof(VM));
  creme_set_current_vm(vm);
  vm->has_actor_unwind = 1;
  if (setjmp(vm->actor_unwind) == 0) {
    char **families = NULL;
    int n_families = 0;
    creme_load_from_bytes(vm, data, size, &families, &n_families);
  }
  /* A caught creme_abort (the expected outcome for almost every fuzzed
   * input -- "corrupt bytecode", truncated file, implausible count,
   * excess nesting, etc.) lands here via the longjmp above; a
   * successfully-parsed input just falls through normally. Either way,
   * this iteration is done -- the resulting Chunk tree (if any) is
   * simply abandoned to the GC, mirroring how a real embedder would
   * discard a chunk it decided not to run. */
  return 0;
}
