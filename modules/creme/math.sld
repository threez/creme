;; (creme math): thin re-export frontend over (creme builtin math)
(define-library (creme math)
  (import (creme builtin math))
  (export acos asin atan atan2 bits->flonum cos e exp flonum->bits hypot
          log log10 log2 pi pow sin tan))
