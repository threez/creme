(define (fact n) (if (<= n 1) 1 (* n (fact (- n 1)))))
(println "factorial 10 = " (fact 10))

(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(println "fib 20 = " (fib 20))

(define (make-counter)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(println "counter: " (c) " " (c) " " (c))

(define (make-adder n) (lambda (x) (+ x n)))
(println "make-adder 3 applied to 4 = " ((make-adder 3) 4))

(println "map square: " (map (lambda (x) (* x x)) '(1 2 3 4)))
(println "filter >2: " (filter (lambda (x) (> x 2)) '(1 2 3 4)))
(println "reduce +: " (reduce + 0 '(1 2 3 4 5)))

(println "let: " (let ((a 1) (b 2)) (+ a b)))
(println "let*: " (let* ((a 1) (b (+ a 1))) (* a b)))

(define (sign x)
  (cond ((> x 0) 'positive) ((< x 0) 'negative) (else 'zero)))
(println "sign -5 = " (sign -5))

(println "even? 10 = " (even? 10))
(println "odd? 7 = " (odd? 7))

(define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n))))
(println "tail-recursive sum-to 100000 = " (sum-to 100000 0))

(println "mixed arithmetic: " (+ 1 2.5 3))
(println "comparison chain (< 1 2 3): " (< 1 2 3))
(println "and short-circuit: " (and 1 2 3))
(println "or short-circuit: " (or #f #f 7))

(println "quasiquote: " `(1 ,(+ 1 1) ,@(list 3 4)))
(println "list ops: " (append '(1 2) '(3 4)) " len=" (length '(a b c)) " rev=" (reverse '(1 2 3)))