/* (creme treelist) — see treelist.h.
 *
 * A direct, line-for-line port of the RRB (Relaxed Radix Balanced) tree
 * engine in src/creme/modules/creme/treelist.cr (module Creme::RRB) --
 * every internal branch node carries a cumulative size table (i.e.
 * every node is "relaxed"), giving O(log n) ref/set/add/cons/insert/
 * delete/take/drop/concat without needing pure radix bit-masking. See
 * that file's own header comment for the algorithm-level design
 * rationale (rebalancing on concat, etc.) -- this file mirrors its
 * Leaf/Branch/mk_branch/node_ref/node_set/fast_push/fast_cons/
 * chunk_leaves/chunk_branches/rebalance/concat_sub/slice_node/
 * from_array/collect/concat_roots/canonical functions one-to-one, and
 * its Tree class's own ref/set/add/cons/concat/take/drop/sublist/
 * insert/delete/to_a/reverse methods as plain functions operating on an
 * RRBNode* root directly (root->size already carries what Tree#size
 * cached separately in Crystal, so no extra wrapper struct is needed).
 *
 * Unlike Crystal's persistent arrays (copy-on-slice, so every `.dup`/
 * range-slice in the original already allocates independently), C
 * arrays alias by default -- every function below therefore explicitly
 * copies any node/item array it's about to store into a new node,
 * rather than aliasing a caller's array, to preserve the same
 * persistent-immutability guarantee (an existing tree version must
 * never be observably mutated by a later operation).
 *
 * Value representation: an immutable treelist is a T_BOX (BOX_KIND_
 * TREELIST) wrapping an RRBNode* root directly. A mutable treelist is a
 * T_BOX (BOX_KIND_MUTABLE_TREELIST) wrapping a one-field
 * MutableTreelistState struct (so `!`-suffixed ops can reassign its
 * root in place, exactly like native's own SchemeMutableTreelist#tree=
 * -- see that class's own comment on why this makes mutable ops O(log n)
 * and mutable-treelist-snapshot O(1)).
 */
#include <gc.h>
#include <string.h>

#include "embed.h"
#include "treelist.h"

#define RRB_WIDTH 32

typedef struct RRBNode RRBNode;
struct RRBNode {
  int is_branch;
  int height;
  int size;
  /* leaf */
  Value *items;
  int n_items;
  /* branch */
  RRBNode **children;
  int *sizes; /* cumulative: sizes[i] = elements in children[0..i] */
  int n_children;
};

typedef struct {
  RRBNode *root;
} MutableTreelistState;

/* ---- small array-copy/concat helpers (see this file's own header
 * comment on why every array gets copied before being stored in a node) ---- */

static Value *value_array_copy(const Value *src, int n) {
  Value *dst = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  if (n) memcpy(dst, src, sizeof(Value) * (size_t)n);
  return dst;
}

static RRBNode **node_array_copy(RRBNode *const *src, int n) {
  RRBNode **dst = GC_MALLOC(sizeof(RRBNode *) * (size_t)(n ? n : 1));
  if (n) memcpy(dst, src, sizeof(RRBNode *) * (size_t)n);
  return dst;
}

static RRBNode **node_array_concat3(RRBNode *const *a, int na, RRBNode *const *b, int nb, RRBNode *const *c, int nc, int *out_n) {
  int n = na + nb + nc;
  RRBNode **res = GC_MALLOC(sizeof(RRBNode *) * (size_t)(n ? n : 1));
  int pos = 0;
  if (na) { memcpy(res + pos, a, sizeof(RRBNode *) * (size_t)na); pos += na; }
  if (nb) { memcpy(res + pos, b, sizeof(RRBNode *) * (size_t)nb); pos += nb; }
  if (nc) { memcpy(res + pos, c, sizeof(RRBNode *) * (size_t)nc); pos += nc; }
  *out_n = n;
  return res;
}

/* ---- node construction ---- */

static RRBNode *rrb_make_leaf(Value *items, int n) {
  RRBNode *node = GC_MALLOC(sizeof(RRBNode));
  node->is_branch = 0;
  node->height = 0;
  node->size = n;
  node->items = items;
  node->n_items = n;
  return node;
}

static int rrb_height_of(RRBNode *n) { return n->is_branch ? n->height : 0; }

static RRBNode *rrb_as_branch(RRBNode *n) {
  if (!n->is_branch) creme_abort("RRB: expected a branch node");
  return n;
}

/* Build a branch from same-height children (already a fresh, owned
 * array -- callers copy before calling this), computing its size table. */
static RRBNode *rrb_mk_branch(RRBNode **children, int n) {
  RRBNode *node = GC_MALLOC(sizeof(RRBNode));
  node->is_branch = 1;
  node->height = rrb_height_of(children[0]) + 1;
  node->children = children;
  node->n_children = n;
  node->sizes = GC_MALLOC(sizeof(int) * (size_t)(n ? n : 1));
  int acc = 0;
  for (int i = 0; i < n; i++) {
    acc += children[i]->size;
    node->sizes[i] = acc;
  }
  node->size = n ? node->sizes[n - 1] : 0;
  return node;
}

static RRBNode *rrb_empty_leaf(void) { return rrb_make_leaf(GC_MALLOC(1), 0); }

static Value rrb_node_ref(RRBNode *node, int index) {
  for (;;) {
    if (!node->is_branch) return node->items[index];
    int i = 0;
    while (node->sizes[i] <= index) i++;
    if (i > 0) index -= node->sizes[i - 1];
    node = node->children[i];
  }
}

static RRBNode *rrb_node_set(RRBNode *node, int index, Value v) {
  if (!node->is_branch) {
    Value *items = value_array_copy(node->items, node->n_items);
    items[index] = v;
    return rrb_make_leaf(items, node->n_items);
  }
  int i = 0;
  while (node->sizes[i] <= index) i++;
  int prev = i > 0 ? node->sizes[i - 1] : 0;
  RRBNode **children = node_array_copy(node->children, node->n_children);
  children[i] = rrb_node_set(children[i], index - prev, v);
  RRBNode *result = GC_MALLOC(sizeof(RRBNode));
  result->is_branch = 1;
  result->height = node->height;
  result->children = children;
  result->n_children = node->n_children;
  result->sizes = GC_MALLOC(sizeof(int) * (size_t)node->n_children);
  memcpy(result->sizes, node->sizes, sizeof(int) * (size_t)node->n_children);
  result->size = node->size;
  return result;
}

/* Fast rightmost append; returns NULL if the rightmost leaf is full. */
static RRBNode *rrb_fast_push(RRBNode *node, Value v) {
  if (!node->is_branch) {
    if (node->n_items >= RRB_WIDTH) return NULL;
    Value *items = GC_MALLOC(sizeof(Value) * (size_t)(node->n_items + 1));
    if (node->n_items) memcpy(items, node->items, sizeof(Value) * (size_t)node->n_items);
    items[node->n_items] = v;
    return rrb_make_leaf(items, node->n_items + 1);
  }
  RRBNode *child = rrb_fast_push(node->children[node->n_children - 1], v);
  if (!child) return NULL;
  RRBNode **children = node_array_copy(node->children, node->n_children);
  children[node->n_children - 1] = child;
  int *sizes = GC_MALLOC(sizeof(int) * (size_t)node->n_children);
  memcpy(sizes, node->sizes, sizeof(int) * (size_t)node->n_children);
  sizes[node->n_children - 1] += 1;
  RRBNode *result = GC_MALLOC(sizeof(RRBNode));
  result->is_branch = 1;
  result->height = node->height;
  result->children = children;
  result->n_children = node->n_children;
  result->sizes = sizes;
  result->size = node->size + 1;
  return result;
}

/* Fast leftmost prepend; returns NULL if the leftmost leaf is full. */
static RRBNode *rrb_fast_cons(RRBNode *node, Value v) {
  if (!node->is_branch) {
    if (node->n_items >= RRB_WIDTH) return NULL;
    Value *items = GC_MALLOC(sizeof(Value) * (size_t)(node->n_items + 1));
    items[0] = v;
    if (node->n_items) memcpy(items + 1, node->items, sizeof(Value) * (size_t)node->n_items);
    return rrb_make_leaf(items, node->n_items + 1);
  }
  RRBNode *child = rrb_fast_cons(node->children[0], v);
  if (!child) return NULL;
  RRBNode **children = node_array_copy(node->children, node->n_children);
  children[0] = child;
  int *sizes = GC_MALLOC(sizeof(int) * (size_t)node->n_children);
  for (int i = 0; i < node->n_children; i++) sizes[i] = node->sizes[i] + 1;
  RRBNode *result = GC_MALLOC(sizeof(RRBNode));
  result->is_branch = 1;
  result->height = node->height;
  result->children = children;
  result->n_children = node->n_children;
  result->sizes = sizes;
  result->size = node->size + 1;
  return result;
}

static RRBNode **rrb_chunk_leaves(Value *items, int n, int *out_count) {
  int cap = (n + RRB_WIDTH - 1) / RRB_WIDTH;
  RRBNode **res = GC_MALLOC(sizeof(RRBNode *) * (size_t)(cap ? cap : 1));
  int c = 0, i = 0;
  while (i < n) {
    int chunk_n = n - i < RRB_WIDTH ? n - i : RRB_WIDTH;
    res[c++] = rrb_make_leaf(value_array_copy(items + i, chunk_n), chunk_n);
    i += RRB_WIDTH;
  }
  *out_count = c;
  return res;
}

static RRBNode **rrb_chunk_branches(RRBNode **kids, int n, int *out_count) {
  int cap = (n + RRB_WIDTH - 1) / RRB_WIDTH;
  RRBNode **res = GC_MALLOC(sizeof(RRBNode *) * (size_t)(cap ? cap : 1));
  int c = 0, i = 0;
  while (i < n) {
    int chunk_n = n - i < RRB_WIDTH ? n - i : RRB_WIDTH;
    res[c++] = rrb_mk_branch(node_array_copy(kids + i, chunk_n), chunk_n);
    i += RRB_WIDTH;
  }
  *out_count = c;
  return res;
}

/* Repack the grandchildren of `merged` (nodes at height `ml`) into full
 * WIDTH-sized nodes, then group them under a branch at height ml+2 with
 * 1 or 2 children (at height ml+1) -- the shape concat_sub expects back. */
static RRBNode *rrb_rebalance(RRBNode **merged, int n_merged, int ml) {
  RRBNode **new_nodes;
  int new_n;
  if (ml == 0) {
    int total = 0;
    for (int i = 0; i < n_merged; i++) total += merged[i]->n_items;
    Value *items = GC_MALLOC(sizeof(Value) * (size_t)(total ? total : 1));
    int pos = 0;
    for (int i = 0; i < n_merged; i++) {
      if (merged[i]->n_items) memcpy(items + pos, merged[i]->items, sizeof(Value) * (size_t)merged[i]->n_items);
      pos += merged[i]->n_items;
    }
    new_nodes = rrb_chunk_leaves(items, total, &new_n);
  } else {
    int total = 0;
    for (int i = 0; i < n_merged; i++) total += merged[i]->n_children;
    RRBNode **kids = GC_MALLOC(sizeof(RRBNode *) * (size_t)(total ? total : 1));
    int pos = 0;
    for (int i = 0; i < n_merged; i++) {
      if (merged[i]->n_children) memcpy(kids + pos, merged[i]->children, sizeof(RRBNode *) * (size_t)merged[i]->n_children);
      pos += merged[i]->n_children;
    }
    new_nodes = rrb_chunk_branches(kids, total, &new_n);
  }

  if (new_n <= RRB_WIDTH) {
    RRBNode *inner = rrb_mk_branch(node_array_copy(new_nodes, new_n), new_n);
    RRBNode **wrap = GC_MALLOC(sizeof(RRBNode *));
    wrap[0] = inner;
    return rrb_mk_branch(wrap, 1);
  }
  RRBNode *a = rrb_mk_branch(node_array_copy(new_nodes, RRB_WIDTH), RRB_WIDTH);
  int rest_n = new_n - RRB_WIDTH;
  RRBNode *b = rrb_mk_branch(node_array_copy(new_nodes + RRB_WIDTH, rest_n), rest_n);
  RRBNode **pair = GC_MALLOC(sizeof(RRBNode *) * 2);
  pair[0] = a;
  pair[1] = b;
  return rrb_mk_branch(pair, 2);
}

/* Concatenate two nodes; returns a branch one level above max(height)
 * with 1 or 2 children (already rebalanced) -- ALWAYS a branch, never a
 * bare leaf, matching native's own Branch-typed return. */
static RRBNode *rrb_concat_sub(RRBNode *left, RRBNode *right) {
  int hl = rrb_height_of(left), hr = rrb_height_of(right);

  if (hl == hr) {
    if (!left->is_branch && !right->is_branch) {
      int total = left->n_items + right->n_items;
      Value *combined = GC_MALLOC(sizeof(Value) * (size_t)(total ? total : 1));
      if (left->n_items) memcpy(combined, left->items, sizeof(Value) * (size_t)left->n_items);
      if (right->n_items) memcpy(combined + left->n_items, right->items, sizeof(Value) * (size_t)right->n_items);
      if (total <= RRB_WIDTH) {
        RRBNode **wrap = GC_MALLOC(sizeof(RRBNode *));
        wrap[0] = rrb_make_leaf(combined, total);
        return rrb_mk_branch(wrap, 1);
      }
      RRBNode **pair = GC_MALLOC(sizeof(RRBNode *) * 2);
      pair[0] = rrb_make_leaf(value_array_copy(combined, RRB_WIDTH), RRB_WIDTH);
      pair[1] = rrb_make_leaf(value_array_copy(combined + RRB_WIDTH, total - RRB_WIDTH), total - RRB_WIDTH);
      return rrb_mk_branch(pair, 2);
    }
    RRBNode *lb = rrb_as_branch(left);
    RRBNode *rb = rrb_as_branch(right);
    RRBNode *mid = rrb_concat_sub(lb->children[lb->n_children - 1], rb->children[0]);
    int out_n;
    RRBNode **merged = node_array_concat3(lb->children, lb->n_children - 1, mid->children, mid->n_children, rb->children + 1, rb->n_children - 1, &out_n);
    return rrb_rebalance(merged, out_n, hl - 1);
  }
  if (hl > hr) {
    RRBNode *lb = rrb_as_branch(left);
    RRBNode *mid = rrb_concat_sub(lb->children[lb->n_children - 1], right);
    int out_n;
    RRBNode **merged = node_array_concat3(lb->children, lb->n_children - 1, mid->children, mid->n_children, NULL, 0, &out_n);
    return rrb_rebalance(merged, out_n, hl - 1);
  }
  RRBNode *rb = rrb_as_branch(right);
  RRBNode *mid = rrb_concat_sub(left, rb->children[0]);
  int out_n;
  RRBNode **merged = node_array_concat3(mid->children, mid->n_children, rb->children + 1, rb->n_children - 1, NULL, 0, &out_n);
  return rrb_rebalance(merged, out_n, hr - 1);
}

static RRBNode *rrb_concat_roots(RRBNode *left, RRBNode *right) {
  RRBNode *top = rrb_concat_sub(left, right);
  return top->n_children == 1 ? top->children[0] : top;
}

/* Strip redundant single-child branch roots left behind by slicing. */
static RRBNode *rrb_canonical(RRBNode *node) {
  while (node->is_branch && node->n_children == 1) node = node->children[0];
  return node;
}

/* Extract elements [from, to) from `node`, preserving its height. */
static RRBNode *rrb_slice_node(RRBNode *node, int from, int to) {
  if (!node->is_branch) {
    int n = to - from;
    return rrb_make_leaf(value_array_copy(node->items + from, n), n);
  }
  RRBNode **result = GC_MALLOC(sizeof(RRBNode *) * (size_t)(node->n_children ? node->n_children : 1));
  int rn = 0, lo = 0;
  for (int i = 0; i < node->n_children; i++) {
    RRBNode *child = node->children[i];
    int hi = lo + child->size;
    int a = from > lo ? from : lo;
    int b = to < hi ? to : hi;
    if (a < b) result[rn++] = (a == lo && b == hi) ? child : rrb_slice_node(child, a - lo, b - lo);
    lo = hi;
    if (lo >= to) break;
  }
  return rrb_mk_branch(result, rn);
}

/* Bulk-load a balanced tree from an array. O(n). */
static RRBNode *rrb_from_array(Value *items, int n) {
  if (n == 0) return rrb_empty_leaf();
  int cnt;
  RRBNode **nodes = rrb_chunk_leaves(items, n, &cnt);
  while (cnt > 1) {
    int new_cnt;
    nodes = rrb_chunk_branches(nodes, cnt, &new_cnt);
    cnt = new_cnt;
  }
  return nodes[0];
}

static void rrb_collect(RRBNode *node, Value *out, int *pos) {
  if (!node->is_branch) {
    if (node->n_items) memcpy(out + *pos, node->items, sizeof(Value) * (size_t)node->n_items);
    *pos += node->n_items;
    return;
  }
  for (int i = 0; i < node->n_children; i++) rrb_collect(node->children[i], out, pos);
}

static Value *rrb_to_array(RRBNode *root) {
  Value *out = GC_MALLOC(sizeof(Value) * (size_t)(root->size ? root->size : 1));
  int pos = 0;
  rrb_collect(root, out, &pos);
  return out;
}

/* ---- Tree-level ops (mirrors Creme::RRB::Tree's own methods, one to
 * one, operating directly on an RRBNode* root -- root->size already IS
 * Tree#size, no separate wrapper needed) ---- */

static RRBNode *tree_add(RRBNode *root, Value v) {
  RRBNode *nr = rrb_fast_push(root, v);
  if (nr) return nr;
  Value *single = value_array_copy(&v, 1);
  return rrb_concat_roots(root, rrb_make_leaf(single, 1));
}

static RRBNode *tree_cons(RRBNode *root, Value v) {
  RRBNode *nr = rrb_fast_cons(root, v);
  if (nr) return nr;
  Value *single = value_array_copy(&v, 1);
  return rrb_concat_roots(rrb_make_leaf(single, 1), root);
}

static RRBNode *tree_concat(RRBNode *a, RRBNode *b) {
  if (a->size == 0) return b;
  if (b->size == 0) return a;
  return rrb_concat_roots(a, b);
}

static RRBNode *tree_take(RRBNode *root, int n) {
  if (n <= 0) return rrb_empty_leaf();
  if (n >= root->size) return root;
  return rrb_canonical(rrb_slice_node(root, 0, n));
}

static RRBNode *tree_drop(RRBNode *root, int n) {
  if (n <= 0) return root;
  if (n >= root->size) return rrb_empty_leaf();
  return rrb_canonical(rrb_slice_node(root, n, root->size));
}

static RRBNode *tree_sublist(RRBNode *root, int from, int to) {
  return tree_drop(tree_take(root, to), from);
}

static RRBNode *tree_insert(RRBNode *root, int i, Value v) {
  if (i <= 0) return tree_cons(root, v);
  if (i >= root->size) return tree_add(root, v);
  RRBNode *mid = rrb_make_leaf(value_array_copy(&v, 1), 1);
  return tree_concat(tree_concat(tree_take(root, i), mid), tree_drop(root, i));
}

static RRBNode *tree_delete(RRBNode *root, int i) {
  return tree_concat(tree_take(root, i), tree_drop(root, i + 1));
}

static RRBNode *tree_reverse(RRBNode *root) {
  Value *arr = rrb_to_array(root);
  int n = root->size;
  Value *rev = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  for (int i = 0; i < n; i++) rev[i] = arr[n - 1 - i];
  return rrb_from_array(rev, n);
}

/* ---- Value wrapping / argument helpers ---- */

static Value v_treelist(RRBNode *root) { return v_box(root, BOX_KIND_TREELIST); }
static Value v_mutable_treelist(RRBNode *root) {
  MutableTreelistState *m = GC_MALLOC(sizeof(MutableTreelistState));
  m->root = root;
  return v_box(m, BOX_KIND_MUTABLE_TREELIST);
}

static RRBNode *tl_arg(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_TREELIST, who);
}

static MutableTreelistState *mtl_arg(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_MUTABLE_TREELIST, who);
}

static RRBNode *any_tree_arg(Value v, const char *who) {
  if (v.tag == T_BOX && v.aux == BOX_KIND_TREELIST) return (RRBNode *)v.as.ptr;
  if (v.tag == T_BOX && v.aux == BOX_KIND_MUTABLE_TREELIST) return ((MutableTreelistState *)v.as.ptr)->root;
  creme_abort("%s: expected a treelist", who);
}

static int tl_size_arg(Value v, const char *who) {
  if (v.tag != T_INT || v.as.i < 0) creme_abort("%s: size must be a non-negative integer", who);
  return (int)v.as.i;
}

/* Index that must be within [0, size). */
static int tl_bounds(Value v, int size, const char *who) {
  if (v.tag != T_INT) creme_abort("%s: expected an integer index", who);
  int64_t i = v.as.i;
  if (i < 0 || i >= size) creme_abort("%s: index out of range for treelist of length %d", who, size);
  return (int)i;
}

/* Position that must be within [0, size] (insertion/boundary). */
static int tl_bounds_incl(Value v, int size, const char *who) {
  if (v.tag != T_INT) creme_abort("%s: expected an integer position", who);
  int64_t i = v.as.i;
  if (i < 0 || i > size) creme_abort("%s: position out of range for treelist of length %d", who, size);
  return (int)i;
}

/* Count that must be within [0, size] (take/drop lengths). */
static int tl_count(Value v, int size, const char *who) {
  if (v.tag != T_INT) creme_abort("%s: expected an integer count", who);
  int64_t i = v.as.i;
  if (i < 0 || i > size) creme_abort("%s: count out of range for treelist of length %d", who, size);
  return (int)i;
}

static int find_index(VM *vm, RRBNode *root, Value needle, Value *eql) {
  Value *arr = rrb_to_array(root);
  int n = root->size;
  for (int i = 0; i < n; i++) {
    int match;
    if (eql) {
      Value call_args[2];
      call_args[0] = needle;
      call_args[1] = arr[i];
      Value result = creme_apply(vm, *eql, call_args, 2);
      match = !v_falsy(result);
    } else {
      match = creme_equal(needle, arr[i]);
    }
    if (match) return i;
  }
  return -1;
}

/* ---- immutable treelist builtins ---- */

static Value bi_treelist(VM *vm, Value *args, int nargs) {
  (void)vm;
  return v_treelist(rrb_from_array(value_array_copy(args, nargs), nargs));
}

static Value bi_make_treelist(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "make-treelist");
  int n = tl_size_arg(args[0], "make-treelist");
  Value *items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  for (int i = 0; i < n; i++) items[i] = args[1];
  return v_treelist(rrb_from_array(items, n));
}

static Value *list_to_value_array(Value list, int *out_n) {
  int n = 0;
  Value cur = list;
  while (cur.tag == T_PAIR) { n++; cur = cur.as.pair->cdr; }
  Value *arr = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  cur = list;
  for (int i = 0; i < n; i++) { arr[i] = cur.as.pair->car; cur = cur.as.pair->cdr; }
  *out_n = n;
  return arr;
}

static Value bi_list_to_treelist(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "list->treelist");
  int n;
  Value *arr = list_to_value_array(args[0], &n);
  return v_treelist(rrb_from_array(arr, n));
}

static Value bi_treelist_to_list(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "treelist->list");
  RRBNode *root = tl_arg(args[0], "treelist->list");
  Value *arr = rrb_to_array(root);
  Value r = v_nil();
  for (int i = root->size - 1; i >= 0; i--) r = creme_cons(vm, arr[i], r);
  return r;
}

static Value bi_vector_to_treelist(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_VECTOR) creme_abort("vector->treelist: expected a vector");
  Vector *vec = args[0].as.vec;
  return v_treelist(rrb_from_array(value_array_copy(vec->items, vec->len), vec->len));
}

static Value bi_treelist_to_vector(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "treelist->vector");
  RRBNode *root = tl_arg(args[0], "treelist->vector");
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = root->size;
  vec->items = rrb_to_array(root);
  return v_vector(vec);
}

static Value bi_treelist_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "treelist?");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_TREELIST);
}

static Value bi_treelist_empty_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "treelist-empty?");
  return v_bool(tl_arg(args[0], "treelist-empty?")->size == 0);
}

static Value bi_treelist_length(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "treelist-length");
  return v_int(tl_arg(args[0], "treelist-length")->size);
}

static Value bi_treelist_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "treelist-ref");
  RRBNode *t = tl_arg(args[0], "treelist-ref");
  return rrb_node_ref(t, tl_bounds(args[1], t->size, "treelist-ref"));
}

static Value bi_treelist_first(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "treelist-first");
  RRBNode *t = tl_arg(args[0], "treelist-first");
  if (t->size == 0) creme_abort("treelist-first: empty treelist");
  return rrb_node_ref(t, 0);
}

static Value bi_treelist_last(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "treelist-last");
  RRBNode *t = tl_arg(args[0], "treelist-last");
  if (t->size == 0) creme_abort("treelist-last: empty treelist");
  return rrb_node_ref(t, t->size - 1);
}

static Value bi_treelist_add(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "treelist-add");
  return v_treelist(tree_add(tl_arg(args[0], "treelist-add"), args[1]));
}

static Value bi_treelist_cons(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "treelist-cons");
  return v_treelist(tree_cons(tl_arg(args[0], "treelist-cons"), args[1]));
}

static Value bi_treelist_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "treelist-set");
  RRBNode *t = tl_arg(args[0], "treelist-set");
  return v_treelist(rrb_node_set(t, tl_bounds(args[1], t->size, "treelist-set"), args[2]));
}

static Value bi_treelist_insert(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "treelist-insert");
  RRBNode *t = tl_arg(args[0], "treelist-insert");
  return v_treelist(tree_insert(t, tl_bounds_incl(args[1], t->size, "treelist-insert"), args[2]));
}

static Value bi_treelist_delete(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "treelist-delete");
  RRBNode *t = tl_arg(args[0], "treelist-delete");
  return v_treelist(tree_delete(t, tl_bounds(args[1], t->size, "treelist-delete")));
}

static Value bi_treelist_take(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "treelist-take");
  RRBNode *t = tl_arg(args[0], "treelist-take");
  return v_treelist(tree_take(t, tl_count(args[1], t->size, "treelist-take")));
}

static Value bi_treelist_drop(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "treelist-drop");
  RRBNode *t = tl_arg(args[0], "treelist-drop");
  return v_treelist(tree_drop(t, tl_count(args[1], t->size, "treelist-drop")));
}

static Value bi_treelist_take_right(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "treelist-take-right");
  RRBNode *t = tl_arg(args[0], "treelist-take-right");
  int n = tl_count(args[1], t->size, "treelist-take-right");
  return v_treelist(tree_drop(t, t->size - n));
}

static Value bi_treelist_drop_right(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "treelist-drop-right");
  RRBNode *t = tl_arg(args[0], "treelist-drop-right");
  int n = tl_count(args[1], t->size, "treelist-drop-right");
  return v_treelist(tree_take(t, t->size - n));
}

static Value bi_treelist_sublist(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "treelist-sublist");
  RRBNode *t = tl_arg(args[0], "treelist-sublist");
  int from = tl_count(args[1], t->size, "treelist-sublist");
  int to = tl_count(args[2], t->size, "treelist-sublist");
  if (from > to) creme_abort("treelist-sublist: bad range");
  return v_treelist(tree_sublist(t, from, to));
}

static Value bi_treelist_rest(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "treelist-rest");
  RRBNode *t = tl_arg(args[0], "treelist-rest");
  if (t->size == 0) creme_abort("treelist-rest: empty treelist");
  return v_treelist(tree_drop(t, 1));
}

static Value bi_treelist_append(VM *vm, Value *args, int nargs) {
  (void)vm;
  RRBNode *acc = rrb_empty_leaf();
  for (int i = 0; i < nargs; i++) acc = tree_concat(acc, tl_arg(args[i], "treelist-append"));
  return v_treelist(acc);
}

static Value bi_treelist_reverse(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "treelist-reverse");
  return v_treelist(tree_reverse(tl_arg(args[0], "treelist-reverse")));
}

static Value bi_treelist_map(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "treelist-map");
  RRBNode *t = tl_arg(args[0], "treelist-map");
  Value *arr = rrb_to_array(t);
  Value *mapped = GC_MALLOC(sizeof(Value) * (size_t)(t->size ? t->size : 1));
  for (int i = 0; i < t->size; i++) mapped[i] = creme_apply(vm, args[1], arr + i, 1);
  return v_treelist(rrb_from_array(mapped, t->size));
}

/* treelist-filter's argument order is (proc, treelist) -- the REVERSE of
 * treelist-map/-for-each/-sort/-find's (treelist, proc) -- matching
 * native's own arg order exactly (base treelist.cr's own
 * treelist_filter: `keep = proc_arg(args[0]...); t = tl_arg(args[1]...)`). */
static Value bi_treelist_filter(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "treelist-filter");
  RRBNode *t = tl_arg(args[1], "treelist-filter");
  Value *arr = rrb_to_array(t);
  Value *kept = GC_MALLOC(sizeof(Value) * (size_t)(t->size ? t->size : 1));
  int n = 0;
  for (int i = 0; i < t->size; i++) {
    if (!v_falsy(creme_apply(vm, args[0], arr + i, 1))) kept[n++] = arr[i];
  }
  return v_treelist(rrb_from_array(kept, n));
}

static Value bi_treelist_for_each(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "treelist-for-each");
  RRBNode *t = tl_arg(args[0], "treelist-for-each");
  Value *arr = rrb_to_array(t);
  for (int i = 0; i < t->size; i++) creme_apply(vm, args[1], arr + i, 1);
  return v_nil();
}

/* Insertion sort by proc's own "less" comparator -- O(n^2), matching
 * this file's overall "correctness over asymptotics for higher-order
 * ops" scope (unlike ref/set/add/take/drop/concat, which DO preserve
 * the RRB tree's O(log n) guarantees). native itself just calls
 * Crystal's own Array#sort (a real O(n log n) sort); this prototype's
 * simpler insertion sort is a deliberate, narrower cut. */
static void tl_insertion_sort(VM *vm, Value *arr, int n, Value less) {
  for (int i = 1; i < n; i++) {
    Value key = arr[i];
    int j = i - 1;
    while (j >= 0) {
      Value cmp_args[2];
      cmp_args[0] = key;
      cmp_args[1] = arr[j];
      if (v_falsy(creme_apply(vm, less, cmp_args, 2))) break;
      arr[j + 1] = arr[j];
      j--;
    }
    arr[j + 1] = key;
  }
}

static Value bi_treelist_sort(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "treelist-sort");
  RRBNode *t = tl_arg(args[0], "treelist-sort");
  Value *arr = value_array_copy(rrb_to_array(t), t->size);
  tl_insertion_sort(vm, arr, t->size, args[1]);
  return v_treelist(rrb_from_array(arr, t->size));
}

static Value bi_treelist_member_p(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "treelist-member?");
  RRBNode *t = tl_arg(args[0], "treelist-member?");
  Value *eql = nargs >= 3 ? &args[2] : NULL;
  return v_bool(find_index(vm, t, args[1], eql) >= 0);
}

static Value bi_treelist_index_of(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "treelist-index-of");
  RRBNode *t = tl_arg(args[0], "treelist-index-of");
  Value *eql = nargs >= 3 ? &args[2] : NULL;
  int idx = find_index(vm, t, args[1], eql);
  return idx >= 0 ? v_int(idx) : v_bool(0);
}

static Value bi_treelist_find(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "treelist-find");
  RRBNode *t = tl_arg(args[0], "treelist-find");
  Value *arr = rrb_to_array(t);
  for (int i = 0; i < t->size; i++) {
    if (!v_falsy(creme_apply(vm, args[1], arr + i, 1))) return arr[i];
  }
  return v_bool(0);
}

/* ---- mutable treelist builtins ---- */

static Value bi_mutable_treelist(VM *vm, Value *args, int nargs) {
  (void)vm;
  return v_mutable_treelist(rrb_from_array(value_array_copy(args, nargs), nargs));
}

static Value bi_make_mutable_treelist(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "make-mutable-treelist");
  int n = tl_size_arg(args[0], "make-mutable-treelist");
  Value fill = nargs >= 2 ? args[1] : v_bool(0);
  Value *items = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  for (int i = 0; i < n; i++) items[i] = fill;
  return v_mutable_treelist(rrb_from_array(items, n));
}

static Value bi_list_to_mutable_treelist(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "list->mutable-treelist");
  int n;
  Value *arr = list_to_value_array(args[0], &n);
  return v_mutable_treelist(rrb_from_array(arr, n));
}

static Value bi_vector_to_mutable_treelist(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_VECTOR) creme_abort("vector->mutable-treelist: expected a vector");
  Vector *vec = args[0].as.vec;
  return v_mutable_treelist(rrb_from_array(value_array_copy(vec->items, vec->len), vec->len));
}

/* (treelist-copy t): a MUTABLE copy of an immutable treelist -- safe to
 * share the same root (persistent/immutable), matching native exactly. */
static Value bi_treelist_copy(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "treelist-copy");
  return v_mutable_treelist(tl_arg(args[0], "treelist-copy"));
}

static Value bi_mutable_treelist_copy(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mutable-treelist-copy");
  return v_mutable_treelist(mtl_arg(args[0], "mutable-treelist-copy")->root);
}

static Value bi_mutable_treelist_snapshot(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mutable-treelist-snapshot");
  return v_treelist(mtl_arg(args[0], "mutable-treelist-snapshot")->root);
}

static Value bi_mutable_treelist_to_list(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "mutable-treelist->list");
  RRBNode *root = mtl_arg(args[0], "mutable-treelist->list")->root;
  Value *arr = rrb_to_array(root);
  Value r = v_nil();
  for (int i = root->size - 1; i >= 0; i--) r = creme_cons(vm, arr[i], r);
  return r;
}

static Value bi_mutable_treelist_to_vector(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mutable-treelist->vector");
  RRBNode *root = mtl_arg(args[0], "mutable-treelist->vector")->root;
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->len = root->size;
  vec->items = rrb_to_array(root);
  return v_vector(vec);
}

static Value bi_mutable_treelist_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mutable-treelist?");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_MUTABLE_TREELIST);
}

static Value bi_mutable_treelist_empty_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mutable-treelist-empty?");
  return v_bool(mtl_arg(args[0], "mutable-treelist-empty?")->root->size == 0);
}

static Value bi_mutable_treelist_length(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mutable-treelist-length");
  return v_int(mtl_arg(args[0], "mutable-treelist-length")->root->size);
}

static Value bi_mutable_treelist_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mutable-treelist-ref");
  RRBNode *t = mtl_arg(args[0], "mutable-treelist-ref")->root;
  return rrb_node_ref(t, tl_bounds(args[1], t->size, "mutable-treelist-ref"));
}

static Value bi_mutable_treelist_first(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mutable-treelist-first");
  RRBNode *t = mtl_arg(args[0], "mutable-treelist-first")->root;
  if (t->size == 0) creme_abort("mutable-treelist-first: empty treelist");
  return rrb_node_ref(t, 0);
}

static Value bi_mutable_treelist_last(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mutable-treelist-last");
  RRBNode *t = mtl_arg(args[0], "mutable-treelist-last")->root;
  if (t->size == 0) creme_abort("mutable-treelist-last: empty treelist");
  return rrb_node_ref(t, t->size - 1);
}

static Value bi_mutable_treelist_add_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mutable-treelist-add!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-add!");
  m->root = tree_add(m->root, args[1]);
  return v_nil();
}

static Value bi_mutable_treelist_cons_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mutable-treelist-cons!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-cons!");
  m->root = tree_cons(m->root, args[1]);
  return v_nil();
}

static Value bi_mutable_treelist_set_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "mutable-treelist-set!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-set!");
  m->root = rrb_node_set(m->root, tl_bounds(args[1], m->root->size, "mutable-treelist-set!"), args[2]);
  return v_nil();
}

static Value bi_mutable_treelist_insert_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "mutable-treelist-insert!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-insert!");
  m->root = tree_insert(m->root, tl_bounds_incl(args[1], m->root->size, "mutable-treelist-insert!"), args[2]);
  return v_nil();
}

static Value bi_mutable_treelist_delete_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mutable-treelist-delete!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-delete!");
  m->root = tree_delete(m->root, tl_bounds(args[1], m->root->size, "mutable-treelist-delete!"));
  return v_nil();
}

static Value bi_mutable_treelist_append_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mutable-treelist-append!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-append!");
  m->root = tree_concat(m->root, any_tree_arg(args[1], "mutable-treelist-append!"));
  return v_nil();
}

static Value bi_mutable_treelist_prepend_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mutable-treelist-prepend!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-prepend!");
  m->root = tree_concat(any_tree_arg(args[1], "mutable-treelist-prepend!"), m->root);
  return v_nil();
}

static Value bi_mutable_treelist_take_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mutable-treelist-take!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-take!");
  m->root = tree_take(m->root, tl_count(args[1], m->root->size, "mutable-treelist-take!"));
  return v_nil();
}

static Value bi_mutable_treelist_drop_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mutable-treelist-drop!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-drop!");
  m->root = tree_drop(m->root, tl_count(args[1], m->root->size, "mutable-treelist-drop!"));
  return v_nil();
}

static Value bi_mutable_treelist_take_right_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mutable-treelist-take-right!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-take-right!");
  int n = tl_count(args[1], m->root->size, "mutable-treelist-take-right!");
  m->root = tree_drop(m->root, m->root->size - n);
  return v_nil();
}

static Value bi_mutable_treelist_drop_right_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mutable-treelist-drop-right!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-drop-right!");
  int n = tl_count(args[1], m->root->size, "mutable-treelist-drop-right!");
  m->root = tree_take(m->root, m->root->size - n);
  return v_nil();
}

static Value bi_mutable_treelist_sublist_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "mutable-treelist-sublist!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-sublist!");
  int from = tl_count(args[1], m->root->size, "mutable-treelist-sublist!");
  int to = tl_count(args[2], m->root->size, "mutable-treelist-sublist!");
  if (from > to) creme_abort("mutable-treelist-sublist!: bad range");
  m->root = tree_sublist(m->root, from, to);
  return v_nil();
}

static Value bi_mutable_treelist_reverse_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mutable-treelist-reverse!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-reverse!");
  m->root = tree_reverse(m->root);
  return v_nil();
}

static Value bi_mutable_treelist_map_bang(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "mutable-treelist-map!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-map!");
  Value *arr = rrb_to_array(m->root);
  int n = m->root->size;
  Value *mapped = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  for (int i = 0; i < n; i++) mapped[i] = creme_apply(vm, args[1], arr + i, 1);
  m->root = rrb_from_array(mapped, n);
  return v_nil();
}

static Value bi_mutable_treelist_sort_bang(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "mutable-treelist-sort!");
  MutableTreelistState *m = mtl_arg(args[0], "mutable-treelist-sort!");
  Value *arr = value_array_copy(rrb_to_array(m->root), m->root->size);
  tl_insertion_sort(vm, arr, m->root->size, args[1]);
  m->root = rrb_from_array(arr, m->root->size);
  return v_nil();
}

/* NOTE: no trailing `!` -- matches native's own name exactly (a
 * read-only traversal, so it's not a destructive op despite living
 * alongside the `!`-suffixed mutable ops here). */
static Value bi_mutable_treelist_for_each(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "mutable-treelist-for-each");
  RRBNode *t = mtl_arg(args[0], "mutable-treelist-for-each")->root;
  Value *arr = rrb_to_array(t);
  for (int i = 0; i < t->size; i++) creme_apply(vm, args[1], arr + i, 1);
  return v_nil();
}

static Value bi_mutable_treelist_member_p(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "mutable-treelist-member?");
  RRBNode *t = mtl_arg(args[0], "mutable-treelist-member?")->root;
  Value *eql = nargs >= 3 ? &args[2] : NULL;
  return v_bool(find_index(vm, t, args[1], eql) >= 0);
}

static Value bi_mutable_treelist_find(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "mutable-treelist-find");
  RRBNode *t = mtl_arg(args[0], "mutable-treelist-find")->root;
  Value *arr = rrb_to_array(t);
  for (int i = 0; i < t->size; i++) {
    if (!v_falsy(creme_apply(vm, args[1], arr + i, 1))) return arr[i];
  }
  return v_bool(0);
}

void creme_register_treelist_builtins(VM *vm) {
  creme_register_builtin(vm, "treelist", bi_treelist);
  creme_register_builtin(vm, "make-treelist", bi_make_treelist);
  creme_register_builtin(vm, "list->treelist", bi_list_to_treelist);
  creme_register_builtin(vm, "treelist->list", bi_treelist_to_list);
  creme_register_builtin(vm, "vector->treelist", bi_vector_to_treelist);
  creme_register_builtin(vm, "treelist->vector", bi_treelist_to_vector);
  creme_register_builtin(vm, "treelist?", bi_treelist_p);
  creme_register_builtin(vm, "treelist-empty?", bi_treelist_empty_p);
  creme_register_builtin(vm, "treelist-length", bi_treelist_length);
  creme_register_builtin(vm, "treelist-ref", bi_treelist_ref);
  creme_register_builtin(vm, "treelist-first", bi_treelist_first);
  creme_register_builtin(vm, "treelist-last", bi_treelist_last);
  creme_register_builtin(vm, "treelist-add", bi_treelist_add);
  creme_register_builtin(vm, "treelist-cons", bi_treelist_cons);
  creme_register_builtin(vm, "treelist-set", bi_treelist_set);
  creme_register_builtin(vm, "treelist-insert", bi_treelist_insert);
  creme_register_builtin(vm, "treelist-delete", bi_treelist_delete);
  creme_register_builtin(vm, "treelist-take", bi_treelist_take);
  creme_register_builtin(vm, "treelist-drop", bi_treelist_drop);
  creme_register_builtin(vm, "treelist-take-right", bi_treelist_take_right);
  creme_register_builtin(vm, "treelist-drop-right", bi_treelist_drop_right);
  creme_register_builtin(vm, "treelist-sublist", bi_treelist_sublist);
  creme_register_builtin(vm, "treelist-rest", bi_treelist_rest);
  creme_register_builtin(vm, "treelist-append", bi_treelist_append);
  creme_register_builtin(vm, "treelist-reverse", bi_treelist_reverse);
  creme_register_builtin(vm, "treelist-map", bi_treelist_map);
  creme_register_builtin(vm, "treelist-filter", bi_treelist_filter);
  creme_register_builtin(vm, "treelist-for-each", bi_treelist_for_each);
  creme_register_builtin(vm, "treelist-sort", bi_treelist_sort);
  creme_register_builtin(vm, "treelist-member?", bi_treelist_member_p);
  creme_register_builtin(vm, "treelist-index-of", bi_treelist_index_of);
  creme_register_builtin(vm, "treelist-find", bi_treelist_find);

  creme_register_builtin(vm, "mutable-treelist", bi_mutable_treelist);
  creme_register_builtin(vm, "make-mutable-treelist", bi_make_mutable_treelist);
  creme_register_builtin(vm, "list->mutable-treelist", bi_list_to_mutable_treelist);
  creme_register_builtin(vm, "vector->mutable-treelist", bi_vector_to_mutable_treelist);
  creme_register_builtin(vm, "treelist-copy", bi_treelist_copy);
  creme_register_builtin(vm, "mutable-treelist-copy", bi_mutable_treelist_copy);
  creme_register_builtin(vm, "mutable-treelist-snapshot", bi_mutable_treelist_snapshot);
  creme_register_builtin(vm, "mutable-treelist->list", bi_mutable_treelist_to_list);
  creme_register_builtin(vm, "mutable-treelist->vector", bi_mutable_treelist_to_vector);
  creme_register_builtin(vm, "mutable-treelist?", bi_mutable_treelist_p);
  creme_register_builtin(vm, "mutable-treelist-empty?", bi_mutable_treelist_empty_p);
  creme_register_builtin(vm, "mutable-treelist-length", bi_mutable_treelist_length);
  creme_register_builtin(vm, "mutable-treelist-ref", bi_mutable_treelist_ref);
  creme_register_builtin(vm, "mutable-treelist-first", bi_mutable_treelist_first);
  creme_register_builtin(vm, "mutable-treelist-last", bi_mutable_treelist_last);
  creme_register_builtin(vm, "mutable-treelist-add!", bi_mutable_treelist_add_bang);
  creme_register_builtin(vm, "mutable-treelist-cons!", bi_mutable_treelist_cons_bang);
  creme_register_builtin(vm, "mutable-treelist-set!", bi_mutable_treelist_set_bang);
  creme_register_builtin(vm, "mutable-treelist-insert!", bi_mutable_treelist_insert_bang);
  creme_register_builtin(vm, "mutable-treelist-delete!", bi_mutable_treelist_delete_bang);
  creme_register_builtin(vm, "mutable-treelist-append!", bi_mutable_treelist_append_bang);
  creme_register_builtin(vm, "mutable-treelist-prepend!", bi_mutable_treelist_prepend_bang);
  creme_register_builtin(vm, "mutable-treelist-take!", bi_mutable_treelist_take_bang);
  creme_register_builtin(vm, "mutable-treelist-drop!", bi_mutable_treelist_drop_bang);
  creme_register_builtin(vm, "mutable-treelist-take-right!", bi_mutable_treelist_take_right_bang);
  creme_register_builtin(vm, "mutable-treelist-drop-right!", bi_mutable_treelist_drop_right_bang);
  creme_register_builtin(vm, "mutable-treelist-sublist!", bi_mutable_treelist_sublist_bang);
  creme_register_builtin(vm, "mutable-treelist-reverse!", bi_mutable_treelist_reverse_bang);
  creme_register_builtin(vm, "mutable-treelist-map!", bi_mutable_treelist_map_bang);
  creme_register_builtin(vm, "mutable-treelist-sort!", bi_mutable_treelist_sort_bang);
  creme_register_builtin(vm, "mutable-treelist-for-each", bi_mutable_treelist_for_each);
  creme_register_builtin(vm, "mutable-treelist-member?", bi_mutable_treelist_member_p);
  creme_register_builtin(vm, "mutable-treelist-find", bi_mutable_treelist_find);

  /* empty-treelist is a value constant, not a procedure -- interned
   * directly into the global table, mirroring (creme math)'s own pi/e
   * (builtins.c) rather than a BuiltinFn. */
  int slot = creme_global_intern(vm, "empty-treelist", 14);
  vm->globals[slot].value = v_treelist(rrb_empty_leaf());
  vm->globals[slot].bound = 1;
}
