(require 'math)

(define (quadratic-roots a b c)
  (let ((discriminant (- (math:pow b 2) (* 4 a c))))
    (cond
      ((< discriminant 0) (list 'no-real-roots))
      ((= discriminant 0) (list (/ (- b) (* 2 a))))
      (else
        (let ((sq (sqrt discriminant)))
          (list (/ (+ (- b) sq) (* 2 a))
                (/ (- (- b) sq) (* 2 a))))))))

(define (report a b c)
  (println "Solving " a "x^2 + " b "x + " c " = 0")
  (println "  Roots: " (quadratic-roots a b c)))

(report 1 -3 2)
(report 1 2 1)
(report 1 0 1)
