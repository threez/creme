(import (scheme base) (scheme write) (creme random))

(define (range-list a b) (if (>= a b) '() (cons a (range-list (+ a 1) b))))
(define (reduce-list f init lst)
  (if (null? lst) init (reduce-list f (f init (car lst)) (cdr lst))))

; random-integer draws from [0, n) — offset by lo and widen n by 1 for an
; inclusive [lo, hi] range.
(define (random-int lo hi) (+ lo (random-integer (+ 1 (- hi lo)))))

(define (roll-die) (random-int 1 6))

(define (roll-dice n) (map (lambda (_) (roll-die)) (range-list 0 n)))

(define (tally rolls)
  (let ((counts (make-vector 7 0)))
    (for-each (lambda (r) (vector-set! counts r (+ 1 (vector-ref counts r)))) rolls)
    counts))

(random-seed! 7)
(define rolls (roll-dice 20))
(display "Rolled: ") (display rolls) (newline)
(display "Sum: ") (display (reduce-list + 0 rolls)) (newline)
(display "Tally (index = face value, 0 unused): ") (display (tally rolls)) (newline)
