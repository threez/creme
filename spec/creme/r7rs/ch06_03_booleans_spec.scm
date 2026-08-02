;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_03_booleans_spec.cr's
;; own cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses. The original Crystal spec evaluated each case's
;; Scheme source via a fresh sub-interpreter (run(src)/w(src)) since it was
;; testing a Scheme interpreter from OUTSIDE, as Crystal code; here, running
;; directly as Scheme, each case's forms are written and asserted directly
;; via should-equal?/should-be-true?/should-be-false? instead of comparing
;; write_string'd output against a literal string.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_03_booleans_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_03_booleans_spec.scm
;;   ./cvm/cvm spec/creme/r7rs/ch06_03_booleans_spec.scm
;; ===========================================================================

(import (scheme base) (creme spec))

(describe "R7RS §6.3 Booleans"
  (it "#t and #f are the standard boolean objects; #true/#false are alternative spellings"
    (should-be-true? #t)
    (should-be-false? #f)
    (should-be-true? #true)
    (should-be-false? #false))

  (it "not returns #t only for #f, and #f otherwise (including for '() and other Lisp-falsy-looking values)"
    (should-equal? (list (not #t) (not 3) (not (list 3)) (not #f) (not '()) (not (list)) (not 'nil))
                    (list #f #f #f #t #f #f #f)))

  (it "boolean? recognizes only #t/#f, not 0 or ()"
    (should-equal? (list (boolean? #f) (boolean? 0) (boolean? '()))
                    (list #t #f #f)))

  (it "boolean=? returns #t if all arguments are booleans and all are #t or all are #f"
    (should-be-true? (boolean=? #t #t #t))
    (should-be-false? (boolean=? #t #f))))

(spec-summary!)
