#lang r7rs
;; Racket counterpart of bench/bench.scm's own workload run: same imports,
;; same (include "workloads.scm")/(include "workloads-demo.scm") — a single
;; source of truth for what's actually benchmarked, so the two never drift
;; apart.
(import (scheme base) (scheme write) (scheme inexact) (scheme time))
(include "workloads.scm")
(include "workloads-demo.scm")
