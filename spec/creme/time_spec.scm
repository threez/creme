;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/modules/scheme_spec.cr's own
;; "(scheme time)" cases -- see modules/creme/spec.sld's own header comment
;; for the framework this uses.
;;
;; current-second/current-jiffy/jiffies-per-second used to be a deliberate
;; icecreme gap (only (creme time)'s current-time/time-difference existed
;; natively there -- see icecreme/builtins.c's own bi_current_time). Unlike
;; every other file in this directory, this one does NOT use
;; should-match-native?: current-jiffy measures elapsed time since each
;; process's own start (icecreme's own clock_gettime(CLOCK_MONOTONIC) call vs.
;; native's Time.instant - interp.start_instant), so its absolute value
;; can never match across two independently-started processes -- the
;; native Crystal spec this is ported from (spec/scheme/modules/
;; scheme_spec.cr) asserts plausibility/monotonicity for exactly this
;; reason, not an exact expected value, and this file mirrors that.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/time_spec.scm
;;   ./bin/creme --self-hosted spec/creme/time_spec.scm
;;   ./icecreme/icecreme spec/creme/time_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme time) (creme spec))

(describe "(scheme time)"
  (it "provides current-second, current-jiffy, jiffies-per-second per R7RS's contract"
    (should-be-true? (> (jiffies-per-second) 0))
    (should-be-true? (>= (current-jiffy) 0))
    (should-be-true? (> (current-second) 0)))

  (it "current-jiffy increases monotonically"
    (define a (current-jiffy))
    (define b (current-jiffy))
    (should-be-true? (>= b a))))

(spec-summary!)
