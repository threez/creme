; Prints each bench/workloads.scm workload's result plus its wall-clock time
; via (scheme time)'s current-second (R7RS's minimal time contract), then a
; "total = ...s" line — the plain-text bench/creme.scm and bench/racket.scm
; output that bench/bench.scm's own parse-elapsed-alist regexp expects.
;
; A separate file from workloads.scm itself (included right after it, not
; folded in) so that bench/prof.scm — which (include "workloads.scm") only
; to profile those same definitions — doesn't also pay for and print this
; demo run first; it has its own profiling report to produce instead.

(define (timed-run name thunk)
  (let* ((start (current-second))
         (result (thunk))
         (elapsed (- (current-second) start)))
    (display name) (display " = ") (display result)
    (display "  (") (display elapsed) (display "s)")
    (newline)
    result))

(define total-start (current-second))

(timed-run "fib(27)" (lambda () (fib 27)))
(timed-run "sum-to(2000000)" (lambda () (sum-to 2000000 0)))
(timed-run "build-list(200000) length+reverse" (lambda () (length (reverse (build-list 200000)))))
(timed-run "vector-sum-test(500000)" (lambda () (vector-sum-test 500000)))
(timed-run "string-build-test(4000) length" (lambda () (string-build-test 4000)))

(display "total = ") (display (- (current-second) total-start)) (display "s") (newline)
