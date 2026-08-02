;; (creme http): thin re-export frontend over (creme builtin http)
(define-library (creme http)
  (import (creme builtin http))
  (export http-delete http-get http-head http-patch http-post http-put
          http-request))
