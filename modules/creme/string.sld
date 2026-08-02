;; (creme string): thin re-export frontend over (creme builtin string)
(define-library (creme string)
  (import (creme builtin string))
  (export string-contains? string-downcase string-index-of string-join
          string-pad string-pad-right string-prefix? string-repeat
          string-replace string-reverse string-split string-suffix?
          string-translate string-trim string-upcase))
