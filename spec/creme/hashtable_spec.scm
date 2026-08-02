;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/modules/creme/hash_table_spec.cr's
;; own cases exercising (creme hash-table) -- see modules/creme/spec.sld's
;; own header comment for the framework this uses, and compiler_spec.scm's
;; own header comment for the general should-match-native? approach.
;;
;; hash-table-keys/hash-table-values/hash-table->alist used to be a
;; deliberate icecreme gap (icecreme/hashtable.c's CremeHashTable only stored values,
;; never the original keys, so there was nothing to recover them from) --
;; now implemented (see hashtable.c's own header comment on the `keys`
;; array + fiobj_each1-based enumeration), so ported here the same
;; should-match-native? way as prim_call_spec.scm/compiler_numeric_tower_
;; spec.scm.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/hashtable_spec.scm
;;   ./bin/creme --self-hosted spec/creme/hashtable_spec.scm
;;   ./icecreme/icecreme spec/creme/hashtable_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper)
        (creme hash-table))

(describe "hash-table module"
  (it "make-hash-table/hash-table? construct an empty table"
    (should-match-native? '((hash-table? (make-hash-table))))
    (should-match-native? '((hash-table? 5))))

  (it "hash-table-set!/hash-table-ref round-trip a value"
    (should-match-native? '((define h (make-hash-table)) (hash-table-set! h 'a 1) (hash-table-ref h 'a))))

  (it "hash-table-set! overwrites an existing key"
    (should-match-native? '((define h (make-hash-table)) (hash-table-set! h 'a 1) (hash-table-set! h 'a 2) (hash-table-ref h 'a))))

  (it "keys are compared by equal?, not identity"
    (should-match-native? '((define h (make-hash-table)) (hash-table-set! h (list 1 2) 'found) (hash-table-ref h (list 1 2) 'missing))))

  (it "hash-table-ref returns a plain default value when the key is missing"
    (should-match-native? '((define h (make-hash-table)) (hash-table-ref h 'missing 'fallback))))

  (it "hash-table-ref calls a thunk default lazily when the key is missing"
    (should-match-native? '((define h (make-hash-table)) (hash-table-ref h 'missing (lambda () 'lazy)))))

  (it "hash-table-keys/hash-table-values/hash-table->alist"
    (should-match-native? '((define h (make-hash-table)) (hash-table-set! h 'a 1) (hash-table-set! h 'b 2) (hash-table-keys h)))
    (should-match-native? '((define h2 (make-hash-table)) (hash-table-set! h2 'a 1) (hash-table-set! h2 'b 2) (hash-table-values h2)))
    (should-match-native? '((define h3 (make-hash-table)) (hash-table-set! h3 'a 1) (hash-table-set! h3 'b 2) (hash-table->alist h3))))

  (it "hash-table-delete! removes a key, and hash-table-contains? reflects it"
    (should-match-native? '((define h4 (make-hash-table)) (hash-table-set! h4 'a 1) (hash-table-delete! h4 'a) (hash-table-contains? h4 'a)))))

(spec-summary!)
