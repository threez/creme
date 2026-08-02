(import (scheme base) (scheme write) (creme matrix))

(define a (matrix '(1 2) '(3 4)))
(define b (matrix '(5 6) '(7 8)))

(display "a = ") (display (matrix->list a)) (newline)
(display "b = ") (display (matrix->list b)) (newline)
(newline)

(display "a + b = ") (display (matrix->list (matrix-add a b))) (newline)
(display "a * b = ") (display (matrix->list (matrix-multiply a b))) (newline)
(display "transpose(a) = ") (display (matrix->list (matrix-transpose a))) (newline)
(display "trace(a) = ") (display (matrix-trace a)) (newline)
(display "det(a) = ") (display (matrix-determinant a)) (newline)
(newline)

(display "identity(3) = ") (display (matrix->list (matrix-identity 3))) (newline)
(display "2 * a = ") (display (matrix->list (matrix-scale a 2))) (newline)
