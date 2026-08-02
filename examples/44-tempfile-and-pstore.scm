(import (scheme base) (scheme write) (creme tempfile) (creme pstore) (creme file))

;; call-with-tempfile: a scratch file that cleans itself up, even if the
;; body raises -- here we just write some scratch data and read it back.
(call-with-tempfile
 "creme-example"
 (lambda (t)
   (write-string "line one\nline two\n" (tempfile-port t))
   (tempfile-close! t)
   (display "tempfile contents:") (newline)
   (display (file-read (tempfile-path t)))
   (newline)))
;; t's file is now deleted -- cleaned up automatically on return.

;; pstore: a tiny persistent key-value store, one file, S-expression
;; serialized. Use a tempfile's path as the store's backing file, but
;; manage its lifetime ourselves since pstore, not tempfile, owns it now.
;; call-with-tempfile already deletes the file itself once the body
;; returns -- we only wanted a guaranteed-unique, already-cleaned-up path.
(define store-path
  (call-with-tempfile "creme-store" (lambda (t) (tempfile-path t))))

(define store (pstore-open store-path))
(pstore-transaction! store
  (lambda (s)
    (pstore-set! s 'visits 1)
    (pstore-set! s 'last-user "alice")))

;; Re-open the same path fresh, to prove the data actually persisted.
(define reopened (pstore-open store-path))
(display "visits: ") (display (pstore-ref reopened 'visits)) (newline)
(display "last-user: ") (display (pstore-ref reopened 'last-user)) (newline)

;; An aborted transaction leaves the store untouched.
(pstore-transaction! reopened
  (lambda (s)
    (pstore-set! s 'visits 999)
    (pstore-abort!)))
(display "visits after aborted transaction: ")
(display (pstore-ref (pstore-open store-path) 'visits))
(newline)

(delete-file store-path)
