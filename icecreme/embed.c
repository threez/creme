/* Embedding-convenience API — see embed.h. Everything here is additive: a
 * thin, host-facing layer over mechanisms that already exist elsewhere in
 * icecreme (creme_alloc_vm, creme_register_builtin, creme_load_from_bytes,
 * creme_run_chunk, main.c's own "compiler mode" recipe) — nothing here
 * duplicates VM/loader/dispatch logic, it only assembles existing pieces
 * into single calls for a host program that doesn't want to reimplement
 * main.c's own startup sequence by hand. */
#include <stdlib.h>
#include <string.h>

#include <gc.h>
#include <gmp.h>

#include "bootstrap.h"
#include "embed.h"

/* Embedded at build time by icecreme/Makefile's bin2c-driven rules — see
 * that Makefile's own comment and icecreme/tools/bin2c.c. The precompiled
 * self-hosted-compiler driver's ICE1 chunk bytes, for creme_run_scheme_file.
 * Doesn't need to exist on disk at runtime — this is exactly what main.c's
 * own file-based CREME_COMPILER_DRIVER_PATH reads from disk, just baked
 * into the library binary instead. */
extern const unsigned char creme_embedded_compiler_run_ice[];
extern const size_t creme_embedded_compiler_run_ice_len;

/* Same allocator-redirection idiom main.c's own gmp_gc_alloc/_realloc/_free
 * use — duplicated here rather than shared, since embed.c (library-only)
 * and main.c (CLI-only) are never linked into the same binary, so there's
 * no symbol collision to avoid; see main.c's own copy for the full
 * rationale (GMP has no per-instance allocator, only this one process-wide
 * setting, so it must be redirected through the same collector every other
 * heap allocation in icecreme uses). */
static void *creme_embed_gmp_alloc(size_t size) { return GC_MALLOC(size); }
static void *creme_embed_gmp_realloc(void *ptr, size_t old_size, size_t new_size) {
  (void)old_size;
  return GC_REALLOC(ptr, new_size);
}
static void creme_embed_gmp_free(void *ptr, size_t size) {
  (void)ptr;
  (void)size;
}

void creme_runtime_init(void) {
  GC_INIT();
  if (!getenv("GC_INITIAL_HEAP_SIZE")) {
    size_t default_heap = 256 * 1024 * 1024;
    size_t heap_size = GC_get_heap_size();
    if (heap_size < default_heap) GC_expand_hp(default_heap - heap_size);
  }
  GC_set_oom_fn(creme_gc_oom_handler);
  mp_set_memory_functions(creme_embed_gmp_alloc, creme_embed_gmp_realloc, creme_embed_gmp_free);
}

void creme_register_global(VM *vm, const char *name, Value value) {
  int slot = creme_global_intern(vm, name, (int)strlen(name));
  vm->globals[slot].value = value;
  vm->globals[slot].bound = 1;
}

void creme_run_repl(VM *vm) {
  /* Delegates to creme_run_scheme_file against the repo's own icecreme/
   * repl.scm (a 2-line shim over (creme repl)) — see icecreme/README.md's
   * "REPL" section: (creme repl) relies on (scheme read)/(scheme eval)/
   * (interaction-environment), which icecreme has no native C builtins
   * for at all — the ONLY place they're backed is the bundled self-hosted
   * compiler's own toolchain setup (compiler mode), which defines them
   * itself before compiling-and-running the target. An ahead-of-time
   * `--emit-icecreme` build of repl.scm skips that bridge entirely and
   * aborts with an unbound-variable error on the first form submitted —
   * repl.scm must always run as source through the compiler-mode path,
   * never precompiled, confirmed via `./icecreme/icecreme icecreme/
   * repl.ice` failing that exact way outside any of this embedding code
   * too (there: "unbound variable: interaction-environment"). */
  creme_run_scheme_file(vm, "icecreme/repl.scm");
}

void creme_run_scheme_file(VM *vm, const char *scm_path) {
  creme_set_target_path(scm_path);
  Chunk *driver = creme_load_from_bytes(vm, creme_embedded_compiler_run_ice, creme_embedded_compiler_run_ice_len, NULL, NULL);
  creme_run_chunk(vm, driver);
}
