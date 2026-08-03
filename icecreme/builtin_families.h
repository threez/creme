/* Maps an ICE1 "required families" name to the icecreme-side C function that
 * registers that family's builtins into a VM. Extracted out of main.c (which
 * also defines main()) so it can be linked into libcreme.a for embedding —
 * see builtin_families.c's own header comment. */
#ifndef CREME_BUILTIN_FAMILIES_H
#define CREME_BUILTIN_FAMILIES_H

#include "vm.h"

/* Registers the two always-on families (base/write) plus, for every other
 * name in `families`, whichever creme_register_*_builtins function that
 * family maps to (silently skipping a name icecreme has no native family for --
 * see this function's own doc comment in builtin_families.c). Called once at
 * startup with the loaded file's own required-families metadata, and again by
 * bootstrap.c's bi_load_chunk_bytes (icecreme's "compiler mode" case: the
 * startup call only sees precompiled compiler-run.ice's own near-empty
 * list, since the REAL target script's required families aren't known
 * until the self-hosted compiler actually compiles it, well after startup
 * registration already ran) with the real target's own list. */
void creme_register_required_builtins(VM *vm, char **families, int n_families);

/* Registers every builtin family this build knows about, unconditionally —
 * base/write plus every BUILTIN_FAMILIES entry (builtin_families.c) — rather
 * than only the ones a specific compiled script's required-families list
 * names. For an embedder running scripts it doesn't want to (or can't)
 * inspect ahead of time via creme_peek_required_families; costs a bit more
 * registration work up front, nothing else — registering an unused builtin
 * has no runtime cost beyond the one-time global-table slot. Idempotent per
 * family per VM, same as creme_register_required_builtins (skips anything
 * already registered on this VM). */
void creme_register_all_builtins(VM *vm);

#endif
