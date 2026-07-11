(require 'env)
(require 'string)

(env:set! "CRISP_EXAMPLE_FEATURES" "dark-mode, beta-search,  export-csv")

(define (enabled-features)
  (map string:trim (string:split (env:get "CRISP_EXAMPLE_FEATURES") ",")))

(define (feature-enabled? name) (if (member name (enabled-features)) #t #f))

(define features-to-check (list "dark-mode" "beta-search" "old-ui" "export-csv"))

(for-each
  (lambda (f) (println f ": " (if (feature-enabled? f) "ON" "off")))
  features-to-check)

(env:delete! "CRISP_EXAMPLE_FEATURES")
