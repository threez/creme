; Standalone microbenchmark for cvm's OP_QCALLGLOBAL_RECACC (cvm/vm.c) --
; measures the effect of quickening a define-record-type field accessor's
; call site, the same way doc/optimization-cvm.md's own "Call-site
; quickening for primitive calls" section measured the +/-/*/cons/car/cdr
; work. NOT wired into competition/bench.scm's cross-language suite: this
; is a cvm-only runtime behavior (no other backend here has an equivalent
; to compare against), not a cross-language comparison, same reasoning as
; why that original microbenchmark was never folded into workloads.scm
; either.
;
; Run standalone, before and after cvm/vm.c's quickening change, comparing
; the printed elapsed time (rebuild cvm/cvm between runs -- the .cvmc this
; produces doesn't change, only how cvm executes it does):
;   ./bin/creme --emit-cvm competition/bench/record-accessor-quicken.scm /tmp/recacc.cvmc
;   ./cvm/cvm /tmp/recacc.cvmc
;
; Also runs directly under creme itself (no quickening there -- this is a
; cvm-only mechanism -- so this number is just a reference point, not
; expected to move):
;   ./bin/creme competition/bench/record-accessor-quicken.scm

(import (scheme base) (scheme write) (scheme time))

(define-record-type point (make-point x y) point? (x point-x) (y point-y))

(define (sum-fields n p acc)
  (if (= n 0) acc (sum-fields (- n 1) p (+ acc (point-x p) (point-y p)))))

(define p (make-point 3 4))
(define iterations 20000000)

(define start (current-second))
(define result (sum-fields iterations p 0))
(define elapsed (- (current-second) start))

(display "sum-fields(") (display iterations) (display ") = ") (display result)
(display "  (") (display elapsed) (display "s)") (newline)
