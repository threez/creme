;; ===========================================================================
;; (creme set): a mutable hash-set, plus a SortedSet variant
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme memoize)/(creme extra) use) rather than compiled into the
;; interpreter binary, since every export here is expressible in plain R7RS
;; on top of (creme hash-table)'s own primitives, with no opaque foreign
;; object or third-party Crystal library of its own involved.
;;
;; A set is a <set> record wrapping one (creme hash-table) whose keys are
;; the set's members and whose values are always #t (a placeholder — only
;; key presence is ever consulted). Membership/equality is whatever (creme
;; hash-table) itself uses (equal?), so e.g. (set 1 1.0) is NOT collapsed
;; to one member (1 and 1.0 are equal? distinct, being exact vs inexact),
;; matching (creme hash-table)'s own key semantics exactly — this is a
;; thin adapter over that table, not a new equality notion.
;;
;;   (make-set)              -> a new empty set
;;   (set item ...)          -> a new set containing the given items
;;   (list->set lst)         -> a new set containing lst's elements
;;   (set->list s)           -> s's members as a list, in unspecified order
;;   (set? x)                -> #t iff x is a <set> record
;;   (set-add! s x)          -> adds x to s (idempotent)
;;   (set-delete! s x)       -> removes x from s (no-op if absent)
;;   (set-member? s x)       -> #t iff x is in s
;;   (set-size s)            -> s's member count
;;   (set-empty? s)          -> #t iff s has no members
;;   (set-copy s)            -> a new set with the same members
;;   (set-clear! s)          -> removes every member from s, in place
;;   (set-each s proc)       -> calls (proc x) for each member, for effect
;;   (set-map s proc)        -> a new set of (proc x) over each member
;;                              (note: if proc isn't injective, the result
;;                              can have fewer members than s did)
;;   (set-filter s pred)     -> a new set of s's members satisfying pred
;;   (set-union a b)             -> a new set: everything in a or b
;;   (set-intersection a b)      -> a new set: everything in both a and b
;;   (set-difference a b)        -> a new set: a's members not in b
;;   (set-symmetric-difference a b) -> a new set: members in exactly one of
;;                                     a/b (Ruby's Set#^)
;;   (set-subset? a b)       -> #t iff every member of a is in b
;;   (set-superset? a b)     -> #t iff every member of b is in a
;;   (set-disjoint? a b)     -> #t iff a and b share no members
;;   (set-equal? a b)        -> #t iff a and b have exactly the same members
;;   (set-merge! a b)        -> adds every member of b into a, in place,
;;                              and returns a (Ruby's Set#merge)
;;
;; SortedSet: a <sorted-set> record, same membership semantics as <set>,
;; but set->list is instead always returned in ascending order per an
;; explicit less? comparator (default <, so a sorted-set of anything but
;; numbers needs its own comparator passed explicitly — mixing
;; incomparable member types under the default comparator is the caller's
;; problem to avoid, same honesty as (creme sort) itself makes no attempt
;; to guess a "natural" order for arbitrary values).
;;
;;   (make-sorted-set)            -> empty, ordered by <
;;   (make-sorted-set less?)     -> empty, ordered by less?
;;   (sorted-set item ...)        -> from items, ordered by <
;;   (list->sorted-set lst less?) -> from a list, with an explicit less?
;;   (sorted-set? x)
;;   (sorted-set-add! s x) / (sorted-set-delete! s x) / (sorted-set-member? s x)
;;   (sorted-set-size s)
;;   (sorted-set->list s)         -> members in ascending order, computed
;;                                   fresh each call via (creme sort)'s
;;                                   list-sort (a sorted-set does not keep
;;                                   its members pre-sorted internally —
;;                                   membership/add/delete stay O(1)-ish
;;                                   hash-table operations, and only
;;                                   ->list pays the O(n log n) sort cost)
;;
;; Not auto-imported anywhere — every script that wants this must
;; (import (creme set)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme set)
  (export
    make-set set list->set set->list set? set-add! set-delete! set-member?
    set-size set-empty? set-copy set-clear! set-each set-map set-filter
    set-union set-intersection set-difference set-symmetric-difference
    set-subset? set-superset? set-disjoint? set-equal? set-merge!
    make-sorted-set sorted-set list->sorted-set sorted-set?
    sorted-set-add! sorted-set-delete! sorted-set-member? sorted-set-size
    sorted-set->list)
  (import (scheme base) (creme hash-table) (creme sort))
  (begin
    (define-record-type <set>
      (make-set-record table)
      set?
      (table set-table))

    (define (make-set) (make-set-record (make-hash-table)))

    (define (set . items) (list->set items))

    (define (list->set lst)
      (let ((s (make-set)))
        (for-each (lambda (x) (set-add! s x)) lst)
        s))

    (define (set-add! s x) (hash-table-set! (set-table s) x #t))
    (define (set-delete! s x) (hash-table-delete! (set-table s) x))
    (define (set-member? s x) (hash-table-contains? (set-table s) x))
    (define (set->list s) (hash-table-keys (set-table s)))
    (define (set-size s) (length (set->list s)))
    (define (set-empty? s) (null? (set->list s)))
    (define (set-copy s) (list->set (set->list s)))
    (define (set-clear! s) (for-each (lambda (x) (set-delete! s x)) (set->list s)))
    (define (set-each s proc) (for-each proc (set->list s)))
    (define (set-map s proc) (list->set (map proc (set->list s))))

    (define (set-priv-filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (set-priv-filter pred (cdr lst))))
            (else (set-priv-filter pred (cdr lst)))))

    (define (set-priv-every? pred lst)
      (or (null? lst) (and (pred (car lst)) (set-priv-every? pred (cdr lst)))))

    (define (set-filter s pred) (list->set (set-priv-filter pred (set->list s))))

    (define (set-union a b) (list->set (append (set->list a) (set->list b))))
    (define (set-intersection a b)
      (list->set (set-priv-filter (lambda (x) (set-member? b x)) (set->list a))))
    (define (set-difference a b)
      (list->set (set-priv-filter (lambda (x) (not (set-member? b x))) (set->list a))))
    (define (set-symmetric-difference a b)
      (set-union (set-difference a b) (set-difference b a)))
    (define (set-subset? a b)
      (set-priv-every? (lambda (x) (set-member? b x)) (set->list a)))
    (define (set-superset? a b) (set-subset? b a))
    (define (set-disjoint? a b) (null? (set->list (set-intersection a b))))
    (define (set-equal? a b) (and (= (set-size a) (set-size b)) (set-subset? a b)))
    (define (set-merge! a b)
      (for-each (lambda (x) (set-add! a x)) (set->list b))
      a)

    (define-record-type <sorted-set>
      (make-sorted-set-record table less?)
      sorted-set?
      (table sorted-set-table)
      (less? sorted-set-less?))

    (define (make-sorted-set . opt)
      (make-sorted-set-record (make-hash-table) (if (null? opt) < (car opt))))

    (define (sorted-set . items) (list->sorted-set items <))

    (define (list->sorted-set lst less?)
      (let ((s (make-sorted-set less?)))
        (for-each (lambda (x) (sorted-set-add! s x)) lst)
        s))

    (define (sorted-set-add! s x) (hash-table-set! (sorted-set-table s) x #t))
    (define (sorted-set-delete! s x) (hash-table-delete! (sorted-set-table s) x))
    (define (sorted-set-member? s x) (hash-table-contains? (sorted-set-table s) x))
    (define (sorted-set-size s) (length (hash-table-keys (sorted-set-table s))))
    (define (sorted-set->list s)
      (list-sort (sorted-set-less? s) (hash-table-keys (sorted-set-table s))))))
