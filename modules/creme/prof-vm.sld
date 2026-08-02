;; (creme prof-vm): thin re-export frontend over (creme builtin prof-vm)
(define-library (creme prof-vm)
  (import (creme builtin prof-vm))
  (export profile-scheme profile-scheme-report? profile-scheme-top
          profile-scheme-total-samples))
