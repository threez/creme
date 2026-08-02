;; ===========================================================================
;; (creme numfmt): fixed-decimal and ratio number formatting
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme sxql)/(creme extra) use) rather than compiled into the interpreter
;; binary, since every export here is expressible in plain R7RS with no
;; opaque foreign object, stateful handle, or third-party Crystal library
;; involved — see modules/creme/extra.sld's own header comment for the same
;; rationale.
;;
;; Named numfmt, not format: (creme format) already exists as a Crystal-
;; native module (src/creme/modules/format.cr) providing SRFI-28-style
;; printf directives (~a/~s/~c/~d/~x/~o/~b) — a different, unrelated job
;; (arbitrary-value interpolation into a template string) with no fixed-
;; decimal or ratio support. This module doesn't extend or replace it.
;;
;; Not auto-imported anywhere — every script that wants numfmt-fixed/
;; numfmt-ratio must (import (creme numfmt)) explicitly, same as any other
;; file-based library.
;; ===========================================================================

(define-library (creme numfmt)
  (export numfmt-fixed numfmt-ratio)
  (import (scheme base))
  (begin
    ;; (numfmt-fixed x decimals) — x formatted to a fixed number of decimal
    ;; places (e.g. (numfmt-fixed 3.14159 2) => "3.14"), or "n/a" if x is #f
    ;; (the "value unavailable" convention this module's callers use).
    (define (numfmt-fixed x decimals)
      (if (not x)
          "n/a"
          (let* ((scale (expt 10 decimals))
                 (scaled (exact (round (* x scale))))
                 (int-part (quotient scaled scale))
                 (frac-part (remainder scaled scale))
                 (frac-str (number->string frac-part)))
            (string-append (number->string int-part) "."
                            (make-string (- decimals (string-length frac-str)) #\0)
                            frac-str))))

    ;; (numfmt-ratio num denom) — "N.Nx", or "n/a" if either side is #f or
    ;; denom is 0 (avoids a division by zero rather than raising).
    (define (numfmt-ratio num denom)
      (if (or (not num) (not denom) (= denom 0))
          "n/a"
          (string-append (numfmt-fixed (/ num denom) 1) "x")))))
