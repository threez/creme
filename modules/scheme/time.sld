;; (scheme time): thin re-export frontend over (creme builtin scheme-time)
;; (the "scheme-time" native name disambiguates from the unrelated,
;; richer (creme time) family — see modules/creme/time.sld).
(define-library (scheme time)
  (import (creme builtin scheme-time))
  (export current-jiffy current-second jiffies-per-second))
