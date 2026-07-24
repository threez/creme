(import (scheme base) (scheme write) (scheme time) (creme memoize))

;; The naive recursive fib: exponential, since fib(n) re-derives fib(n-1)
;; and fib(n-2) from scratch, and those overlap massively.
(define (fib n)
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))

;; Pitfall: memoizing only the top-level call doesn't help a fresh n --
;; fib's OWN recursive calls still go to the un-memoized `fib` above, so
;; this does exactly as much work as naive fib the first time it sees any
;; given n. It only pays off on a repeat call with that same n.
(define cached-fib-naive (memoize fib))

;; The actual fix: fib has to recurse THROUGH the memoized wrapper, not
;; just be wrapped by one. By hand, that means a forward-reference dance:
;;   (define fib-memo #f)
;;   (define (fib-inner n) (if (< n 2) n (+ (fib-memo (- n 1)) (fib-memo (- n 2)))))
;;   (set! fib-memo (memoize fib-inner))
;; so fib-inner's own recursive calls resolve to the memoized version only
;; once fib-memo has been set! -- collapsing the exponential tree of
;; overlapping subproblems into O(n) distinct calls. define-memoize is
;; sugar for exactly that dance: the name being defined is what its own
;; body should recurse through, so it's simply used directly.
(define-memoize (fib-memo n)
  (if (< n 2) n (+ (fib-memo (- n 1)) (fib-memo (- n 2)))))

(define (elapsed-ms thunk)
  (define start (current-jiffy))
  (define result (thunk))
  (define ms (* 1000.0 (/ (- (current-jiffy) start) (jiffies-per-second))))
  (list result ms))

(define (report label thunk)
  (define result+ms (elapsed-ms thunk))
  (display label) (display ": ") (display (car result+ms))
  (display " in ") (display (cadr result+ms)) (display "ms") (newline))

(display "--- fib(27) ---") (newline)
(report "naive fib" (lambda () (fib 27)))
(report "memoize(fib), 1st call at this n (the pitfall: no help)" (lambda () (cached-fib-naive 27)))
(report "memoize(fib), 2nd call at the SAME n (a pure cache hit)" (lambda () (cached-fib-naive 27)))
(report "self-referential memoized fib" (lambda () (fib-memo 27)))
(newline)

(display "--- fib(33): the naive O(2^n) blowup really shows here ---") (newline)
(report "naive fib" (lambda () (fib 33)))
(report "self-referential memoized fib" (lambda () (fib-memo 33)))
(newline)

(display "--- fib(50): infeasible naively, still trivial memoized ---") (newline)
(report "self-referential memoized fib" (lambda () (fib-memo 50)))
