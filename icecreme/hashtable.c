/* (creme hash-table) — see hashtable.h.
 *
 * Backed by Verstable (vendor/verstable/verstable.h, MIT). Verstable's
 * KEY_TY can be a real Scheme `Value` directly (via creme_hash_value/
 * creme_equal, vm.h), so there's no lossy conversion step at all.
 *
 * A real Scheme value (a list of memoize args, a closure used as a key,
 * ...) doesn't fit losslessly into a small integer, and a closure or
 * another hash-table box can be used as a hash-table KEY *or VALUE* (see
 * modules/creme/memoize.sld's `memoize-caches`, which maps a wrapper
 * closure to another hash-table box) -- so this table's `map` only ever
 * maps a Scheme key to an *index* into this table's own `keys`/`values`
 * side arrays, which hold the REAL Values. Those arrays are GC_MALLOC'd
 * and reachable from the table's own CremeHashTable struct (itself reachable
 * from wherever the T_BOX Value holding it lives), so Boehm sees every
 * stored Value normally.
 *
 * The side arrays exist for a second reason beyond just "recover the
 * original key for hash-table-keys/->alist": Verstable (an open-addressing
 * table) does NOT preserve insertion order, but native Crystal's own
 * Hash does (and hash-table-keys/-values/
 * ->alist's should-match-native? spec cases rely on that) -- see
 * bi_hash_table_keys/values/to_alist below for how iterating the side
 * array in slot order, filtered by a liveness re-check against `map`,
 * reproduces insertion order for the common (no-overwrite) case. */
#include <gc.h>
#include <limits.h>
#include <stdbool.h>

#include "embed.h"
#include "hashtable.h"

static void *creme_ht_malloc(size_t size) {
  return GC_MALLOC(size);
}

static void creme_ht_free(void *ptr, size_t size) {
  (void)size;
  GC_FREE(ptr);
}

static bool creme_ht_cmpr(Value a, Value b) {
  return creme_equal(a, b) != 0;
}

#define NAME creme_ht_idx
#define KEY_TY Value
#define VAL_TY int
#define HASH_FN creme_hash_value
#define CMPR_FN creme_ht_cmpr
#define MALLOC_FN creme_ht_malloc
#define FREE_FN creme_ht_free
#include "verstable.h"

typedef struct {
  creme_ht_idx map; /* Value -> (index into keys/values) + 1; see header comment */
  Value *keys;    /* parallel to values, same indexing -- the ORIGINAL Scheme
                   * key, kept so hash-table-keys/->alist can recover it and
                   * so iteration order can be reconstructed (see above) */
  Value *values;
  int n_values, cap_values;
  int n_live; /* count of live (non-orphaned) slots; drives compaction. set!
               * always appends, so n_values grows with total operations while
               * n_live tracks the actual entry count -- when the dead ratio
               * gets high we compact the side arrays back down (ht_compact). */
} CremeHashTable;

static CremeHashTable *as_hash_table(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_HASHTABLE, who);
}

static Value bi_make_hash_table(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  CremeHashTable *ht = GC_MALLOC(sizeof(CremeHashTable));
  creme_ht_idx_init(&ht->map);
  ht->keys = NULL;
  ht->values = NULL;
  ht->n_values = 0;
  ht->cap_values = 0;
  ht->n_live = 0;
  return v_box(ht, BOX_KIND_HASHTABLE);
}

static Value bi_hash_table_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "hash-table?");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_HASHTABLE);
}

/* Rebuild keys/values keeping only live slots IN THEIR CURRENT ORDER (a slot
 * is live iff the map still points AT this very slot -- same test collect_live
 * uses), reclaiming every orphaned slot left by an overwrite or delete. Order
 * is preserved, so hash-table-keys/->alist output is unchanged. */
static void ht_compact(CremeHashTable *ht) {
  int live = ht->n_live;
  Value *nk = live ? creme_alloc_array((size_t)live, sizeof(Value), "hash-table") : NULL;
  Value *nv = live ? creme_alloc_array((size_t)live, sizeof(Value), "hash-table") : NULL;
  int n = 0;
  for (int i = 0; i < ht->n_values; i++) {
    creme_ht_idx_itr itr = creme_ht_idx_get(&ht->map, ht->keys[i]);
    if (creme_ht_idx_is_end(itr) || itr.data->val - 1 != i) continue;
    nk[n] = ht->keys[i];
    nv[n] = ht->values[i];
    n++;
  }
  for (int i = 0; i < n; i++) creme_ht_idx_insert(&ht->map, nk[i], i + 1); /* repoint at new index */
  ht->keys = nk;
  ht->values = nv;
  ht->n_values = n;
  ht->cap_values = live;
  ht->n_live = n;
}

/* Amortized-O(1) trigger: compact once at least half the slots are dead (and
 * the table is big enough that the O(n) rebuild is worth it). */
static void ht_maybe_compact(CremeHashTable *ht) {
  if (ht->n_values >= 16 && ht->n_values >= 2 * ht->n_live) ht_compact(ht);
}

Value bi_hash_table_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 3, "hash-table-set!");
  CremeHashTable *ht = as_hash_table(args[0], "hash-table-set!");
  ht_maybe_compact(ht);
  int existed = !creme_ht_idx_is_end(creme_ht_idx_get(&ht->map, args[1]));
  if (ht->n_values >= ht->cap_values) {
    /* size_t growth: `cap * 2` in int overflows to negative near INT_MAX/2 and
     * then casts to a huge size_t, feeding GC_REALLOC a bogus length. */
    size_t newcap = ht->cap_values ? (size_t)ht->cap_values * 2 : 8;
    if (newcap > INT_MAX) creme_abort("hash-table-set!: table too large");
    ht->cap_values = (int)newcap;
    ht->keys = GC_REALLOC(ht->keys, sizeof(Value) * newcap);
    ht->values = GC_REALLOC(ht->values, sizeof(Value) * newcap);
  }
  int idx = ht->n_values++;
  ht->keys[idx] = args[1];
  ht->values[idx] = args[2];
  creme_ht_idx_insert(&ht->map, args[1], idx + 1); /* +1: 0 would be ambiguous with "not found" */
  if (!existed) ht->n_live++; /* overwrite reuses no slot -- only new keys add a live entry */
  return v_nil();
}

static int hash_table_lookup(CremeHashTable *ht, Value key, Value *out) {
  creme_ht_idx_itr itr = creme_ht_idx_get(&ht->map, key);
  if (creme_ht_idx_is_end(itr)) return 0;
  *out = ht->values[itr.data->val - 1];
  return 1;
}

static Value bi_hash_table_contains_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "hash-table-contains?");
  CremeHashTable *ht = as_hash_table(args[0], "hash-table-contains?");
  Value unused;
  return v_bool(hash_table_lookup(ht, args[1], &unused));
}

/* default may be a thunk (0-arg procedure, called lazily) or, for callers
 * that don't want laziness, an ordinary value -- a non-procedure default
 * simply isn't applied. Mirrors src/creme/modules/creme/hash_table.cr's
 * own hash_table_ref/hash_table_default contract exactly -- (creme dao)'s
 * dao-ref-keyword relies on passing a plain #f default here (not a thunk),
 * so unconditionally creme_apply-ing args[2] (this function's prior behavior)
 * broke with "attempt to apply a non-procedure value" the moment icecreme ran
 * any script built on (creme dao). */
Value bi_hash_table_ref(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "hash-table-ref");
  CremeHashTable *ht = as_hash_table(args[0], "hash-table-ref");
  Value result;
  if (hash_table_lookup(ht, args[1], &result)) return result;
  if (nargs >= 3) {
    Value def = args[2];
    return (def.tag == T_CLOSURE || def.tag == T_BUILTIN) ? creme_apply(vm, def, NULL, 0) : def;
  }
  creme_abort("hash-table-ref: key not found and no default given");
}

/* hash-table-keys/-values/->alist all need to enumerate only the table's
 * LIVE entries, in insertion order (see this file's header comment for
 * why that's not just "iterate the map"). An overwritten or deleted key
 * leaves its old `keys`/`values` slot orphaned -- bi_hash_table_set never
 * overwrites a side-array slot in place, it always appends and retargets
 * `map` to the new index -- so walking the side array in slot order and,
 * for each slot, re-checking `map` still points AT THIS SLOT'S OWN index
 * naturally skips every dead one (overwritten-away or deleted), with no
 * separate liveness bookkeeping of our own. */
static Value values_to_list(VM *vm, Value *values, int n) {
  Value r = v_nil();
  for (int i = n - 1; i >= 0; i--) r = creme_cons(vm, values[i], r);
  return r;
}

typedef enum { COLLECT_KEYS, COLLECT_VALUES, COLLECT_ALIST } CollectKind;

static Value collect_live(VM *vm, CremeHashTable *ht, CollectKind kind) {
  Value *out = NULL;
  int n = 0, cap = 0;
  for (int i = 0; i < ht->n_values; i++) {
    creme_ht_idx_itr itr = creme_ht_idx_get(&ht->map, ht->keys[i]);
    if (creme_ht_idx_is_end(itr) || itr.data->val - 1 != i) continue; /* overwritten or deleted */
    if (n >= cap) {
      cap = cap ? cap * 2 : 8;
      out = GC_REALLOC(out, sizeof(Value) * (size_t)cap);
    }
    switch (kind) {
    case COLLECT_KEYS:
      out[n++] = ht->keys[i];
      break;
    case COLLECT_VALUES:
      out[n++] = ht->values[i];
      break;
    case COLLECT_ALIST:
      out[n++] = creme_cons(vm, ht->keys[i], ht->values[i]);
      break;
    }
  }
  return values_to_list(vm, out, n);
}

static Value bi_hash_table_keys(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "hash-table-keys");
  return collect_live(vm, as_hash_table(args[0], "hash-table-keys"), COLLECT_KEYS);
}

static Value bi_hash_table_values(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "hash-table-values");
  return collect_live(vm, as_hash_table(args[0], "hash-table-values"), COLLECT_VALUES);
}

static Value bi_hash_table_to_alist(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "hash-table->alist");
  return collect_live(vm, as_hash_table(args[0], "hash-table->alist"), COLLECT_ALIST);
}

static Value bi_hash_table_delete(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "hash-table-delete!");
  CremeHashTable *ht = as_hash_table(args[0], "hash-table-delete!");
  if (!creme_ht_idx_is_end(creme_ht_idx_get(&ht->map, args[1]))) {
    creme_ht_idx_erase(&ht->map, args[1]);
    ht->n_live--; /* slot stays in keys/values (now orphaned) until compaction */
    ht_maybe_compact(ht);
  }
  return v_nil();
}

void creme_register_hashtable_builtins(VM *vm) {
  creme_register_builtin(vm, "make-hash-table", bi_make_hash_table);
  creme_register_builtin(vm, "hash-table?", bi_hash_table_p);
  creme_register_builtin(vm, "hash-table-set!", bi_hash_table_set);
  creme_register_builtin(vm, "hash-table-contains?", bi_hash_table_contains_p);
  creme_register_builtin(vm, "hash-table-ref", bi_hash_table_ref);
  creme_register_builtin(vm, "hash-table-delete!", bi_hash_table_delete);
  creme_register_builtin(vm, "hash-table-keys", bi_hash_table_keys);
  creme_register_builtin(vm, "hash-table-values", bi_hash_table_values);
  creme_register_builtin(vm, "hash-table->alist", bi_hash_table_to_alist);
}
