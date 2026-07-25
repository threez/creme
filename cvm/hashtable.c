/* (creme hash-table) — see hashtable.h.
 *
 * A real Scheme value (a list of memoize args, a closure used as a key,
 * ...) doesn't fit FIOBJ's own type system losslessly in both directions —
 * a closure or another hash-table box can be used as a hash-table KEY *or
 * VALUE* (see modules/creme/memoize.sld's `memoize-caches`, which maps a
 * wrapper closure to another hash-table box), and there's no way to
 * reconstruct an arbitrary cvm Value back out of a plain FIOBJ number/
 * string/array. So FIOBJ here is used ONLY as a structural hash/equality
 * index: `value_to_fiobj` converts a Scheme key into an FIOBJ purely so
 * fiobj_hash's own hashing/equality can find it again, and the hash maps
 * that FIOBJ key to a small integer — an index into this table's own
 * `values` side array, which holds the REAL (unconverted) Values. That
 * side array is GC_MALLOC'd and reachable from the table's own CvmHashTable
 * struct (itself reachable from wherever the T_BOX Value holding it lives),
 * so Boehm sees every stored Value normally — nothing is ever hidden inside
 * facil.io's own non-GC refcounted memory. */
#include <gc.h>
#include <fiobj.h>

#include "hashtable.h"

typedef struct {
  FIOBJ hash;
  Value *values;
  int n_values, cap_values;
} CvmHashTable;

/* Converts a Scheme value into an FIOBJ purely for fiobj_hash's own
 * structural hashing/equality — never converted back (see this file's own
 * header comment). Two Scheme values that are genuinely different types
 * but happen to encode to the same FIOBJ shape (e.g. the character #\A and
 * the integer 65, or a symbol and a string with the same characters) would
 * collide as the same key; not a concern for what this app's own memoize
 * caches actually key on (argument lists of plain ints/strings/bools). */
static FIOBJ value_to_fiobj(Value v) {
  switch (v.tag) {
  case T_NIL:
    return fiobj_null();
  case T_BOOL:
    return v.as.b ? fiobj_true() : fiobj_false();
  case T_INT:
    return fiobj_num_new(v.as.i);
  case T_FLOAT:
    return fiobj_float_new(v.as.f);
  case T_CHAR:
    return fiobj_num_new(v.as.i);
  case T_STR:
  case T_SYM:
    return fiobj_str_new(v.as.str.chars, (size_t)v.as.str.len);
  case T_PAIR: {
    FIOBJ ary = fiobj_ary_new();
    Value cur = v;
    while (cur.tag == T_PAIR) {
      fiobj_ary_push(ary, value_to_fiobj(cur.as.pair->car));
      cur = cur.as.pair->cdr;
    }
    return ary;
  }
  case T_VECTOR: {
    FIOBJ ary = fiobj_ary_new();
    for (int i = 0; i < v.as.vec->len; i++) fiobj_ary_push(ary, value_to_fiobj(v.as.vec->items[i]));
    return ary;
  }
  case T_CLOSURE:
    return fiobj_num_new((intptr_t)v.as.closure);
  case T_BUILTIN:
    return fiobj_num_new((intptr_t)v.as.builtin);
  case T_BOX:
    return fiobj_num_new((intptr_t)v.as.box.ptr);
  case T_PORT:
    return fiobj_num_new((intptr_t)v.as.port);
  default:
    return fiobj_null();
  }
}

static CvmHashTable *as_hash_table(Value v, const char *who) {
  if (v.tag != T_BOX || v.as.box.kind != BOX_KIND_HASHTABLE) cvm_abort("%s: expected a hash table", who);
  return (CvmHashTable *)v.as.box.ptr;
}

static Value bi_make_hash_table(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  CvmHashTable *ht = GC_MALLOC(sizeof(CvmHashTable));
  ht->hash = fiobj_hash_new();
  ht->values = NULL;
  ht->n_values = 0;
  ht->cap_values = 0;
  return v_box(ht, BOX_KIND_HASHTABLE);
}

static Value bi_hash_table_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("hash-table?: expected an argument");
  return v_bool(args[0].tag == T_BOX && args[0].as.box.kind == BOX_KIND_HASHTABLE);
}

static Value bi_hash_table_set(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 3) cvm_abort("hash-table-set!: expected (table key value)");
  CvmHashTable *ht = as_hash_table(args[0], "hash-table-set!");
  FIOBJ fkey = value_to_fiobj(args[1]);
  if (ht->n_values >= ht->cap_values) {
    ht->cap_values = ht->cap_values ? ht->cap_values * 2 : 8;
    ht->values = GC_REALLOC(ht->values, sizeof(Value) * (size_t)ht->cap_values);
  }
  int idx = ht->n_values++;
  ht->values[idx] = args[2];
  fiobj_hash_set(ht->hash, fkey, fiobj_num_new(idx + 1)); /* +1: 0 would collide with FIOBJ_INVALID */
  fiobj_free(fkey);
  return v_nil();
}

static int hash_table_lookup(CvmHashTable *ht, Value key, Value *out) {
  FIOBJ fkey = value_to_fiobj(key);
  FIOBJ found = fiobj_hash_get(ht->hash, fkey);
  fiobj_free(fkey);
  if (!found) return 0;
  int idx = (int)fiobj_obj2num(found) - 1;
  *out = ht->values[idx];
  return 1;
}

static Value bi_hash_table_contains_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("hash-table-contains?: expected (table key)");
  CvmHashTable *ht = as_hash_table(args[0], "hash-table-contains?");
  Value unused;
  return v_bool(hash_table_lookup(ht, args[1], &unused));
}

static Value bi_hash_table_ref(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("hash-table-ref: expected (table key [default-thunk])");
  CvmHashTable *ht = as_hash_table(args[0], "hash-table-ref");
  Value result;
  if (hash_table_lookup(ht, args[1], &result)) return result;
  if (nargs >= 3) return cvm_apply(vm, args[2], NULL, 0);
  cvm_abort("hash-table-ref: key not found and no default thunk given");
}

static Value bi_hash_table_delete(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("hash-table-delete!: expected (table key)");
  CvmHashTable *ht = as_hash_table(args[0], "hash-table-delete!");
  FIOBJ fkey = value_to_fiobj(args[1]);
  fiobj_hash_delete(ht->hash, fkey);
  fiobj_free(fkey);
  return v_nil();
}

void cvm_register_hashtable_builtins(VM *vm) {
  cvm_register_builtin(vm, "make-hash-table", bi_make_hash_table);
  cvm_register_builtin(vm, "hash-table?", bi_hash_table_p);
  cvm_register_builtin(vm, "hash-table-set!", bi_hash_table_set);
  cvm_register_builtin(vm, "hash-table-contains?", bi_hash_table_contains_p);
  cvm_register_builtin(vm, "hash-table-ref", bi_hash_table_ref);
  cvm_register_builtin(vm, "hash-table-delete!", bi_hash_table_delete);
}
