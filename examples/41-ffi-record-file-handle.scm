;; (creme ffi) + (creme foreign): the complementary "opaque handle, no
;; visible fields" pattern define-foreign-struct's byte-offset accessors
;; don't fit -- a C API like stdio's FILE* that you only ever pass BACK
;; into further calls on the same library, never peek inside yourself.
;; (creme foreign)'s define-foreign-record wraps such a pointer in a
;; genuine, distinct Scheme record type (a real per-type predicate, not
;; just the generic ffi-pointer? every wrapped pointer would otherwise
;; share), with "method"-style accessors that thread the handle in as
;; each underlying C function's first argument automatically -- (file-tell
;; f) instead of (ffi-call ftell-fn (list (unwrap f))). See
;; modules/creme/foreign.sld's own header comment for exactly what this
;; expands to and why it only fits a "handle is the first C argument"
;; API (stdio's own functions all qualify: fopen/fclose/ftell/feof/rewind
;; every one takes FILE* first, unlike e.g. strftime's trailing struct
;; tm* -- see examples/40-ffi-struct-pointer-clock.scm's own struct-field
;; approach for that other shape instead).
;;
;; SECURITY: see examples/39-ffi-libm-caller.scm's own SECURITY note.
(import (scheme base) (scheme write) (creme ffi) (creme foreign) (creme file) (creme introspection))

(define os (cdr (assq 'os (runtime))))
(define libc-soname
  (cond ((string=? os "FreeBSD") "libc.so.7")
        ((string=? os "Darwin") "libSystem.dylib")
        (else "libc.so.6")))
(define libc (ffi-open libc-soname))

;; <file> wraps a FILE*; every accessor below is a real stdio call with
;; the wrapped pointer spliced in as its first (and, here, only) argument.
(define-foreign-record <file>
  (open-file libc "fopen" pointer (string string))
  file?
  (file-close!  libc "fclose"  int32 (pointer))
  (file-eof?    libc "feof"    bool  (pointer))
  (file-tell    libc "ftell"   int64 (pointer))
  (file-getc!   libc "fgetc"   int32 (pointer))
  (file-rewind! libc "rewind"  void  (pointer)))

;; A scratch file with known, fixed content -- so file-tell's result
;; below is fully deterministic, not dependent on any file already on
;; the host.
(define scratch-path "./examples-ffi-record-scratch.txt")
(file-write scratch-path "hello, foreign record!")

(define f (open-file scratch-path "r"))
(display "file? on a real fopen() result: ") (display (file? f)) (newline)
(display "file? on an ordinary ffi-pointer (not wrapped): ") (display (file? (ffi-function libc "fopen" 'pointer '(string string)))) (newline)

(display "feof? right after opening: ") (display (file-eof? f)) (newline)
(display "ftell right after opening: ") (display (file-tell f)) (newline)

;; Read every byte via file-getc! (fgetc, another pointer-first stdio
;; call, so it fits the same accessor pattern) to move the file
;; position, then confirm ftell/feof reflect it -- all through the SAME
;; wrapped handle, never peeking at struct FILE's own (deliberately
;; unspecified) internals.
(define (drain-file! f)
  (if (= (file-getc! f) -1) 'done (drain-file! f)))
(drain-file! f)

(display "ftell after reading to EOF: ") (display (file-tell f)) (newline)
(display "feof? after reading to EOF: ") (display (file-eof? f)) (newline)

(file-rewind! f)
(display "ftell after rewind!: ") (display (file-tell f)) (newline)

(file-close! f)

;; fopen on a nonexistent path returns NULL in real libc -- propagated
;; here as plain #f, exactly like the underlying ffi-call already would,
;; never as an error.
(display "opening a nonexistent path: ") (display (open-file "/no/such/path" "r")) (newline)

(delete-file scratch-path)
(ffi-close libc)
