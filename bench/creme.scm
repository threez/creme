; creme's own entry point for bench/workloads.scm — the counterpart to
; bench/racket.scm, run standalone as its own process by bench.scm (which
; invokes bin/creme the same way it invokes bin/bench_cr/ruby/racket, for a
; uniform 4-variant comparison).
(import (scheme base) (scheme write) (scheme inexact) (scheme time))
(include "workloads.scm")
(include "workloads-demo.scm")
