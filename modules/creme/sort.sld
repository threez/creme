;; ===========================================================================
;; (creme sort): a generic list sort, plus a key-extracting convenience
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme table)/(creme numfmt)/(creme extra) use) rather than compiled into
;; the interpreter binary, since every export here is expressible in plain
;; R7RS with no opaque foreign object, stateful handle, or third-party
;; Crystal library involved — see modules/creme/extra.sld's own header
;; comment for the same rationale. `(creme treelist)`'s treelist-sort/
;; mutable-treelist-sort! are a different, unrelated thing: those sort
;; treelist values (this project's own persistent-vector-like data
;; structure), not plain lists.
;;
;;   (list-sort less? lst)          -> lst, stably sorted ascending by
;;                                      less? (a proper "a should come
;;                                      before b" predicate, e.g. < for
;;                                      ascending numbers, string<? for
;;                                      ascending strings). A plain,
;;                                      recursive top-down merge sort --
;;                                      O(n log n), and stable (two
;;                                      elements neither less? than the
;;                                      other keep their original relative
;;                                      order), same guarantee SRFI 132's
;;                                      list-sort (the same name/contract
;;                                      this mirrors) makes.
;;   (sort-by key-fn less? lst)     -> lst, stably sorted by comparing
;;                                      (key-fn elem) across elements with
;;                                      less?, instead of comparing whole
;;                                      elements directly -- e.g. (sort-by
;;                                      cadr > rows) sorts a list of rows
;;                                      by their own second element,
;;                                      descending, without writing out
;;                                      (lambda (a b) (> (cadr a) (cadr b)))
;;                                      at the call site.
;;
;; Not auto-imported anywhere — every script that wants list-sort/sort-by
;; must (import (creme sort)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme sort)
  (export list-sort sort-by)
  (import (scheme base) (only (creme extra) take drop))
  (begin
    ;; Merges two already-sorted (by less?) lists into one sorted list.
    ;; Picks from `a` on a tie (not less? in either direction) so an
    ;; earlier-in-the-original-list element stays earlier -- this is what
    ;; makes the whole sort stable.
    (define (merge-sorted less? a b)
      (cond
       ((null? a) b)
       ((null? b) a)
       ((less? (car b) (car a)) (cons (car b) (merge-sorted less? a (cdr b))))
       (else (cons (car a) (merge-sorted less? (cdr a) b)))))

    ;; (list-sort less? lst) -> see this file's own header comment.
    (define (list-sort less? lst)
      (if (or (null? lst) (null? (cdr lst)))
          lst
          (let* ((half (quotient (length lst) 2))
                 (left (take lst half))
                 (right (drop lst half)))
            (merge-sorted less? (list-sort less? left) (list-sort less? right)))))

    ;; (sort-by key-fn less? lst) -> see this file's own header comment.
    (define (sort-by key-fn less? lst)
      (list-sort (lambda (a b) (less? (key-fn a) (key-fn b))) lst))))
