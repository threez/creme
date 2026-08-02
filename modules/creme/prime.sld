;; ===========================================================================
;; (creme prime): primality testing, factorization, prime enumeration
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme set)/(creme tsort) use) since every export here is expressible in
;; plain R7RS arithmetic, with no opaque foreign object or third-party
;; Crystal library involved.
;;
;;   (prime? n)          -> #t iff n is a prime exact integer (n < 2 is
;;                          never prime)
;;   (next-prime n)      -> the smallest prime strictly greater than n
;;   (prime-factors n)   -> n's prime factorization as a list of
;;                          (base . exponent) pairs, ascending by base,
;;                          e.g. (prime-factors 360) -> ((2 . 3) (3 . 2)
;;                          (5 . 1)); (prime-factors 1) -> '() (1 has no
;;                          prime factors); n must be >= 1
;;   (primes-upto n)     -> every prime <= n, ascending, via the Sieve of
;;                          Eratosthenes
;;
;; Implementation is plain trial division (prime?/prime-factors check
;; candidate divisors only up to sqrt(n), and only 2 plus odd numbers
;; beyond that) -- O(sqrt n) per call, not Miller-Rabin or any other
;; probabilistic test. Fine for ordinary integers; a cryptographic-scale
;; number (hundreds of digits) would be impractically slow here -- this
;; library makes no attempt at that use case. Only exact integers are
;; accepted (this project's numeric tower's inexact/rational/complex
;; numbers, and (creme bigdecimal) values, are all out of scope -- pass
;; exact-integer? values only).
;; ===========================================================================

(define-library (creme prime)
  (export prime? next-prime prime-factors primes-upto)
  (import (scheme base))
  (begin
    (define (prime-priv-divides? d n) (= 0 (remainder n d)))

    (define (prime? n)
      (cond
       ((< n 2) #f)
       ((= n 2) #t)
       ((prime-priv-divides? 2 n) #f)
       (else
        (let loop ((d 3))
          (cond
           ((> (* d d) n) #t)
           ((prime-priv-divides? d n) #f)
           (else (loop (+ d 2))))))))

    (define (next-prime n)
      (let loop ((candidate (+ n 1)))
        (if (prime? candidate) candidate (loop (+ candidate 1)))))

    (define (prime-factors n)
      (if (< n 1) (error "prime-factors: n must be >= 1" n))
      (let loop ((remaining n) (d 2) (factors '()))
        (cond
         ((= remaining 1) (reverse factors))
         ((> (* d d) remaining)
          (reverse (cons (cons remaining 1) factors)))
         ((prime-priv-divides? d remaining)
          (let count-loop ((r remaining) (exp 0))
            (if (prime-priv-divides? d r)
                (count-loop (quotient r d) (+ exp 1))
                (loop r (+ d 1) (cons (cons d exp) factors)))))
         (else (loop remaining (+ d 1) factors)))))

    (define (primes-upto n)
      (if (< n 2)
          '()
          (let ((sieve (make-vector (+ n 1) #t)))
            (vector-set! sieve 0 #f)
            (vector-set! sieve 1 #f)
            (let loop ((i 2))
              (if (<= (* i i) n)
                  (begin
                    (if (vector-ref sieve i)
                        (let mark-loop ((m (* i i)))
                          (if (<= m n)
                              (begin (vector-set! sieve m #f) (mark-loop (+ m i))))))
                    (loop (+ i 1)))))
            (let collect-loop ((i 2) (acc '()))
              (if (> i n)
                  (reverse acc)
                  (collect-loop (+ i 1) (if (vector-ref sieve i) (cons i acc) acc)))))))))
