/* Minimal libcreme.a embedding example: a host C program registers its OWN
 * native function (host-greet) and native value (host-version) as Scheme
 * globals, then runs a plain .scm script that calls/reads them — no
 * `--emit-icecreme` precompilation step, no .ice file shipped, no Crystal
 * toolchain involved at runtime at all. See ../../icecreme/README.md's
 * "Embedding" section for the full call-sequence writeup this mirrors. */
#include <stdio.h>
#include <string.h>

#include <gc.h>

#include <icecreme/creme.h>

/* host-greet: (host-greet "world") => "Hello from C, world!" — a hand-
 * written BuiltinFn, exactly the shape every icecreme-internal `bi_*`
 * function already has (see e.g. creme_ffi.c's bi_ffi_open for the same
 * "validate arity/type, then build a fresh Value" idiom this mirrors). */
static Value host_greet(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs != 1 || args[0].tag != T_STR) {
    creme_abort("host-greet: expected 1 string argument");
  }

  /* Extract the argument as a NUL-terminated C string. */
  int arg_len = args[0].aux;
  char *arg = GC_MALLOC((size_t)arg_len + 1);
  memcpy(arg, args[0].as.chars, (size_t)arg_len);
  arg[arg_len] = '\0';

  /* Build the fresh reply string as a real Scheme Value. Strings in
   * icecreme are just a pointer+length pair (v_str, value.h) — no
   * separate "Scheme string object" to construct, just GC-owned bytes. */
  const char *prefix = "Hello from C, ";
  const char *suffix = "!";
  size_t reply_len = strlen(prefix) + (size_t)arg_len + strlen(suffix);
  char *reply = GC_MALLOC(reply_len + 1);
  snprintf(reply, reply_len + 1, "%s%s%s", prefix, arg, suffix);
  return v_str(reply, (int)reply_len);
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
  creme_register_global(vm, "host-version", v_str("libcream host demo 0.1", 22));

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
