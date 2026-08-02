;; (scheme char): thin re-export frontend over (creme builtin char)
(define-library (scheme char)
  (import (creme builtin char))
  (export char-alphabetic? char-ci<=? char-ci<? char-ci=? char-ci>=? char-ci>?
          char-downcase char-foldcase char-lower-case? char-numeric?
          char-upcase char-upper-case? char-whitespace? digit-value
          string-ci<=? string-ci<? string-ci=? string-ci>=? string-ci>?
          string-downcase string-foldcase string-upcase))
