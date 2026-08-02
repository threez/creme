;; ===========================================================================
;; (creme abbrev): unambiguous-abbreviation lookup, matching Ruby's Abbrev
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme prime)/(creme set) use) since every export here is expressible in
;; plain R7RS on top of (creme hash-table)'s primitives, with no opaque
;; foreign object or third-party Crystal library involved.
;;
;;   (abbrev words)  -> an alist `(prefix . word)` covering every prefix
;;                      (of every length) of every string in `words` that
;;                      uniquely identifies one word across the whole
;;                      list, PLUS every full word mapped to itself
;;                      unconditionally (even one so short another word
;;                      shares every one of its own shorter prefixes) --
;;                      exactly Ruby's `Abbrev.abbrev` behavior. E.g.
;;                      (abbrev '("ruby" "rules")) maps "rub"/"ruby" only
;;                      to "ruby" (the shared "ru"/"r" prefixes are
;;                      ambiguous, so absent), "rul"/"rule"/"rules" only
;;                      to "rules", and both "ruby" and "rules" themselves
;;                      are always present regardless. Alist order is
;;                      unspecified (built over a hash-table internally,
;;                      same as (creme set)'s set->list).
;;   (abbrev-resolve alist prefix) -> the full word alist maps prefix to,
;;                      or #f if prefix isn't in alist at all (neither a
;;                      unique abbreviation nor a full word).
;;
;; Deliberately omits Ruby's optional `pattern` argument (a regexp/string
;; pre-filter over which words participate) -- out of scope for this MVP;
;; a caller wanting that can simply filter `words` itself before calling
;; abbrev.
;; ===========================================================================

(define-library (creme abbrev)
  (export abbrev abbrev-resolve)
  (import (scheme base) (creme hash-table))
  (begin
    (define (abbrev words)
      (let ((seen (make-hash-table)) (table (make-hash-table)))
        (for-each
         (lambda (word)
           (let loop ((len (string-length word)))
             (if (>= len 1)
                 (let* ((prefix (substring word 0 len))
                        (count (+ 1 (hash-table-ref seen prefix (lambda () 0)))))
                   (hash-table-set! seen prefix count)
                   (cond
                    ((= count 1) (hash-table-set! table prefix word))
                    ((= count 2) (hash-table-delete! table prefix)))
                   (loop (- len 1))))))
         words)
        (for-each (lambda (word) (hash-table-set! table word word)) words)
        (hash-table->alist table)))

    (define (abbrev-resolve alist prefix)
      (let ((entry (assoc prefix alist)))
        (if entry (cdr entry) #f)))))
