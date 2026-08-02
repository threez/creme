;; ===========================================================================
;; (creme pstore): a single-file persistent key-value store, matching
;; Ruby's PStore
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme tempfile)/(creme logger) use) since every export here is
;; expressible in plain R7RS over (creme hash-table) and this project's
;; own `write`/`read` (which already round-trip any Scheme datum
;; verbatim -- exactly what a "serialization format" needs, so this
;; library needs no bespoke format of its own), with no opaque foreign
;; object or third-party Crystal library involved.
;;
;;   (pstore-open path)   -> a new <pstore> backed by path: if path
;;                           already exists, its single alist datum
;;                           (`((key . value) ...)`, as written by an
;;                           earlier commit) is loaded via `read`;
;;                           otherwise the store starts empty. Reading
;;                           and writing only happen at pstore-open/
;;                           pstore-transaction! time, never per-key --
;;                           between transactions, everything lives in
;;                           an ordinary in-memory (creme hash-table).
;;   (pstore? x)
;;   (pstore-transaction! store proc)
;;                        -> calls (proc store); on a NORMAL return, the
;;                           store's entire current key/value table is
;;                           written back to path (a commit, overwriting
;;                           the whole file every time -- there's no
;;                           incremental/append format here), and proc's
;;                           own return value is pstore-transaction!'s
;;                           return value. If proc calls (pstore-abort!)
;;                           partway through, the transaction unwinds
;;                           immediately WITHOUT committing (any
;;                           pstore-set!/-delete! calls proc already
;;                           made are silently discarded -- the on-disk
;;                           file, and the in-memory table alike, are
;;                           left exactly as they were before this
;;                           transaction started) and pstore-transaction!
;;                           returns #f. If proc raises any OTHER
;;                           exception, the transaction also doesn't
;;                           commit, and the exception propagates
;;                           onward past pstore-transaction! itself,
;;                           same as Ruby's PStore rolling back on error.
;;   (pstore-abort!)      -> see above; only meaningful called from
;;                           inside a pstore-transaction! body
;;   (pstore-ref store key)          -> key's stored value, or #f if
;;                                      unset (matching (creme ostruct)'s
;;                                      own no-default-raises convention,
;;                                      rather than (creme hash-table)'s
;;                                      hash-table-ref, which raises)
;;   (pstore-ref store key default)  -> key's stored value, or default
;;                                      verbatim if unset
;;   (pstore-set! store key value)   -> sets key in store's in-memory
;;                                      table (not yet written to disk
;;                                      until the enclosing transaction
;;                                      commits)
;;   (pstore-delete! store key)      -> removes key from store's
;;                                      in-memory table (same "not on
;;                                      disk until commit" caveat)
;;   (pstore-roots store)            -> every key currently in store, as
;;                                      a list (order unspecified, same
;;                                      as (creme hash-table)'s own
;;                                      hash-table-keys)
;;   (pstore-root? store key)        -> #t iff key is currently set
;;
;; Native `bin/creme` only -- `icecreme/icecreme`'s `read` builtin requires an
;; explicit port argument (it has no current-input-port default the way
;; native creme's `read` does), so pstore-open's `(read)` call inside
;; with-input-from-file doesn't work unmodified there; not addressed
;; here since fixing it is an icecreme builtin-arity change, out of this
;; library's own scope.
;;
;; Limitations (same honesty as (creme tempfile)'s own stated scope):
;; no file locking, so two processes committing to the same path
;; concurrently can race and clobber each other's writes -- exactly the
;; caveat Ruby's own PStore documentation gives for needing external
;; locking under concurrent access; no incremental commit (every commit
;; rewrites the entire file, so this isn't meant for a huge store with
;; frequent small updates); pstore-set!/pstore-delete! are usable outside
;; a transaction too (they just mutate the in-memory table), but nothing
;; you do outside pstore-transaction! is ever persisted to disk -- only
;; a transaction's own commit writes the file.
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme pstore)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme pstore)
  (export pstore-open pstore? pstore-transaction! pstore-abort! pstore-ref
          pstore-set! pstore-delete! pstore-roots pstore-root?)
  (import (scheme base) (scheme read) (scheme write) (creme hash-table) (creme file))
  (begin
    (define-record-type <pstore>
      (make-pstore-record path table)
      pstore?
      (path pstore-path)
      (table pstore-table))

    (define-record-type <pstore-abort-signal>
      (make-pstore-abort-signal)
      pstore-abort-signal?)

    (define (pstore-abort!) (raise (make-pstore-abort-signal)))

    (define (pstore-open path)
      (let ((table (make-hash-table)))
        (if (file-exists? path)
            (let ((datum (with-input-from-file path (lambda () (read)))))
              (if (pair? datum)
                  (for-each (lambda (kv) (hash-table-set! table (car kv) (cdr kv))) datum))))
        (make-pstore-record path table)))

    (define (pstore-priv-commit! store)
      (call-with-output-file
       (pstore-path store)
       (lambda (port) (write (hash-table->alist (pstore-table store)) port))))

    (define (pstore-transaction! store proc)
      (guard (e ((pstore-abort-signal? e) #f))
        (let ((result (proc store)))
          (pstore-priv-commit! store)
          result)))

    (define (pstore-ref store key . default)
      (hash-table-ref (pstore-table store) key (lambda () (if (null? default) #f (car default)))))

    (define (pstore-set! store key value) (hash-table-set! (pstore-table store) key value))
    (define (pstore-delete! store key) (hash-table-delete! (pstore-table store) key))
    (define (pstore-roots store) (hash-table-keys (pstore-table store)))
    (define (pstore-root? store key) (hash-table-contains? (pstore-table store) key))))
