;; (creme time): thin re-export frontend over (creme builtin time)
;; (the richer, creme-only family — see modules/scheme/time.sld for the
;; small R7RS (scheme time) SRFI-170-ish subset, which is actually a
;; DIFFERENT native family, "scheme-time", not this one).
(define-library (creme time)
  (import (creme builtin time))
  (export current-time string->time time->string time-add time-day
          time-difference time-hour time-minute time-month time-second
          time-year))
