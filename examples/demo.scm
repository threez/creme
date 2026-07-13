(import (scheme base) (scheme write))

(define (filter-list pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (filter-list pred (cdr lst))))
        (else (filter-list pred (cdr lst)))))
(define (reduce-list f init lst)
  (if (null? lst) init (reduce-list f (f init (car lst)) (cdr lst))))

(define (fact n) (if (<= n 1) 1 (* n (fact (- n 1)))))
(display "factorial 10 = ") (display (fact 10)) (newline)

(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(display "fib 20 = ") (display (fib 20)) (newline)

(define (make-counter)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(display "counter: ") (display (c)) (display " ") (display (c)) (display " ") (display (c)) (newline)

(define (make-adder n) (lambda (x) (+ x n)))
(display "make-adder 3 applied to 4 = ") (display ((make-adder 3) 4)) (newline)

(display "map square: ") (display (map (lambda (x) (* x x)) '(1 2 3 4))) (newline)
(display "filter >2: ") (display (filter-list (lambda (x) (> x 2)) '(1 2 3 4))) (newline)
(display "reduce +: ") (display (reduce-list + 0 '(1 2 3 4 5))) (newline)

(display "let: ") (display (let ((a 1) (b 2)) (+ a b))) (newline)
(display "let*: ") (display (let* ((a 1) (b (+ a 1))) (* a b))) (newline)

(define (sign x)
  (cond ((> x 0) 'positive) ((< x 0) 'negative) (else 'zero)))
(display "sign -5 = ") (display (sign -5)) (newline)

(display "even? 10 = ") (display (even? 10)) (newline)
(display "odd? 7 = ") (display (odd? 7)) (newline)

(define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n))))
(display "tail-recursive sum-to 100000 = ") (display (sum-to 100000 0)) (newline)

(display "mixed arithmetic: ") (display (+ 1 2.5 3)) (newline)
(display "comparison chain (< 1 2 3): ") (display (< 1 2 3)) (newline)
(display "and short-circuit: ") (display (and 1 2 3)) (newline)
(display "or short-circuit: ") (display (or #f #f 7)) (newline)

(display "quasiquote: ") (display `(1 ,(+ 1 1) ,@(list 3 4))) (newline)
(display "list ops: ") (display (append '(1 2) '(3 4))) (display " len=") (display (length '(a b c))) (display " rev=") (display (reverse '(1 2 3))) (newline)
