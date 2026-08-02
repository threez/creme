;; ===========================================================================
;; (creme ostruct): a dynamic-attribute record, matching Ruby's OpenStruct
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme abbrev)/(creme set) use) since every export here is expressible
;; in plain R7RS on top of (creme hash-table)'s primitives, with no opaque
;; foreign object or third-party Crystal library involved.
;;
;; Ruby's OpenStruct dispatches an arbitrary `obj.field`/`obj.field = v`
;; through `method_missing`; Scheme has no such dispatch mechanism, so
;; field access here is always an explicit procedure call (ostruct-ref/
;; ostruct-set!) rather than dot syntax -- same tradeoff (creme
;; hash-table)'s own hash-table-ref/-set! already make for "a bag of
;; named values."
;;
;;   (make-ostruct alist)      -> a new <ostruct> record, one field per
;;                                (name . value) pair in alist (name a
;;                                symbol)
;;   (ostruct (name val) ...)  -> a defmacro: sugar for (make-ostruct
;;                                (list (cons 'name val) ...)) -- fields
;;                                are literal identifiers at the call
;;                                site, folded into quoted symbols; val
;;                                is any expression, evaluated normally
;;   (ostruct? x)
;;   (ostruct-ref o field)          -> field's value, or #f if o has no
;;                                     such field (matching Ruby's
;;                                     OpenStruct, where reading an unset
;;                                     attribute returns nil rather than
;;                                     raising -- unlike (creme
;;                                     hash-table)'s own hash-table-ref,
;;                                     which raises with no default given)
;;   (ostruct-ref o field default)  -> field's value, or default verbatim
;;                                     if unset -- default is used as-is,
;;                                     even if it happens to be a
;;                                     procedure (unlike hash-table-ref's
;;                                     own lazy-thunk convention): a field
;;                                     literally holding a procedure value
;;                                     is an ordinary case for a dynamic
;;                                     attribute bag, and auto-calling a
;;                                     procedure default would misfire on
;;                                     that case silently
;;   (ostruct-set! o field value)   -> sets/overwrites field, in place
;;   (ostruct-delete! o field)      -> removes field, in place (no-op if
;;                                     unset)
;;   (ostruct->alist o)             -> o's fields as a (name . value)
;;                                     alist (order unspecified, same as
;;                                     (creme hash-table)'s own
;;                                     hash-table->alist)
;;   (ostruct-each o proc)          -> calls (proc name value) for each
;;                                     field, for effect
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme ostruct)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme ostruct)
  (export make-ostruct ostruct ostruct? ostruct-ref ostruct-set!
          ostruct-delete! ostruct->alist ostruct-each)
  (import (scheme base) (creme hash-table))
  (begin
    (define-record-type <ostruct>
      (make-ostruct-record table)
      ostruct?
      (table ostruct-table))

    (define (make-ostruct alist)
      (let ((h (make-hash-table)))
        (for-each (lambda (kv) (hash-table-set! h (car kv) (cdr kv))) alist)
        (make-ostruct-record h)))

    (defmacro ostruct fields
      (list 'make-ostruct
            (cons 'list
                  (map (lambda (clause) (list 'cons (list 'quote (car clause)) (cadr clause)))
                       fields))))

    (define (ostruct-ref o field . default)
      (hash-table-ref (ostruct-table o) field
                       (lambda () (if (null? default) #f (car default)))))

    (define (ostruct-set! o field value) (hash-table-set! (ostruct-table o) field value))
    (define (ostruct-delete! o field) (hash-table-delete! (ostruct-table o) field))
    (define (ostruct->alist o) (hash-table->alist (ostruct-table o)))
    (define (ostruct-each o proc)
      (for-each (lambda (kv) (proc (car kv) (cdr kv))) (ostruct->alist o)))))
