; dynamic-wind: guaranteed before/after thunks around a body, even when it
; exits early via a call/cc escape or an uncaught error -- useful for
; resource-acquisition-style cleanup that must run no matter how the body
; leaves. Tracks a stack of "open resources" as a poor man's leak detector.

(import (scheme base) (scheme write))

(define open-resources '())

(define (with-resource name thunk)
  (dynamic-wind
    (lambda ()
      (set! open-resources (cons name open-resources))
      (display "opened ") (display name) (newline))
    thunk
    (lambda ()
      (set! open-resources (cdr open-resources))
      (display "closed ") (display name) (newline))))

; Normal completion: opens and closes in order.
(with-resource 'file-a
  (lambda ()
    (with-resource 'file-b
      (lambda () (display "  working with both open") (newline)))))
(display "resources still open: ") (display open-resources) (newline)
(newline)

; Early exit via call/cc: the resource still gets closed even though the
; body never reaches its own end.
(call/cc (lambda (abort)
  (with-resource 'file-c
    (lambda ()
      (display "  about to bail out early") (newline)
      (abort 'bailed)
      (display "  this line never runs") (newline)))))
(display "resources still open: ") (display open-resources) (newline)
(newline)

; An error inside the body still triggers cleanup before the error
; propagates to the guard.
(display
  (guard (e (#t (list 'caught (error-object-message e))))
    (with-resource 'file-d
      (lambda () (error "boom, something went wrong")))))
(newline)
(display "resources still open: ") (display open-resources) (newline)
