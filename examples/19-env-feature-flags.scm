(import (scheme base) (scheme write) (creme env) (creme string))

(set-environment-variable! "CREME_EXAMPLE_FEATURES" "dark-mode, beta-search,  export-csv")

(define (enabled-features)
  (map string-trim (string-split (get-environment-variable "CREME_EXAMPLE_FEATURES") ",")))

(define (feature-enabled? name) (if (member name (enabled-features)) #t #f))

(define features-to-check (list "dark-mode" "beta-search" "old-ui" "export-csv"))

(for-each
  (lambda (f) (display f) (display ": ") (display (if (feature-enabled? f) "ON" "off")) (newline))
  features-to-check)

(delete-environment-variable! "CREME_EXAMPLE_FEATURES")
