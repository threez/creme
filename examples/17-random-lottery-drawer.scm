(import (scheme base) (scheme write) (creme random))

(define participants
  (list "Alice" "Bob" "Carol" "Dave" "Erin" "Frank" "Grace" "Heidi"))

(define (draw-winners names count)
  (define (pick remaining n winners)
    (if (or (= n 0) (null? remaining))
        (reverse winners)
        (pick (cdr remaining) (- n 1) (cons (car remaining) winners))))
  (pick (random-shuffle names) count '()))

(random-seed! 2026)
(display "Participants: ") (display participants) (newline)
(display "Winners (top 3): ") (display (draw-winners participants 3)) (newline)
