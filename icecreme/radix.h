/* (creme radix) -- see radix.c for the algorithm. General-purpose,
 * VM-agnostic byte-radix trie: mux.c builds its own (creme mux) routing
 * on top of the RadixTree/radix_tree_* core below (ALWAYS compiled,
 * regardless of CREME_WITH_RADIX -- see radix.c's own comment), and
 * creme_register_radix_builtins (gated by CREME_WITH_RADIX, like every
 * other no-external-lib family) exposes the same core directly to
 * Scheme as (creme radix), for any other ":name"/"*name"-style
 * prefix-matching use. */
#ifndef CREME_RADIX_H
#define CREME_RADIX_H

#include <stddef.h>

#include "vm.h"

typedef enum { RADIX_NORMAL, RADIX_NAMED, RADIX_GLOB } RadixKind;

typedef struct RadixNode {
  const char *key; /* GC-owned raw byte chunk -- a literal run, or a whole
                     * ":name"/"*name" token (see radix.c's tokenizer) */
  size_t key_len;
  struct RadixNode **children;
  int n_children, cap_children;
  RadixKind kind;
  void *payload; /* NULL until some radix_tree_add call terminates here */
} RadixNode;

typedef struct {
  RadixNode *root;
  int count; /* number of distinct terminal patterns added (re-adding an
              * existing pattern overwrites its payload without bumping this) */
} RadixTree;

typedef struct {
  const char *name;
  size_t name_len;
  const char *value;
  size_t value_len;
} RadixParam;

RadixTree *radix_tree_new(void);
void radix_tree_add(RadixTree *t, const char *key, size_t key_len, void *payload);

/* Returns the matched payload, or NULL. On a match, writes up to
 * max_params captured ":name"/"*name" params into out_params (in the
 * order encountered root-to-leaf) and the actual count into *out_nparams
 * -- extra captures beyond max_params are silently dropped (same
 * generous-fixed-cap reasoning MUX_MAX_HEADERS already uses elsewhere in
 * this codebase). */
void *radix_tree_find(RadixTree *t, const char *path, size_t path_len, RadixParam *out_params, int *out_nparams, int max_params);

void creme_register_radix_builtins(VM *vm);

#endif
