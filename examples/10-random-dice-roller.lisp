(require 'random)

(define (roll-die) (random:int 1 6))

(define (roll-dice n) (map (lambda (_) (roll-die)) (range 0 n)))

(define (tally rolls)
  (let ((counts (make-vector 7 0)))
    (for-each (lambda (r) (vector-set! counts r (+ 1 (vector-ref counts r)))) rolls)
    counts))

(random:seed 7)
(define rolls (roll-dice 20))
(println "Rolled: " rolls)
(println "Sum: " (reduce + 0 rolls))
(println "Tally (index = face value, 0 unused): " (tally rolls))
