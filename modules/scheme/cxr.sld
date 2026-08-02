;; (scheme cxr): thin re-export frontend over (creme builtin cxr)
(define-library (scheme cxr)
  (import (creme builtin cxr))
  (export caaar caadr cadar caddr cdaar cdadr cddar cdddr
          caaaar caaadr caadar caaddr cadaar cadadr caddar cadddr
          cdaaar cdaadr cdadar cdaddr cddaar cddadr cdddar cddddr))
