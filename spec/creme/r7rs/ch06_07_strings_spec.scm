;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_07_strings_spec.cr's
;; own cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses. The original Crystal spec evaluated each case's
;; Scheme source via a fresh sub-interpreter (run(src)/w(src)) since it was
;; testing a Scheme interpreter from OUTSIDE, as Crystal code; here, running
;; directly as Scheme, each case's forms are written and asserted directly
;; via should-equal?/should-be-true?/should-be-false? instead of comparing
;; write_string'd output against a literal string.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_07_strings_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_07_strings_spec.scm
;;   ./icecreme/icecreme spec/creme/r7rs/ch06_07_strings_spec.scm
;; ===========================================================================

(import (scheme base) (scheme char) (creme spec))

(describe "R7RS §6.7 Strings"
  (it "string? is #t for string objects"
    (should-be-true? (string? "abc"))
    (should-be-false? (string? 'abc)))

  (it "make-string returns a newly allocated string of length k, optionally filled with char"
    (should-equal? (make-string 3 #\a) "aaa"))

  (it "string returns a newly allocated string composed of its char arguments, analogous to list"
    (should-equal? (string #\a #\b #\c) "abc")
    (should-equal? (string) ""))

  (it "string-length returns the number of characters in the string"
    (should-equal? (string-length "abc") 3))

  (it "string-ref returns the character at a zero-origin index"
    (should-eqv? (string-ref "abc" 1) #\b))

  (it "string-set! stores char in element k of string"
    (let ((s (make-string 3 #\*)))
      (string-set! s 0 #\?)
      (should-equal? s "?**")))

  (it "string=?/string-ci=? compare strings for equality (case-sensitive/insensitive)"
    (should-be-true? (string=? "abc" "abc" "abc"))
    (should-be-true? (string-ci=? "AbC" "abc")))

  (it "string<?/string>?/etc. compare strings lexicographically"
    (should-be-true? (string<? "a" "b")))

  (it "substring returns a newly allocated string copy of the given range"
    (should-equal? (substring "hello world" 0 5) "hello"))

  (it "string-append returns a newly allocated concatenation of its string arguments"
    (should-equal? (string-append "foo" "bar") "foobar"))

  (it "string->list/list->string convert between a string and a list of its characters, preserving order"
    (should-equal? (string->list "abc") (list #\a #\b #\c))
    (should-equal? (list->string (list #\a #\b #\c)) "abc"))

  (it "string-copy returns a newly allocated copy of the given range, defaulting to the whole string"
    (should-equal? (string-copy "abcde" 1 4) "bcd"))

  (it "string-copy! copies a range of characters from one string into another at a given offset"
    (let ((a (string-copy "abcde")))
      (string-copy! a 1 "xyz" 0 2)
      (should-equal? a "axyde")))

  (it "string-fill! stores fill in the elements of a string between start and end"
    (let ((s (make-string 3)))
      (string-fill! s #\a)
      (should-equal? s "aaa")))

  (it "string-map applies a procedure element-wise across one or more strings, returning a new string"
    (should-equal? (string-map char-upcase "abc") "ABC"))

  (it "string-for-each calls a procedure for its side effects over each character in order"
    (let ((v '()))
      (string-for-each (lambda (c) (set! v (cons (char->integer c) v))) "abcde")
      (should-equal? v (list 101 100 99 98 97))))

  (it "string->vector/vector->string convert between a string and a vector of its characters"
    (should-equal? (string->vector "ABC") (vector #\A #\B #\C))
    (should-equal? (vector->string (vector #\1 #\2 #\3)) "123"))

  (describe "R7RS §6.7 Strings (via (scheme char))"
    (it "string-upcase/string-downcase/string-foldcase apply Unicode case mappings"
      (should-equal? (string-upcase "hi") "HI")
      (should-equal? (string-downcase "HI") "hi")
      (should-equal? (string-foldcase "HeLLo") "hello"))))

(spec-summary!)
