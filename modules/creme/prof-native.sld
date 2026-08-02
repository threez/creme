;; (creme prof-native): thin re-export frontend over (creme builtin prof-native)
(define-library (creme prof-native)
  (import (creme builtin prof-native))
  (export profile profile-report? profile-top profile-total-samples
          profile-write-folded profile-write-speedscope))
