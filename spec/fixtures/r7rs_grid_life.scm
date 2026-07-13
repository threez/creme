; R7RS spec's own define-library example (section 5.6): a library exports a
; procedure renamed as `set!`, and importing code excludes the base `set!`
; special form in favor of the renamed one. Used by
; spec/scheme/interpreter/library_spec.cr to verify special forms are
; genuinely shadowable/renameable identifiers, not hardcoded syntax that
; import/export/rename can't touch.
(define-library (test grid)
  (export make rows cols ref put! each)
  (import (scheme base))
  (begin
    (define (make n m)
      (let ((grid (make-vector n)))
        (do ((i 0 (+ i 1)))
            ((= i n) grid)
          (let ((v (make-vector m #f)))
            (vector-set! grid i v)))))
    (define (rows grid) (vector-length grid))
    (define (cols grid) (vector-length (vector-ref grid 0)))
    (define (ref grid n m)
      (and (< -1 n (rows grid))
           (< -1 m (cols grid))
           (vector-ref (vector-ref grid n) m)))
    (define (put! grid n m v)
      (vector-set! (vector-ref grid n) m v))
    (define (each grid proc)
      (do ((j 0 (+ j 1)))
          ((= j (rows grid)))
        (do ((k 0 (+ k 1)))
            ((= k (cols grid)))
          (proc j k (ref grid j k)))))))

(import (except (test grid) put!) (rename (test grid) (put! set!)))
(define g (make 3 3))
(set! g 1 1 'alive)
(display (ref g 1 1))
(newline)
(display (ref g 0 0))
(newline)
