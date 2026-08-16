/* (creme radix) — see radix.h.
 *
 * A general-purpose, VM-agnostic byte-radix trie, factored out of what
 * used to be icecreme/mux.c's own private linear-scanned route table
 * (see mux.c's own header comment for that history) so both mux.c and
 * this file's own Scheme-facing (creme radix) module share one
 * implementation rather than mux.c owning a copy nobody else can reach.
 *
 * Matches native Crystal's own radix-based routing (mux.cr, via the
 * `threez/mux.cr` shard wrapping `luislavena/radix`): a compressed
 * prefix trie with three node kinds -- Normal (a literal byte run),
 * Named (a whole ":name" token, capturing up to the next '/' or the end
 * of the matched string), and Glob (a whole "*name" token, capturing
 * everything remaining) -- where children are always tried in
 * Normal-then-Named-then-Glob order at every branch, so a static route
 * always beats an overlapping ":name"/"*name" one REGARDLESS of
 * registration order (see sort_children below). Unlike the old MUX_MAX_
 * SEGS/MUX_SEG_LEN-bounded segment-array scan this replaces, there is no
 * depth or per-token length cap here: keys are tokenized once at insert
 * time (see radix_tree_add's own tokenizer loop) into literal/":name"/
 * "*name" chunks, and each chunk is only ever bounded by the actual key
 * length.
 *
 * ':' and '*' are ALWAYS pattern syntax here, never literal bytes,
 * matching mux.c's own pre-existing convention (its old match_route only
 * ever checked a segment's first byte for ':'); a literal path
 * containing either character is not representable by this tokenizer.
 * A ":name" token runs from the ':' up to (not including) the next '/'
 * or the end of the key; a "*name" token always runs to the end of the
 * key (a glob is meant to be the last segment of a pattern).
 *
 * Node insertion/matching: two Normal chunks are compared and split on
 * their real common byte prefix (classic radix compression); a Named or
 * Glob chunk only ever "matches" an existing sibling by whole-token
 * identity (same kind, identical bytes) -- comparing partial byte
 * overlap between e.g. ":id" and ":identifier" would otherwise try to
 * split a param's own name in half, which has no sensible meaning. Two
 * different param names at the same tree position simply become
 * separate sibling Named nodes instead (an inherently ambiguous
 * shape -- which one wins is unspecified, same as it would be for any
 * router asked to disambiguate two different capture names on the same
 * path shape).
 *
 * Re-adding an already-registered pattern overwrites its payload in
 * place (not an error, not a duplicate entry). */
#include <string.h>

#include <gc.h>

#include "radix.h"

/* The core trie below (radix_tree_new/add/find) is ALWAYS compiled,
 * regardless of CREME_WITH_RADIX -- mux.c builds its own (creme mux)
 * routing directly on top of it (icecreme/mux.c, gated only by
 * CREME_WITH_MUX) and must not lose that dependency just because an
 * embedder drops the public (creme radix) Scheme module. Only the
 * Scheme-facing builtins at the bottom of this file are gated. */

/* ---- node construction / growable-children array (GC_MALLOC/GC_REALLOC,
 * no manual free — same idiom mux.c's own MuxApp.routes and treelist.c's
 * own node arrays already use throughout this codebase) ---- */

static RadixNode *new_node(const char *key, size_t key_len, RadixKind kind) {
  RadixNode *n = GC_MALLOC(sizeof(RadixNode));
  char *owned = GC_MALLOC(key_len ? key_len : 1);
  if (key_len) memcpy(owned, key, key_len);
  n->key = owned;
  n->key_len = key_len;
  n->kind = kind;
  return n;
}

static void append_child(RadixNode *parent, RadixNode *child) {
  if (parent->n_children >= parent->cap_children) {
    parent->cap_children = parent->cap_children ? parent->cap_children * 2 : 4;
    parent->children = GC_REALLOC(parent->children, sizeof(RadixNode *) * (size_t)parent->cap_children);
  }
  parent->children[parent->n_children++] = child;
}

/* Normal < Named < Glob, so a lookup always tries static children before
 * param children before a catch-all -- this one ordering rule is what
 * gives registration-order-independent precedence (see radix_tree_find). */
static int child_rank(RadixKind k) { return (int)k; }

static void sort_children(RadixNode *parent) {
  /* Small fixed-shape arrays (one tree level's own branching factor,
   * never adversarial) -- plain insertion sort, no need for qsort here. */
  for (int i = 1; i < parent->n_children; i++) {
    RadixNode *cur = parent->children[i];
    int j = i - 1;
    while (j >= 0 && child_rank(parent->children[j]->kind) > child_rank(cur->kind)) {
      parent->children[j + 1] = parent->children[j];
      j--;
    }
    parent->children[j + 1] = cur;
  }
}

/* Splits `child`'s key at byte offset `common`: child keeps its first
 * `common` bytes and becomes the new shared-prefix node (payload/kind
 * always NORMAL here, per node_common's own rule that only two Normal
 * chunks are ever compared/split against each other); a new node,
 * `tail`, inherits the rest of child's original key/children/payload as
 * its sole child. Returns `child` itself, now representing exactly the
 * `common`-byte prefix. */
static RadixNode *split_node(RadixNode *child, size_t common) {
  RadixNode *tail = new_node(child->key + common, child->key_len - common, RADIX_NORMAL);
  tail->children = child->children;
  tail->n_children = child->n_children;
  tail->cap_children = child->cap_children;
  tail->payload = child->payload;

  child->key_len = common;
  child->payload = NULL;
  child->children = NULL;
  child->n_children = 0;
  child->cap_children = 0;
  append_child(child, tail);
  return child;
}

/* Common-prefix length between an existing `child` and an incoming
 * token `(key, key_len)` of kind `kind`. Two Normal chunks compare
 * byte-by-byte; anything else (either side Named/Glob) only "overlaps"
 * on a whole-token exact match (see this file's own header comment) --
 * otherwise treated as zero overlap, i.e. a genuinely distinct sibling. */
static size_t node_common(const RadixNode *child, const char *key, size_t key_len, RadixKind kind) {
  if (child->kind != RADIX_NORMAL || kind != RADIX_NORMAL) {
    if (child->kind == kind && child->key_len == key_len && memcmp(child->key, key, key_len) == 0) return key_len;
    return 0;
  }
  size_t n = child->key_len < key_len ? child->key_len : key_len;
  size_t i = 0;
  while (i < n && child->key[i] == key[i]) i++;
  return i;
}

/* Inserts one token (already tokenized by radix_tree_add, below) under
 * `node`, splitting/creating child nodes as needed, and returns the node
 * that now represents having consumed exactly this token -- the caller
 * attaches the NEXT token (if any) as that node's own child. */
static RadixNode *insert_token(RadixNode *node, const char *key, size_t key_len, RadixKind kind) {
  for (int i = 0; i < node->n_children; i++) {
    RadixNode *child = node->children[i];
    size_t common = node_common(child, key, key_len, kind);
    if (common == 0) continue;
    if (common == child->key_len && common == key_len) return child;
    if (common == child->key_len) return insert_token(child, key + common, key_len - common, kind);
    if (common == key_len) return split_node(child, common);

    RadixNode *shared = split_node(child, common);
    RadixNode *sibling = new_node(key + common, key_len - common, kind);
    append_child(shared, sibling);
    sort_children(shared);
    return sibling;
  }

  RadixNode *child = new_node(key, key_len, kind);
  append_child(node, child);
  sort_children(node);
  return child;
}

RadixTree *radix_tree_new(void) {
  RadixTree *t = GC_MALLOC(sizeof(RadixTree));
  t->root = new_node("", 0, RADIX_NORMAL);
  return t;
}

void radix_tree_add(RadixTree *t, const char *key, size_t key_len, void *payload) {
  RadixNode *node = t->root;
  size_t i = 0;
  while (i < key_len) {
    size_t start = i;
    RadixKind kind;
    if (key[i] == ':') {
      kind = RADIX_NAMED;
      i++;
      while (i < key_len && key[i] != '/') i++;
    } else if (key[i] == '*') {
      kind = RADIX_GLOB;
      i = key_len;
    } else {
      kind = RADIX_NORMAL;
      i++;
      while (i < key_len && key[i] != ':' && key[i] != '*') i++;
    }
    node = insert_token(node, key + start, i - start, kind);
  }
  if (!node->payload) t->count++;
  node->payload = payload;
}

/* Depth-first, trying each node's children in their sorted (Normal <
 * Named < Glob) order; a Named/Glob attempt that leads to a dead end
 * further down backtracks (params written speculatively for that
 * attempt are rolled back via the saved `*n`) and the next sibling is
 * tried -- see this file's own header comment on why only one candidate
 * per kind bucket can ever byte-match a Normal chunk, so backtracking in
 * practice only matters across kind boundaries (or between same-named
 * siblings in the rare ambiguous-name case). */
static void *find_rec(RadixNode *node, const char *path, size_t path_len, RadixParam *out_params, int *n, int max_params) {
  if (path_len == 0) return node->payload;

  for (int i = 0; i < node->n_children; i++) {
    RadixNode *child = node->children[i];

    if (child->kind == RADIX_NORMAL) {
      if (child->key_len <= path_len && memcmp(child->key, path, child->key_len) == 0) {
        void *r = find_rec(child, path + child->key_len, path_len - child->key_len, out_params, n, max_params);
        if (r) return r;
      }
      continue;
    }

    if (child->kind == RADIX_NAMED) {
      size_t j = 0;
      while (j < path_len && path[j] != '/') j++;
      int saved_n = *n;
      if (*n < max_params) {
        out_params[*n].name = child->key + 1;
        out_params[*n].name_len = child->key_len - 1;
        out_params[*n].value = path;
        out_params[*n].value_len = j;
        (*n)++;
      }
      void *r = find_rec(child, path + j, path_len - j, out_params, n, max_params);
      if (r) return r;
      *n = saved_n;
      continue;
    }

    /* RADIX_GLOB: always consumes the entire remaining path in one shot. */
    int saved_n = *n;
    if (*n < max_params) {
      out_params[*n].name = child->key + 1;
      out_params[*n].name_len = child->key_len - 1;
      out_params[*n].value = path;
      out_params[*n].value_len = path_len;
      (*n)++;
    }
    void *r = find_rec(child, path + path_len, 0, out_params, n, max_params);
    if (r) return r;
    *n = saved_n;
  }
  return NULL;
}

void *radix_tree_find(RadixTree *t, const char *path, size_t path_len, RadixParam *out_params, int *out_nparams, int max_params) {
  int n = 0;
  void *payload = find_rec(t->root, path, path_len, out_params, &n, max_params);
  *out_nparams = n;
  return payload;
}

/* ---- (creme radix) Scheme builtins ----
 * `radix-tree` payloads are always Scheme Values, boxed the same way
 * mux.c boxes its own route handlers on top of this same core -- see
 * that file's own RouteHandler for the identical pattern with a
 * different payload shape. */
#include "builtin_config.h"

#if CREME_WITH_RADIX

#include "embed.h"

typedef struct {
  Value v;
} RadixValueBox;

static void *box_value(Value v) {
  RadixValueBox *b = GC_MALLOC(sizeof(RadixValueBox));
  b->v = v;
  return b;
}

static Value unbox_value(void *p) { return p ? ((RadixValueBox *)p)->v : v_bool(0); }

static RadixTree *as_radix_tree(Value v, const char *who) { return creme_arg_box(&v, 1, 0, BOX_KIND_RADIX_TREE, who); }

#define RADIX_MAX_PARAMS 64

static Value bi_radix_tree(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return v_box(radix_tree_new(), BOX_KIND_RADIX_TREE);
}

static Value bi_radix_tree_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "radix-tree?");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_RADIX_TREE);
}

static Value bi_radix_tree_set_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "radix-tree-set!");
  RadixTree *t = as_radix_tree(args[0], "radix-tree-set!");
  int patlen;
  const char *pattern = creme_arg_bytes(args, nargs, 1, "radix-tree-set!", &patlen);
  radix_tree_add(t, pattern, (size_t)patlen, box_value(args[2]));
  return v_nil();
}

static Value bi_radix_tree_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "radix-tree-ref");
  RadixTree *t = as_radix_tree(args[0], "radix-tree-ref");
  int pathlen;
  const char *path = creme_arg_bytes(args, nargs, 1, "radix-tree-ref", &pathlen);
  RadixParam params[RADIX_MAX_PARAMS];
  int nparams;
  void *payload = radix_tree_find(t, path, (size_t)pathlen, params, &nparams, RADIX_MAX_PARAMS);
  return unbox_value(payload);
}

static Value bi_radix_tree_match(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "radix-tree-match");
  RadixTree *t = as_radix_tree(args[0], "radix-tree-match");
  int pathlen;
  const char *path = creme_arg_bytes(args, nargs, 1, "radix-tree-match", &pathlen);
  RadixParam params[RADIX_MAX_PARAMS];
  int nparams;
  void *payload = radix_tree_find(t, path, (size_t)pathlen, params, &nparams, RADIX_MAX_PARAMS);
  if (!payload) return v_bool(0);

  Value params_alist = v_nil();
  for (int i = 0; i < nparams; i++) {
    Value name = creme_bytes_value(params[i].name, params[i].name_len);
    Value value = creme_bytes_value(params[i].value, params[i].value_len);
    params_alist = creme_cons(vm, creme_cons(vm, name, value), params_alist);
  }
  return creme_cons(vm, unbox_value(payload), params_alist);
}

static Value bi_radix_tree_count(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "radix-tree-count");
  RadixTree *t = as_radix_tree(args[0], "radix-tree-count");
  return v_int(t->count);
}

void creme_register_radix_builtins(VM *vm) {
  creme_register_builtin(vm, "radix-tree", bi_radix_tree);
  creme_register_builtin(vm, "radix-tree?", bi_radix_tree_p);
  creme_register_builtin(vm, "radix-tree-set!", bi_radix_tree_set_bang);
  creme_register_builtin(vm, "radix-tree-ref", bi_radix_tree_ref);
  creme_register_builtin(vm, "radix-tree-match", bi_radix_tree_match);
  creme_register_builtin(vm, "radix-tree-count", bi_radix_tree_count);
}

#endif /* CREME_WITH_RADIX */
