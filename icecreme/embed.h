/* Embedding-convenience API for a host C program linking against
 * libcreme.a — see embed.c's own header comment and icecreme/README.md's
 * "Embedding" section for the full minimal call sequence a host program
 * needs. Not used by icecreme's own CLI (main.c) — these are net-new
 * capabilities for an external consumer, kept out of the CLI binary's own
 * SRCS so the CLI's behavior/size is unaffected. */
#ifndef CREME_EMBED_H
#define CREME_EMBED_H

#include "vm.h"

/* Bundles every process-global, one-time, order-sensitive runtime-startup
 * step icecreme's own main.c otherwise inlines: GC_INIT(), a default 256MB
 * GC_expand_hp sizing (skipped if GC_INITIAL_HEAP_SIZE is already set,
 * matching main.c's own convention), GC_set_oom_fn, and mp_set_memory_
 * functions redirecting GMP's allocator through Boehm GC. Call this exactly
 * once per process, before creme_alloc_vm and before touching any Scheme
 * rational (mp_set_memory_functions must run before any mpq_init anywhere
 * in the process — GMP has no per-instance allocator, only this one
 * process-wide setting). */
void creme_runtime_init(void);

/* Defines a plain (non-function) Scheme global — the value-side counterpart
 * of creme_register_builtin (vm.h). Mirrors it exactly: interns `name` via
 * creme_global_intern and writes `value`/bound=1 into that slot. Use
 * creme_register_builtin instead for a native C function; use this for a
 * host-defined constant (a version string, a config value already known at
 * startup, etc.). */
void creme_register_global(VM *vm, const char *name, Value value);

/* Runs an interactive REPL against `vm` (reads from stdin, writes to
 * stdout) — a thin wrapper over creme_run_scheme_file("icecreme/repl.scm"),
 * the repo's own 2-line `(creme repl)` shim (see embed.c's own comment for
 * why this compiles it fresh rather than loading a separately precompiled
 * repl.ice directly). Same repo-root-relative-CWD requirement as
 * creme_run_scheme_file below applies. Register whatever builtins/globals
 * the host wants reachable from the REPL BEFORE calling this
 * (creme_register_all_builtins, or creme_register_required_builtins with a
 * specific family list, plus any creme_register_builtin/creme_register_
 * global calls of the host's own) — same ordering rule as
 * creme_run_scheme_file below. */
void creme_run_repl(VM *vm);

/* Compiles and runs a plain `.scm` source file directly — no Crystal
 * `creme --emit-icecreme` step, no `.ice` file for the host to ship. Uses
 * the library's own bundled, precompiled self-hosted-compiler driver
 * (embedded at build time — see embedded_compiler_run.c, generated from
 * icecreme/compiler-run.scm) exactly the way icecreme's own CLI "compiler
 * mode" already does for a file-based driver (main.c) — creme_set_target_
 * path(scm_path), then load-and-run the driver's own chunk, which reads,
 * compiles, and runs the real target internally (recomputing and
 * registering whatever native builtin families THAT script needs along the
 * way — see bootstrap.c's bi_load_chunk_bytes).
 *
 * Register any of the host's OWN native functions/globals (creme_register_
 * builtin/creme_register_global) at any point before calling this — the
 * self-hosted compiler resolves every free identifier to a plain by-name
 * global reference at compile time regardless of whether anything is bound
 * to it yet (no compile-time "known global" check), so the host's names
 * are simply available the moment this call actually starts executing the
 * compiled target, in whatever order they were registered relative to this
 * call, as long as it's before.
 *
 * `scm_path` is resolved relative to the CALLING PROCESS's own current
 * working directory, not this binary's location or scm_path's own
 * directory — the self-hosted compiler looks up every library the script
 * imports via a repo-root-relative path (modules/scheme/ .sld files), same
 * assumption icecreme's own CLI already makes everywhere. A host embedding
 * this outside the repo needs either the repo root as its CWD, or to
 * vendor modules/ (with a matching relative scm_path) alongside its own
 * binary — see icecreme/README.md's "Embedding" section. */
void creme_run_scheme_file(VM *vm, const char *scm_path);

#endif
