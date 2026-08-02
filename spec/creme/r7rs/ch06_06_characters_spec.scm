;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_06_characters_spec.cr's
;; own cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses. The original Crystal spec evaluated each case's
;; Scheme source via a fresh sub-interpreter (run(src)/w(src)) since it was
;; testing a Scheme interpreter from OUTSIDE, as Crystal code; here, running
;; directly as Scheme, each case's forms are written and asserted directly
;; via should-equal?/should-be-true?/should-be-false? instead of comparing
;; write_string'd output against a literal string.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_06_characters_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_06_characters_spec.scm
;;   ./icecreme/icecreme spec/creme/r7rs/ch06_06_characters_spec.scm
;; ===========================================================================

(import (scheme base) (scheme char) (creme spec))

(describe "R7RS §6.6 Characters"
  (it "char? is #t for character objects"
    (should-be-true? (char? #\a))
    (should-be-false? (char? 97)))

  (it "char=?/char<?/etc. compare characters via their integer scalar values"
    (should-be-true? (char=? #\A #\A))
    (should-be-true? (char<? #\a #\b)))

  (it "char->integer/integer->char convert between a character and its Unicode scalar value"
    (should-equal? (char->integer #\a) 97)
    (should-eqv? (integer->char 97) #\a))

  (it "the named characters newline/return/space/tab are supported"
    (should-equal? (char->integer #\newline) 10)
    (should-equal? (char->integer #\return) 13)
    (should-equal? (char->integer #\space) 32)
    (should-equal? (char->integer #\tab) 9))

  (it "the remaining 5 required named characters alarm/backspace/delete/escape/null are also supported"
    (should-equal? (list (char->integer #\alarm) (char->integer #\backspace) (char->integer #\delete)
                          (char->integer #\escape) (char->integer #\null))
                    (list 7 8 127 27 0)))

  (it "#\\x<hex-scalar-value> reads a character by its Unicode hex scalar value"
    (should-equal? (char->integer #\x03B1) 945)
    (should-equal? (char->integer #\x41) 65))

  (it "bare #\\x with no following hex digit is the ordinary letter x"
    (should-equal? (char->integer #\x) 120))

  (it "ordinary printing characters like #\\a, #\\A, #\\( are self-evaluating literals"
    (should-equal? (list #\a #\A #\() (list #\a #\A #\()))

  (describe "R7RS §6.6 Characters (via (scheme char))"
    (it "char-ci=?/char-upcase/char-downcase/char-foldcase are case-insensitive/case-converting"
      (should-equal? (list (char-ci=? #\A #\a) (char-upcase #\a) (char-downcase #\A) (char-foldcase #\A))
                      (list #t #\A #\a #\a)))

    (it "char-alphabetic?/char-numeric?/char-whitespace?/char-upper-case?/char-lower-case? classify characters"
      (should-equal? (list (char-alphabetic? #\a) (char-numeric? #\3) (char-whitespace? #\space)
                            (char-upper-case? #\A) (char-lower-case? #\a))
                      (list #t #t #t #t #t)))

    (it "digit-value returns a decimal digit character's numeric value, #f for non-digits"
      (should-equal? (digit-value #\3) 3)
      (should-be-false? (digit-value #\a)))))

(spec-summary!)
