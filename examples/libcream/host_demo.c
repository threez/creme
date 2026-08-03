/* Minimal libcreme.a embedding example: a small "receipt generator". The
 * host owns a live price catalog (a hash table it builds and could
 * update at any time — a config reload, a live price feed, etc.) and a
 * fixed list of pending orders, and delegates the actual report logic to
 * a user-editable Scheme script (host_demo.scm) it doesn't want to
 * recompile itself for every change — exactly the shape a real host
 * program embeds icecreme for: a customizable pricing/report/policy
 * layer on top of state and data the host itself owns. See
 * ../../icecreme/README.md's "Embedding" section for the full
 * call-sequence writeup this mirrors. */
#include <stdio.h>

#include <icecreme/creme.h>

/* The host's own authoritative state — a live price catalog it owns and
 * could update at any time. The Scheme side only ever reads it through
 * host-price-lookup below, never touches CremeHashTable's own internals
 * (private to hashtable.c) directly. */
static Value g_catalog;

/* host-welcome: (host-welcome "Alice") => "Welcome to Ionos Grocery,
 * Alice!" — creme_arg_cstr/creme_format_value, exactly the shape every
 * icecreme-internal `bi_*` function already has. */
static Value host_welcome(VM *vm, Value *args, int nargs) {
  (void)vm;
  const char *name = creme_arg_cstr(args, nargs, 0, "host-welcome");
  return creme_format_value("Welcome to Ionos Grocery, %s!", name);
}

/* host-price-lookup: (host-price-lookup "apple") => 150 (cents; or #f if
 * the item isn't in the catalog) — a REAL hash-table key/value access
 * performed FROM the host's own C code against g_catalog, the host's own
 * live state, via embed.h's creme_hash_table_get. */
static Value host_price_lookup(VM *vm, Value *args, int nargs) {
  const char *item = creme_arg_cstr(args, nargs, 0, "host-price-lookup");
  return creme_hash_table_get(vm, g_catalog, creme_cstr_value(item), v_bool(0));
}

/* host-log: (host-log "message") — a side-effecting host capability
 * (writes to stderr with a fixed prefix), not a value-returning
 * computation; the kind of thing a script commonly needs from its host
 * (logging, persistence, notifications) beyond pure data in/out. */
static Value host_log(VM *vm, Value *args, int nargs) {
  (void)vm;
  const char *msg = creme_arg_cstr(args, nargs, 0, "host-log");
  fprintf(stderr, "[host] %s\n", msg);
  return v_nil();
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

  /* Build the host's own price catalog once, at startup — a real
   * embedder might load this from a config file/database instead. Prices
   * are integer CENTS, not floats: money arithmetic on binary floats
   * accumulates visible rounding noise (0.1 + 0.2 prints as
   * 0.30000000000000004 in any IEEE-754 language, icecreme included) —
   * exact integer cents is the standard way real point-of-sale/receipt
   * code avoids that, not just a display trick. */
  g_catalog = creme_hash_table_new(vm);
  creme_hash_table_set(vm, g_catalog, creme_cstr_value("apple"), v_int(150));
  creme_hash_table_set(vm, g_catalog, creme_cstr_value("bread"), v_int(320));
  creme_hash_table_set(vm, g_catalog, creme_cstr_value("milk"), v_int(275));

  creme_register_builtin(vm, "host-welcome", host_welcome);
  creme_register_builtin(vm, "host-price-lookup", host_price_lookup);
  creme_register_builtin(vm, "host-log", host_log);
  creme_register_global(vm, "host-store-name", creme_cstr_value("Ionos Grocery"));

  /* The pending orders themselves — real input data for the report
   * script, a native list of (item . quantity) pairs built directly with
   * embed.h's creme_cons/creme_list_from_values. */
  {
    const char *names[4] = {"apple", "apple", "bread", "milk"};
    int qtys[4] = {3, 2, 1, 2};
    Value order_pairs[4];
    for (int i = 0; i < 4; i++) order_pairs[i] = creme_cons(vm, creme_cstr_value(names[i]), v_int(qtys[i]));
    creme_register_global(vm, "host-orders", creme_list_from_values(vm, order_pairs, 4));
  }

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
