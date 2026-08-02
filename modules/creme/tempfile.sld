;; ===========================================================================
;; (creme tempfile): scratch files in the system temp directory, matching
;; Ruby's Tempfile
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme logger)/(creme uri) use) since every export here is expressible
;; in plain R7RS composing (creme env)'s TMPDIR lookup, (creme random)'s
;; random-integer, and (creme file)'s own file I/O, with no opaque foreign
;; object or third-party Crystal library of its own involved.
;;
;;   (make-tempfile)             -> a new <tempfile>: a fresh, already-
;;                                  open-for-writing file under TMPDIR (or
;;                                  /tmp if TMPDIR isn't set), named
;;                                  "tempfile-<random digits>"
;;   (make-tempfile prefix)      -> same, but named "<prefix>-<random
;;                                  digits>" instead of "tempfile-..."
;;   (tempfile? x)
;;   (tempfile-path t)           -> t's full path, as a string
;;   (tempfile-port t)           -> t's already-open output port (write
;;                                  to it directly, e.g. via display/
;;                                  write-string)
;;   (tempfile-close! t)         -> closes t's port (idempotent -- safe
;;                                  to call even if the port is already
;;                                  closed)
;;   (tempfile-unlink! t)        -> deletes t's file from disk (a no-op
;;                                  if it's already gone)
;;   (call-with-tempfile prefix proc)
;;                               -> creates a tempfile (as make-tempfile
;;                                  prefix would), calls (proc tempfile),
;;                                  and guarantees tempfile-close!+
;;                                  tempfile-unlink! afterward via
;;                                  dynamic-wind -- even if proc raises --
;;                                  Ruby's Tempfile.create block form.
;;                                  Returns proc's own return value.
;;
;; Limitation: the random suffix is the ONLY collision guard -- unlike
;; Ruby's Tempfile, there's no retry loop that notices an unlikely name
;; collision and picks a new name; a caller worried about that (e.g.
;; many thousands of tempfiles per process) should pass its own more
;; distinguishing prefix.
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme tempfile)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme tempfile)
  (export make-tempfile tempfile? tempfile-path tempfile-port
          tempfile-close! tempfile-unlink! call-with-tempfile)
  (import (scheme base) (creme env) (creme random) (creme file))
  (begin
    (define-record-type <tempfile>
      (make-tempfile-record path port)
      tempfile?
      (path tempfile-path)
      (port tempfile-port))

    (define (tempfile-priv-dir)
      (let ((d (get-environment-variable "TMPDIR")))
        (if d d "/tmp")))

    (define (make-tempfile . prefix-opt)
      (let* ((prefix (if (null? prefix-opt) "tempfile" (car prefix-opt)))
             (path (string-append (tempfile-priv-dir) "/" prefix "-" (number->string (random-integer 1000000000))))
             (port (open-output-file path)))
        (make-tempfile-record path port)))

    (define (tempfile-close! t) (close-port (tempfile-port t)))

    (define (tempfile-unlink! t)
      (if (file-exists? (tempfile-path t)) (delete-file (tempfile-path t))))

    (define (call-with-tempfile prefix proc)
      (let ((t (make-tempfile prefix)))
        (dynamic-wind
         (lambda () #f)
         (lambda () (proc t))
         (lambda () (tempfile-close! t) (tempfile-unlink! t)))))))
