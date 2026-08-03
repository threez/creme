/* Minimal libcreme.a embedding example: a host C program registers its OWN
 * native function (host-greet) and native value (host-version) as Scheme
 * globals, then runs a plain .scm script that calls/reads them — no
 * `--emit-icecreme` precompilation step, no .ice file shipped, no Crystal
 * toolchain involved at runtime at all. See ../../icecreme/README.md's
 * "Embedding" section for the full call-sequence writeup this mirrors. */
#include <stdio.h>

#include <icecreme/creme.h>

/* host-greet: (host-greet "world") => "Hello from C, world!" — a hand-
 * written BuiltinFn, exactly the shape every icecreme-internal `bi_*`
 * function already has, just using embed.h's own creme_arg_cstr/
 * creme_format_value helpers instead of hand-rolling the arity/type
 * check and GC_MALLOC/memcpy/snprintf dance directly. */
static Value host_greet(VM *vm, Value *args, int nargs) {
  (void)vm;
  const char *name = creme_arg_cstr(args, nargs, 0, "host-greet");
  return creme_format_value("Hello from C, %s!", name);
}

int main(void) {
  creme_runtime_init();

  VM *vm = creme_alloc_vm(0, 0);
  if (!vm) {
    fprintf(stderr, "host_demo: out of memory allocating VM state\n");
    return 1;
  }
  creme_set_current_vm(vm);

  /* Register every builtin family this build knows about — simplest
   * default for a host running a script it doesn't want to (or can't)
   * inspect ahead of time. A size-conscious embedder could instead
   * creme_peek_required_families + creme_register_required_builtins with
   * just the families a specific known script needs. */
  creme_register_all_builtins(vm);

  /* The host's own native function and value — must be registered before
   * creme_run_scheme_file below actually starts executing the script
   * (order relative to the call itself doesn't matter beyond that). */
  creme_register_builtin(vm, "host-greet", host_greet);
  creme_register_global(vm, "host-version", creme_cstr_value("libcream host demo 0.1"));

  /* Compiles-and-runs host_demo.scm directly, via the self-hosted compiler
   * bundled into libcreme.a at build time (icecreme/Makefile's embedded_
   * compiler_run.c) — no separate `creme --emit-icecreme` step.
   *
   * Path is repo-root-relative, not relative to this binary's own
   * directory: the self-hosted compiler resolves every library it needs
   * ((scheme base), etc., from modules/scheme/ .sld files) relative to the
   * process's own working directory, same repo-root-relative assumption
   * icecreme's own CLI already makes everywhere else (main.c's
   * CREME_COMPILER_DRIVER_PATH, spec/creme spec files, and every other
   * icecreme/creme cross-reference in this project) — so run this binary
   * FROM THE REPO ROOT: `./examples/libcream/host_demo`, not `cd
   * examples/libcream && ./host_demo`. See this directory's own README. */
  creme_run_scheme_file(vm, "examples/libcream/host_demo.scm");

  return 0;
}
