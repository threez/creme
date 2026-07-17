;; GNU Guile counterpart of bench/creme.scm/bench/racket.scm's own workload
;; run: same imports, same (include "workloads.scm")/(include
;; "workloads-demo.scm") — one source of truth for what's benchmarked, so no
;; variant drifts from the others. Run standalone as its own process by
;; bench.scm (which invokes `guile` the same way it invokes racket/ruby).
(import (scheme base) (scheme write) (scheme inexact) (scheme time))
(include "workloads.scm")
(include "workloads-demo.scm")
