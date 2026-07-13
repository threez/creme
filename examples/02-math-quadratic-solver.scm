(import (scheme base) (scheme write) (scheme inexact) (creme math))

(define (quadratic-roots a b c)
  (let ((discriminant (- (pow b 2) (* 4 a c))))
    (cond
      ((< discriminant 0) (list 'no-real-roots))
      ((= discriminant 0) (list (/ (- b) (* 2 a))))
      (else
        (let ((sq (sqrt discriminant)))
          (list (/ (+ (- b) sq) (* 2 a))
                (/ (- (- b) sq) (* 2 a))))))))

(define (report a b c)
  (display "Solving ") (display a) (display "x^2 + ") (display b) (display "x + ") (display c) (display " = 0") (newline)
  (display "  Roots: ") (display (quadratic-roots a b c)) (newline))

(report 1 -3 2)
(report 1 2 1)
(report 1 0 1)
