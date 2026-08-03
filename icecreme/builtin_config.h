/* Compile-time opt-out for the 18 native builtin families that live in
 * their own separate .c file with a real external-library (or at least
 * standalone-.o) footprint -- sql/http/cipher/pkey/x509/digest/secure-
 * random/actor (openssl-touching, several sharing -lcrypto), ffi
 * (libffi+dlopen), yaml (libyaml), and mux/csv/treelist/json/bigdecimal/
 * term/process/string (no extra external lib, but still their own .o).
 * Each `CREME_WITH_<NAME>` macro below defaults to 1 (included) --
 * matching every prior release's "everything always in" behavior -- and
 * can be set to 0 from the Makefile (`make lib CREME_WITH_SQL=0 ...`) to
 * drop that family's .c file down to an empty translation unit (no
 * external header even processed, so its `-dev` package needn't be
 * installed) and its BUILTIN_FAMILIES table row (builtin_families.c), so
 * the linker never pulls in the associated external library either. See
 * icecreme/README.md's "Embedding" section and examples/libcream/README.md
 * for the concrete minimal-dependency build this enables.
 *
 * Two other tiers of "family" deliberately have NO macro here:
 *
 * - The 8 families with zero external dependency that live as small
 *   function groups inside the one always-compiled builtins.c monolith --
 *   cxr, complex, char, process-context, math, introspection, file, env.
 *   Gating these would mean wrapping scattered functions inside a
 *   ~5000-line file for no dependency or meaningful size reduction, so
 *   they stay always-on.
 * - The 4 families the bundled self-hosted compiler needs internally,
 *   regardless of what an embedder's own target .scm script imports --
 *   regex, hash-table, bootstrap, lazy (the last inside builtins.c, the
 *   other three each in their own file) -- plus the always-on "base"/
 *   "write" pair. Every `creme_run_scheme_file`/`creme_run_repl` embedder
 *   needs these unconditionally, so they are never gateable. */
#ifndef CREME_BUILTIN_CONFIG_H
#define CREME_BUILTIN_CONFIG_H

#ifndef CREME_WITH_SQL
#define CREME_WITH_SQL 1 /* sql.c -- sqlite3 */
#endif
#ifndef CREME_WITH_HTTP
#define CREME_WITH_HTTP 1 /* http.c -- openssl (ssl+crypto), sockets */
#endif
#ifndef CREME_WITH_CIPHER
#define CREME_WITH_CIPHER 1 /* cipher.c -- openssl (crypto) */
#endif
#ifndef CREME_WITH_PKEY
#define CREME_WITH_PKEY 1 /* pkey.c -- openssl (crypto) */
#endif
#ifndef CREME_WITH_X509
#define CREME_WITH_X509 1 /* x509.c -- openssl (crypto) */
#endif
#ifndef CREME_WITH_DIGEST
#define CREME_WITH_DIGEST 1 /* digest.c -- openssl (crypto) */
#endif
#ifndef CREME_WITH_SECURE_RANDOM
#define CREME_WITH_SECURE_RANDOM 1 /* secure_random.c -- openssl (crypto) */
#endif
#ifndef CREME_WITH_ACTOR
#define CREME_WITH_ACTOR 1 /* actor.c -- openssl (crypto) + pthread/sockets */
#endif
#ifndef CREME_WITH_FFI
#define CREME_WITH_FFI 1 /* creme_ffi.c -- libffi + dlopen(3) */
#endif
#ifndef CREME_WITH_YAML
#define CREME_WITH_YAML 1 /* yaml.c -- libyaml */
#endif
#ifndef CREME_WITH_MUX
#define CREME_WITH_MUX 1 /* mux.c -- sockets/poll/pthread only */
#endif
#ifndef CREME_WITH_CSV
#define CREME_WITH_CSV 1 /* csv.c -- no external lib */
#endif
#ifndef CREME_WITH_TREELIST
#define CREME_WITH_TREELIST 1 /* treelist.c -- no external lib */
#endif
#ifndef CREME_WITH_JSON
#define CREME_WITH_JSON 1 /* json.c -- no external lib */
#endif
#ifndef CREME_WITH_BIGDECIMAL
#define CREME_WITH_BIGDECIMAL 1 /* bigdecimal.c -- GMP (already required) */
#endif
#ifndef CREME_WITH_TERM
#define CREME_WITH_TERM 1 /* term.c -- no external lib */
#endif
#ifndef CREME_WITH_PROCESS
#define CREME_WITH_PROCESS 1 /* process.c -- no external lib */
#endif
#ifndef CREME_WITH_STRING
#define CREME_WITH_STRING 1 /* strings.c -- no external lib (sds vendored) */
#endif

#endif
