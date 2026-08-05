/* creme_register_required_builtins/creme_register_all_builtins — extracted
 * out of main.c so this table (and the functions built on it) can be linked
 * into libcreme.a without pulling in main.c's own main() (a real symbol
 * clash for any embedder building its own executable). main.c itself still
 * calls these exactly as before; nothing about the CLI's own behavior
 * changes here, this is a pure move.
 *
 * 18 of the table's entries below are wrapped in a `#if CREME_WITH_<NAME>`
 * (builtin_config.h) matching the same macro that wraps that family's own
 * .c file entirely — see that header's own doc comment for which families
 * are gateable this way vs. always-on. When a macro is 0, its row simply
 * doesn't exist in BUILTIN_FAMILIES: the lookup loop below already treats
 * an unrecognized required-families name as "not implemented, skip it, let
 * an actual call fail loudly with 'unbound variable' later" (see that
 * loop's own comment) — a compiled-out family degrades exactly the same
 * way, no separate error handling needed. */
#include <stdint.h>
#include <string.h>

#include "builtin_config.h"

#include "actor.h"
#include "bigdecimal.h"
#include "bootstrap.h"
#include "builtin_families.h"
#include "creme_ffi.h"
#include "csv.h"
#include "digest.h"
#include "secure_random.h"
#include "cipher.h"
#include "pkey.h"
#include "x509.h"
#include "hashtable.h"
#include "http.h"
#include "json.h"
#include "yaml.h"
#include "zstd.h"
#include "mux.h"
#include "process.h"
#include "regex.h"
#include "sql.h"
#include "strings.h"
#include "term.h"
#include "treelist.h"
#include "vm.h"

/* Maps an ICE "required families" name (the third element of a
 * ["creme","builtin",X] library name, per icecreme_emitter.cr's `required_families`
 * computation) to the register_fn icecreme's builtins.c split it into --
 * see builtins.c's/vm.h's per-family creme_register_*_builtins split and the
 * 14 pre-existing per-file ones. "base" and "write" are deliberately absent
 * here (see register_required_builtins below) even though the compiler side
 * always lists them too (scheme/base.cr's AUTO_IMPORTED_LIBRARIES) -- they're
 * registered unconditionally rather than through this table. */
static const struct {
  const char *name;
  void (*register_fn)(VM *);
} BUILTIN_FAMILIES[] = {
    {"cxr", creme_register_cxr_builtins},
    {"complex", creme_register_complex_builtins},
    {"char", creme_register_char_builtins},
    {"process-context", creme_register_process_context_builtins},
    {"lazy", creme_register_lazy_builtins},
    {"math", creme_register_math_builtins},
    {"introspection", creme_register_introspection_builtins},
    {"file", creme_register_file_builtins},
    {"env", creme_register_env_builtins},
    {"hash-table", creme_register_hashtable_builtins},
#if CREME_WITH_SQL
    {"sql", creme_register_sql_builtins},
#endif
#if CREME_WITH_MUX
    {"mux", creme_register_mux_builtins},
#endif
#if CREME_WITH_STRING
    {"string", creme_register_string_builtins},
#endif
    {"bootstrap", creme_register_bootstrap_builtins},
    {"regex", creme_register_regex_builtins},
#if CREME_WITH_PROCESS
    {"process", creme_register_process_builtins},
#endif
#if CREME_WITH_CSV
    {"csv", creme_register_csv_builtins},
#endif
#if CREME_WITH_TREELIST
    {"treelist", creme_register_treelist_builtins},
#endif
#if CREME_WITH_ACTOR
    {"actor", creme_register_actor_builtins},
#endif
#if CREME_WITH_DIGEST
    {"digest", creme_register_digest_builtins},
#endif
#if CREME_WITH_SECURE_RANDOM
    {"secure-random", creme_register_secure_random_builtins},
#endif
#if CREME_WITH_CIPHER
    {"cipher", creme_register_cipher_builtins},
#endif
#if CREME_WITH_PKEY
    {"pkey", creme_register_pkey_builtins},
#endif
#if CREME_WITH_X509
    {"x509", creme_register_x509_builtins},
#endif
#if CREME_WITH_JSON
    {"json", creme_register_json_builtins},
#endif
#if CREME_WITH_YAML
    {"yaml", creme_register_yaml_builtins},
#endif
    {"zstd", creme_register_zstd_builtins}, /* required core dep -- never gated */
#if CREME_WITH_BIGDECIMAL
    {"bigdecimal", creme_register_bigdecimal_builtins},
#endif
#if CREME_WITH_HTTP
    {"http", creme_register_http_builtins},
#endif
#if CREME_WITH_TERM
    {"term", creme_register_term_builtins},
#endif
#if CREME_WITH_FFI
    {"ffi", creme_register_ffi_builtins},
#endif
};
#define N_BUILTIN_FAMILIES (int)(sizeof(BUILTIN_FAMILIES) / sizeof(BUILTIN_FAMILIES[0]))

/* Always calls the two "always on" families (matching scheme/base.cr's
 * AUTO_IMPORTED_LIBRARIES, which every compiled script implicitly imports
 * regardless of what it actually uses), then, for every OTHER name in the
 * compiled file's required-families list, looks it up in BUILTIN_FAMILIES
 * and registers it. A name that isn't "base"/"write" and isn't in
 * BUILTIN_FAMILIES is silently skipped, not an error: icecreme implements only a
 * documented subset of the Crystal interpreter's native libraries (see
 * README.md), so a compiled program can legitimately require a family (e.g.
 * "inexact", "random", "time") that has no icecreme-side register function at
 * all. If the program actually calls something from that family at run
 * time, it still fails loudly there with the normal "unbound variable"
 * abort -- this loop just must not treat "icecreme doesn't implement X" as fatal
 * up front.
 *
 * Non-static (declared in builtin_families.h): also called by bootstrap.c's
 * bi_load_chunk_bytes, for exactly the case this task exists to fix --
 * icecreme's own "compiler mode" (see main.c's header comment on
 * CREME_COMPILER_DRIVER_PATH) registers builtins ONCE, here, based on the
 * PRECOMPILED icecreme.ice's own required-families metadata --
 * before icecreme.scm has even read, let alone compiled, the REAL
 * target script main() actually pointed icecreme at. icecreme.ice's own
 * imports never include any of BUILTIN_FAMILIES (it needs none of them
 * itself), so relying on this call ALONE would leave every other family
 * permanently unregistered for compiler-mode runs regardless of what the
 * real target actually imports. bi_load_chunk_bytes closes that gap: the
 * self-hosted compiler now tracks the real target's own transitively-
 * required native families (modules/creme/compiler/compiler.sld's
 * required-native-families-list) and bakes them into the ICE bytes it
 * hands to load-chunk-bytes, which calls this same function again with
 * THAT real list right before running the loaded chunk. Calling this
 * twice (once here with icecreme.ice's own near-empty list, once
 * from bootstrap.c with the real target's list) is safe -- see
 * vm->registered_family_mask/base_write_registered's own doc comment
 * (vm.h) for why this function is idempotent PER FAMILY PER VM (skips a
 * family, including the always-on base/write pair, it already registered
 * on this exact vm) rather than unconditionally re-running every
 * register_fn on every call: bi_load_chunk_bytes now calls this on EVERY
 * loaded chunk (not just once at process startup) -- every nested self-
 * hosted-compiler library load, every `eval` call -- and re-registering
 * an already-registered name would silently stomp a real Scheme-level
 * redefinition of it (e.g. prim_call_spec.scm's own "deopts + to a
 * runtime redefinition" cases) back to the original native closure.
 *
 * Two of BUILTIN_FAMILIES' own entries get an extra, implied registration
 * beyond their own table lookup -- found empirically while wiring up
 * real required-families tracking for icecreme's own self-hosted-compiler
 * path, but affecting the ordinary native --emit-icecreme gate too,
 * independent of that: icecreme's own C-level register_fn split (builtins.c/
 * strings.c's own file/function boundaries) doesn't line up 1:1 with
 * Crystal's native family grouping (each *.cr file under src/creme/modules/scheme
 * has its own register_library calls). A program using ONLY (scheme char)
 * legitimately gets required_families = [..., "char"] (Crystal's char.cr
 * registers string-downcase/string-upcase/string-ci-comparisons/string-
 * foldcase under the SAME ["creme","builtin","char"] library as the
 * char-only predicates), but icecreme itself splits that same functionality
 * into TWO C functions -- builtins.c's creme_register_char_builtins (char-
 * only) and strings.c's creme_register_string_builtins (string-case
 * functions, ALSO covering (creme string)'s own unrelated string-trim/
 * split/join/etc, hence being its own separate family here too) -- so
 * requesting only "char" left string-downcase permanently unbound.
 * Symmetrically, (scheme process-context)'s Crystal registration
 * (process_context.cr) legitimately includes get-environment-variable/
 * set-environment-variable! (derived from the same underlying EnvVars
 * methods (creme env) also exposes under its own separate family), but
 * icecreme's own creme_register_process_context_builtins (builtins.c) only ever
 * registered `exit` -- the env accessors live solely in
 * creme_register_env_builtins. Requesting "string"/"env" directly still
 * works unchanged (via the ordinary BUILTIN_FAMILIES lookup); these two
 * extra bits (beyond one per BUILTIN_FAMILIES entry) just add the
 * implied registration so "char"/"process-context" alone are enough
 * too.
 *
 * A third case of the same mismatch: native Crystal's (creme file)/
 * (scheme file) (src/creme/modules/creme/file.cr) groups file-write/
 * delete-file under family "file" alongside file-exists?/open-input-
 * file/etc, but icecreme's own file-write/delete-file (bi_file_write/
 * bi_delete_file) are implemented in bootstrap.c and registered only by
 * creme_register_bootstrap_builtins, gated on family "bootstrap" --
 * requesting only "file" left them permanently unbound. Requesting
 * "bootstrap" directly still works unchanged (via the ordinary
 * BUILTIN_FAMILIES lookup); this third extra bit adds the implied
 * registration so "file" alone is enough too. (creme_register_bootstrap_
 * builtins also registers several compiler/REPL-only builtins --
 * import!/load-chunk-bytes/etc -- that a plain "file"-only program will
 * simply never call; harmless extra bindings, not a behavior change.) */
#define CREME_EXTRA_BIT_STRING_VIA_CHAR ((uint64_t)1 << N_BUILTIN_FAMILIES)
#define CREME_EXTRA_BIT_ENV_VIA_PROCESS_CONTEXT ((uint64_t)1 << (N_BUILTIN_FAMILIES + 1))
#define CREME_EXTRA_BIT_BOOTSTRAP_VIA_FILE ((uint64_t)1 << (N_BUILTIN_FAMILIES + 2))

void creme_register_required_builtins(VM *vm, char **families, int n_families) {
  if (!vm->base_write_registered) {
    creme_register_base_builtins(vm);
    creme_register_write_builtins(vm);
    vm->base_write_registered = 1;
  }

  for (int i = 0; i < n_families; i++) {
    const char *name = families[i];
    if (strcmp(name, "base") == 0 || strcmp(name, "write") == 0) continue;

    for (int j = 0; j < N_BUILTIN_FAMILIES; j++) {
      if (strcmp(name, BUILTIN_FAMILIES[j].name) == 0) {
        uint64_t bit = (uint64_t)1 << j;
        if (!(vm->registered_family_mask & bit)) {
          BUILTIN_FAMILIES[j].register_fn(vm);
          vm->registered_family_mask |= bit;
        }
        break;
      }
    }

#if CREME_WITH_STRING
    if (strcmp(name, "char") == 0 && !(vm->registered_family_mask & CREME_EXTRA_BIT_STRING_VIA_CHAR)) {
      creme_register_string_builtins(vm);
      vm->registered_family_mask |= CREME_EXTRA_BIT_STRING_VIA_CHAR;
    }
#endif
    if (strcmp(name, "process-context") == 0 && !(vm->registered_family_mask & CREME_EXTRA_BIT_ENV_VIA_PROCESS_CONTEXT)) {
      creme_register_env_builtins(vm);
      vm->registered_family_mask |= CREME_EXTRA_BIT_ENV_VIA_PROCESS_CONTEXT;
    }
    if (strcmp(name, "file") == 0 && !(vm->registered_family_mask & CREME_EXTRA_BIT_BOOTSTRAP_VIA_FILE)) {
      creme_register_bootstrap_builtins(vm);
      vm->registered_family_mask |= CREME_EXTRA_BIT_BOOTSTRAP_VIA_FILE;
    }
  }
}

/* Registers every family unconditionally rather than filtering by a
 * required-families list -- see builtin_families.h's own doc comment.
 * Reuses the exact same idempotency mask creme_register_required_builtins
 * does, so calling this and then creme_register_required_builtins (or vice
 * versa, e.g. from bootstrap.c's bi_load_chunk_bytes on a later nested
 * chunk load) on the same VM never double-registers anything. Doesn't need
 * the three CREME_EXTRA_BIT_* cases above at all: "string"/"env"/"bootstrap"
 * are themselves ordinary BUILTIN_FAMILIES entries, so registering
 * everything already covers what those extra bits exist to backfill for a
 * partial ("char"-only, etc.) required-families list. */
void creme_register_all_builtins(VM *vm) {
  if (!vm->base_write_registered) {
    creme_register_base_builtins(vm);
    creme_register_write_builtins(vm);
    vm->base_write_registered = 1;
  }

  for (int j = 0; j < N_BUILTIN_FAMILIES; j++) {
    uint64_t bit = (uint64_t)1 << j;
    if (!(vm->registered_family_mask & bit)) {
      BUILTIN_FAMILIES[j].register_fn(vm);
      vm->registered_family_mask |= bit;
    }
  }
}
