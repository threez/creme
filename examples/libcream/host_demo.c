/* Minimal libcreme.a embedding example: a host C program registers several
 * of its OWN native functions/values as Scheme globals, then runs a plain
 * .scm script that calls/reads them — no `--emit-icecreme` precompilation
 * step, no .ice file shipped, no Crystal toolchain involved at runtime at
 * all. See ../../icecreme/README.md's "Embedding" section for the full
 * call-sequence writeup this mirrors.
 *
 * Beyond host-greet/host-version (strings), the functions below exercise
 * embed.h's list/vector/number helpers on both sides of the boundary —
 * host-sum takes a Scheme list of integers, host-scale-vector a vector of
 * numbers, host-word-lengths a list of strings (returning an alist a
 * Scheme (creme hash-table) can be built from directly), and host-stats a
 * variadic run of doubles — showing more of what a host's own native
 * functions can accept/return beyond a single string. */
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

/* host-sum: (host-sum '(1 2 3 4 5)) => 15 — creme_list_length/_to_values
 * turn the Scheme list into a plain C array of Values, which
 * creme_arg_int (its normal (args, nargs, index, who) shape) then
 * extracts+validates one element at a time — the same helper used for a
 * BuiltinFn's own `args` array works just as well on any Value array. */
static Value host_sum(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 1, "host-sum");
  int n = creme_list_length(args[0]);
  Value *items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  creme_list_to_values(args[0], items, n, "host-sum");
  int64_t total = 0;
  for (int i = 0; i < n; i++) total += creme_arg_int(items, n, i, "host-sum");
  return v_int(total);
}

/* host-scale-vector: (host-scale-vector #(1 2 3) 2.5) => #(2.5 5.0 7.5) —
 * creme_arg_vector for the vector's own backing (Value*, length) pair,
 * creme_arg_double for the scale factor, creme_vector_from_values to
 * build the (freshly GC_MALLOC'd) result. */
static Value host_scale_vector(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 2, "host-scale-vector");
  int len;
  Value *items = creme_arg_vector(args, nargs, 0, "host-scale-vector", &len);
  double scale = creme_arg_double(args, nargs, 1, "host-scale-vector");
  Value *scaled = GC_MALLOC(sizeof(Value) * (size_t)(len ? len : 1));
  for (int i = 0; i < len; i++) scaled[i] = v_float(creme_arg_double(items, len, i, "host-scale-vector") * scale);
  return creme_vector_from_values(scaled, len);
}

/* host-word-lengths: (host-word-lengths '("a" "bb" "ccc")) =>
 * (("a" . 1) ("bb" . 2) ("ccc" . 3)) — an alist, exactly the shape
 * (creme hash-table)'s own alist->hash-table-ish patterns expect, so
 * host_demo.scm can feed it straight into a real Scheme hash table
 * without this C function needing to know anything about hash tables
 * itself. creme_arg_bytes gets each string's raw (pointer, length) with
 * no copy; creme_bytes_value then copies just that slice into the pair's
 * own car. */
static Value host_word_lengths(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 1, "host-word-lengths");
  int n = creme_list_length(args[0]);
  Value *words = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  creme_list_to_values(args[0], words, n, "host-word-lengths");
  Value *pairs = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  for (int i = 0; i < n; i++) {
    int len;
    const char *s = creme_arg_bytes(words, n, i, "host-word-lengths", &len);
    pairs[i] = creme_cons(vm, creme_bytes_value(s, len), v_int(len));
  }
  return creme_list_from_values(vm, pairs, n);
}

/* host-stats: (host-stats 3 1 4 1 5 9 2 6) => #(min max avg) — a variadic
 * BuiltinFn reading straight from its own `args`/`nargs`, no list/vector
 * wrapper needed on the Scheme side at all. */
static Value host_stats(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "host-stats");
  double min = creme_arg_double(args, nargs, 0, "host-stats");
  double max = min, sum = 0;
  for (int i = 0; i < nargs; i++) {
    double v = creme_arg_double(args, nargs, i, "host-stats");
    if (v < min) min = v;
    if (v > max) max = v;
    sum += v;
  }
  Value stats[3] = {v_float(min), v_float(max), v_float(sum / nargs)};
  return creme_vector_from_values(stats, 3);
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
  creme_register_builtin(vm, "host-sum", host_sum);
  creme_register_builtin(vm, "host-scale-vector", host_scale_vector);
  creme_register_builtin(vm, "host-word-lengths", host_word_lengths);
  creme_register_builtin(vm, "host-stats", host_stats);

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
