;; ===========================================================================
;; A (creme spec)-based port of (creme treelist)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme treelist) used to be entirely absent from icecreme. Implemented as a
;; direct, line-for-line port of native's own RRB (Relaxed Radix
;; Balanced) tree engine (icecreme/treelist.c) -- every internal branch node
;; carries a cumulative size table, giving real O(log n) ref/set/add/
;; insert/delete/take/drop/concat, not just a plain array standing in
;; for the same API. See that file's own header comment for the port's
;; design notes (every Crystal array-copy-on-slice is replicated as an
;; explicit C array copy, to preserve the same persistent-immutability
;; guarantee).
;;
;; treelist-map's argument order is (treelist proc); treelist-filter's is
;; the REVERSE, (proc treelist) -- matching native's own arg order
;; exactly (see treelist.cr's own treelist_filter). Both are exercised
;; below with their own correct order.
;;
;; Includes cases building treelists past 32 elements (RRB_WIDTH) to
;; exercise actual multi-level tree rebalancing/concatenation, not just
;; the single-leaf fast path.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/treelist_spec.scm
;;   ./bin/creme --self-hosted spec/creme/treelist_spec.scm
;;   ./icecreme/icecreme spec/creme/treelist_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme char) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme treelist) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme treelist) construction/conversion"
  (it "treelist/list->treelist/vector->treelist round-trip via treelist->list"
    (should-match-native? '((treelist->list (treelist 1 2 3 4 5))))
    (should-match-native? '((treelist->list (list->treelist (list 1 2 3)))))
    (should-match-native? '((treelist->list (vector->treelist (vector 'a 'b 'c))))))

  (it "treelist->vector and make-treelist"
    (should-match-native? '((treelist->vector (treelist 1 2 3))))
    (should-match-native? '((treelist->list (make-treelist 4 'x)))))

  (it "treelist?/treelist-empty?/treelist-length"
    (should-match-native? '((treelist? (treelist 1))))
    (should-match-native? '((treelist? 5)))
    (should-match-native? '((treelist-empty? (treelist))))
    (should-match-native? '((treelist-length (treelist 1 2 3))))
    (should-match-native? '((treelist->list empty-treelist)))))

(describe "(creme treelist) access"
  (it "treelist-ref/treelist-first/treelist-last"
    (should-match-native? '((treelist-ref (treelist 1 2 3) 1)))
    (should-match-native? '((treelist-first (treelist 1 2 3))))
    (should-match-native? '((treelist-last (treelist 1 2 3))))))

(describe "(creme treelist) functional update"
  (it "treelist-add/treelist-cons/treelist-set"
    (should-match-native? '((treelist->list (treelist-add (treelist 1 2 3) 4))))
    (should-match-native? '((treelist->list (treelist-cons (treelist 1 2 3) 0))))
    (should-match-native? '((treelist->list (treelist-set (treelist 1 2 3) 1 99)))))

  (it "treelist-insert/treelist-delete"
    (should-match-native? '((treelist->list (treelist-insert (treelist 1 2 3) 1 99))))
    (should-match-native? '((treelist->list (treelist-insert (treelist 1 2 3) 0 99))))
    (should-match-native? '((treelist->list (treelist-insert (treelist 1 2 3) 3 99))))
    (should-match-native? '((treelist->list (treelist-delete (treelist 1 2 3) 1)))))

  (it "treelist-take/-drop/-take-right/-drop-right/-sublist/-rest"
    (should-match-native? '((treelist->list (treelist-take (treelist 1 2 3 4 5) 2))))
    (should-match-native? '((treelist->list (treelist-drop (treelist 1 2 3 4 5) 2))))
    (should-match-native? '((treelist->list (treelist-take-right (treelist 1 2 3 4 5) 2))))
    (should-match-native? '((treelist->list (treelist-drop-right (treelist 1 2 3 4 5) 2))))
    (should-match-native? '((treelist->list (treelist-sublist (treelist 1 2 3 4 5) 1 3))))
    (should-match-native? '((treelist->list (treelist-rest (treelist 1 2 3))))))

  (it "treelist-append/treelist-reverse"
    (should-match-native? '((treelist->list (treelist-append (treelist 1 2) (treelist 3 4) (treelist 5)))))
    (should-match-native? '((treelist->list (treelist-reverse (treelist 1 2 3))))))

  (it "treelist-map (treelist proc order) and treelist-filter (proc treelist order)"
    (should-match-native? '((treelist->list (treelist-map (treelist 1 2 3) (lambda (x) (* x x))))))
    (should-match-native? '((treelist->list (treelist-filter even? (treelist 1 2 3 4 5 6))))))

  (it "treelist-for-each and treelist-sort"
    (should-match-native?
     '((define acc '())
       (treelist-for-each (treelist 1 2 3) (lambda (x) (set! acc (cons x acc))))
       acc))
    (should-match-native? '((treelist->list (treelist-sort (treelist 3 1 4 1 5 9 2 6) <))))))

(describe "(creme treelist) search"
  (it "treelist-member?/treelist-index-of/treelist-find"
    (should-match-native? '((treelist-member? (treelist 1 2 3) 2)))
    (should-match-native? '((treelist-member? (treelist 1 2 3) 99)))
    (should-match-native? '((treelist-index-of (treelist 1 2 3) 2)))
    (should-match-native? '((treelist-index-of (treelist 1 2 3) 99)))
    (should-match-native? '((treelist-find (treelist 1 2 3 4) (lambda (x) (> x 2)))))
    (should-match-native? '((treelist-member? (treelist "a" "B" "c") "b" string-ci=?)))))

(describe "(creme treelist) at scale (exercises real multi-level RRB rebalancing)"
  (it "a treelist with 200 elements round-trips through treelist->list"
    (should-match-native?
     '((define big (list->treelist (let loop ((i 0) (acc (quote ()))) (if (= i 200) (reverse acc) (loop (+ i 1) (cons i acc))))))
       (list (treelist-length big) (treelist-ref big 0) (treelist-ref big 100) (treelist-ref big 199)))))

  (it "insert/delete in the middle of a large treelist stays consistent"
    (should-match-native?
     '((define big (list->treelist (let loop ((i 0) (acc (quote ()))) (if (= i 200) (reverse acc) (loop (+ i 1) (cons i acc))))))
       (define inserted (treelist-insert big 100 -1))
       (list (treelist-ref inserted 99) (treelist-ref inserted 100) (treelist-ref inserted 101))))
    (should-match-native?
     '((define big (list->treelist (let loop ((i 0) (acc (quote ()))) (if (= i 200) (reverse acc) (loop (+ i 1) (cons i acc))))))
       (treelist->list (treelist-delete (treelist-insert big 100 -1) 100)))))

  (it "concatenating two large treelists and slicing them back apart round-trips"
    (should-match-native?
     '((define big (list->treelist (let loop ((i 0) (acc (quote ()))) (if (= i 200) (reverse acc) (loop (+ i 1) (cons i acc))))))
       (define both (treelist-append big big))
       (list (treelist-length both) (treelist-ref both 0) (treelist-ref both 199) (treelist-ref both 200) (treelist-ref both 399))))))

(describe "(creme mutable treelist)"
  (it "mutable-treelist/make-mutable-treelist/list->mutable-treelist/vector->mutable-treelist"
    (should-match-native? '((mutable-treelist->list (mutable-treelist 1 2 3))))
    (should-match-native? '((mutable-treelist->list (make-mutable-treelist 3 'z))))
    (should-match-native? '((mutable-treelist->list (list->mutable-treelist (list 1 2 3)))))
    (should-match-native? '((mutable-treelist->list (vector->mutable-treelist (vector 1 2 3))))))

  (it "mutable-treelist?/mutable-treelist-empty?/mutable-treelist-length/mutable-treelist->vector"
    (should-match-native? '((mutable-treelist? (mutable-treelist 1))))
    (should-match-native? '((mutable-treelist? 5)))
    (should-match-native? '((mutable-treelist-empty? (mutable-treelist))))
    (should-match-native? '((mutable-treelist-length (mutable-treelist 1 2 3))))
    (should-match-native? '((mutable-treelist->vector (mutable-treelist 1 2 3)))))

  (it "mutable-treelist-ref/-first/-last"
    (should-match-native? '((mutable-treelist-ref (mutable-treelist 1 2 3) 1)))
    (should-match-native? '((mutable-treelist-first (mutable-treelist 1 2 3))))
    (should-match-native? '((mutable-treelist-last (mutable-treelist 1 2 3)))))

  (it "mutable-treelist-add!/-cons!/-set!/-insert!/-delete! mutate in place"
    (should-match-native?
     '((define m (mutable-treelist 1 2 3))
       (mutable-treelist-add! m 4)
       (mutable-treelist-cons! m 0)
       (mutable-treelist->list m)))
    (should-match-native?
     '((define m (mutable-treelist 1 2 3))
       (mutable-treelist-set! m 1 99)
       (mutable-treelist->list m)))
    (should-match-native?
     '((define m (mutable-treelist 1 2 3))
       (mutable-treelist-insert! m 1 99)
       (mutable-treelist->list m)))
    (should-match-native?
     '((define m (mutable-treelist 1 2 3))
       (mutable-treelist-delete! m 1)
       (mutable-treelist->list m))))

  (it "mutable-treelist-append!/-prepend! accept either treelist kind"
    (should-match-native?
     '((define m (mutable-treelist 1 2))
       (mutable-treelist-append! m (treelist 3 4))
       (mutable-treelist->list m)))
    (should-match-native?
     '((define m (mutable-treelist 1 2))
       (mutable-treelist-prepend! m (mutable-treelist -1 0))
       (mutable-treelist->list m))))

  (it "mutable-treelist-take!/-drop!/-take-right!/-drop-right!/-sublist!/-reverse!"
    (should-match-native?
     '((define m (mutable-treelist 1 2 3 4 5))
       (mutable-treelist-take! m 3)
       (mutable-treelist->list m)))
    (should-match-native?
     '((define m (mutable-treelist 1 2 3 4 5))
       (mutable-treelist-drop! m 3)
       (mutable-treelist->list m)))
    (should-match-native?
     '((define m (mutable-treelist 1 2 3 4 5))
       (mutable-treelist-take-right! m 2)
       (mutable-treelist->list m)))
    (should-match-native?
     '((define m (mutable-treelist 1 2 3 4 5))
       (mutable-treelist-drop-right! m 2)
       (mutable-treelist->list m)))
    (should-match-native?
     '((define m (mutable-treelist 1 2 3 4 5))
       (mutable-treelist-sublist! m 1 3)
       (mutable-treelist->list m)))
    (should-match-native?
     '((define m (mutable-treelist 1 2 3))
       (mutable-treelist-reverse! m)
       (mutable-treelist->list m))))

  (it "mutable-treelist-map!/-sort!/-for-each"
    (should-match-native?
     '((define m (mutable-treelist 1 2 3))
       (mutable-treelist-map! m (lambda (x) (* x 10)))
       (mutable-treelist->list m)))
    (should-match-native?
     '((define m (mutable-treelist 3 1 2))
       (mutable-treelist-sort! m <)
       (mutable-treelist->list m)))
    (should-match-native?
     '((define acc '())
       (mutable-treelist-for-each (mutable-treelist 1 2 3) (lambda (x) (set! acc (cons x acc))))
       acc)))

  (it "mutable-treelist-member?/-find"
    (should-match-native? '((mutable-treelist-member? (mutable-treelist 1 2 3) 2)))
    (should-match-native? '((mutable-treelist-find (mutable-treelist 1 2 3 4) (lambda (x) (> x 2))))))

  (it "treelist-copy/mutable-treelist-copy/mutable-treelist-snapshot preserve independence"
    (should-match-native?
     '((define t (treelist 1 2 3))
       (define mc (treelist-copy t))
       (mutable-treelist-add! mc 4)
       (list (treelist->list t) (mutable-treelist->list mc))))
    (should-match-native?
     '((define mc (mutable-treelist 1 2 3))
       (define snap (mutable-treelist-snapshot mc))
       (mutable-treelist-add! mc 4)
       (list (treelist->list snap) (mutable-treelist->list mc))))
    (should-match-native?
     '((define mc (mutable-treelist 1 2 3))
       (define mc2 (mutable-treelist-copy mc))
       (mutable-treelist-add! mc2 999)
       (list (mutable-treelist->list mc) (mutable-treelist->list mc2))))))

(spec-summary!)
