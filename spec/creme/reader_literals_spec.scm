;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/modules/creme/compiler/
;; reader_spec.cr's own flat literal battery -- individual atom/list/
;; structure literals read by the self-hosted reader (read-program) and
;; compared against the native reader (read), covering block/datum
;; comments, [...] bracket parens, |foo bar| pipe-quoted symbols, and
;; numeric-literal edge cases (hex/octal/binary/exact/inexact, rationals,
;; complex numbers, +inf.0/-inf.0/+nan.0) -- see modules/creme/spec.sld's
;; own header comment for the framework this uses.
;;
;; Unlike every other spec/creme/*.scm file, sources here are plain
;; STRINGS, not quoted lists of forms -- read-program/native `read` both
;; need real source TEXT to parse; a quoted list would skip the reader
;; entirely, defeating the point of this file.
;;
;; Skipped from the original file: "reads a full mixed program" (already
;; mirrored by compiler_self_host_spec.scm's own reader self-compile
;; test) and "matches the native reader on every example/module source
;; file in the repo" (duplicates the Crystal-level sweep that already
;; runs via `crystal spec`, needs directory-listing support neither
;; (creme spec) nor spec-helper currently provide, and lower marginal
;; value over the flat battery below).
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/reader_literals_spec.scm
;;   ./bin/creme --self-hosted spec/creme/reader_literals_spec.scm
;;   ./icecreme/icecreme spec/creme/reader_literals_spec.scm
;; The 7 complex-number cases in "numbers" (1+2i, 1-2i, -4i, +i, -i, 3+i,
;; 1.5+2.5i) used to fail under `icecreme/icecreme` specifically (icecreme had no
;; complex-number support at all) -- fixed by icecreme/value.h's T_COMPLEX (see
;; compiler_numeric_tower_spec.scm's own header comment for the matching
;; fix on the rational side and at the compiler level).
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(define (should-read-like-native? src)
  (should-equal? (map write-to-string (read-program src)) (map write-to-string (read-all-native src))))

;; check_number in the original file -- confirms the bootstrap reader's
;; first datum is actually a NUMBER, not just a same-spelled symbol that
;; happens to `write` identically (e.g. a wrongly-unclassified "1/2"
;; token falling back to string->symbol would still print as "1/2").
(define (should-read-as-a-number? src)
  (should-read-like-native? src)
  (should-be-true? (number? (car (read-program src)))))

(describe "self-hosted reader matches the native reader on individual literals"
  (describe "lists, vectors, bytevectors"
    (it "()" (should-read-like-native? "()"))
    (it "(1 2 3)" (should-read-like-native? "(1 2 3)"))
    (it "(1 . 2)" (should-read-like-native? "(1 . 2)"))
    (it "(1 2 . 3)" (should-read-like-native? "(1 2 . 3)"))
    (it "(a (b c) . d)" (should-read-like-native? "(a (b c) . d)"))
    (it "#(1 2 3)" (should-read-like-native? "#(1 2 3)"))
    (it "#()" (should-read-like-native? "#()"))
    (it "#u8(1 2 3 255)" (should-read-like-native? "#u8(1 2 3 255)"))
    (it "#u8()" (should-read-like-native? "#u8()")))

  (describe "strings"
    (it "escapes: \\n" (should-read-like-native? "\"hello\\nworld\""))
    (it "escapes: \\t and \\\"" (should-read-like-native? "\"tab\\tquote\\\"end\""))
    (it "empty string" (should-read-like-native? "\"\""))
    (it "\\x41; hex escape" (should-read-like-native? "\"a\\x41;b\"")))

  (describe "characters"
    (it "#\\a" (should-read-like-native? "#\\a"))
    (it "#\\space" (should-read-like-native? "#\\space"))
    (it "#\\newline" (should-read-like-native? "#\\newline"))
    (it "#\\tab" (should-read-like-native? "#\\tab"))
    (it "#\\x41" (should-read-like-native? "#\\x41"))
    (it "#\\(" (should-read-like-native? "#\\("))
    (it "#\\0" (should-read-like-native? "#\\0")))

  (describe "booleans"
    (it "#t" (should-read-like-native? "#t"))
    (it "#f" (should-read-like-native? "#f"))
    (it "#true" (should-read-like-native? "#true"))
    (it "#false" (should-read-like-native? "#false")))

  (describe "quote/quasiquote shorthand"
    (it "'foo" (should-read-like-native? "'foo"))
    (it "`(a ,b ,@c)" (should-read-like-native? "`(a ,b ,@c)"))
    (it "(quote (a b))" (should-read-like-native? "(quote (a b))"))
    (it "''x" (should-read-like-native? "''x")))

  (describe "numbers"
    (it "42" (should-read-like-native? "42"))
    (it "-17" (should-read-like-native? "-17"))
    (it "3.14" (should-read-like-native? "3.14"))
    (it "#x1A" (should-read-like-native? "#x1A"))
    (it "#b101" (should-read-like-native? "#b101"))
    (it "#o17" (should-read-like-native? "#o17"))
    (it "#e1.5" (should-read-like-native? "#e1.5"))
    (it "#d42" (should-read-like-native? "#d42"))
    (it "+inf.0" (should-read-like-native? "+inf.0"))
    (it "-inf.0" (should-read-like-native? "-inf.0"))
    (it "+nan.0" (should-read-like-native? "+nan.0"))
    (it "1/2 is really a number, not a symbol" (should-read-as-a-number? "1/2"))
    (it "-3/4 is really a number, not a symbol" (should-read-as-a-number? "-3/4"))
    (it "1+2i is really a number, not a symbol" (should-read-as-a-number? "1+2i"))
    (it "1-2i is really a number, not a symbol" (should-read-as-a-number? "1-2i"))
    (it "-4i is really a number, not a symbol" (should-read-as-a-number? "-4i"))
    (it "+i is really a number, not a symbol" (should-read-as-a-number? "+i"))
    (it "-i is really a number, not a symbol" (should-read-as-a-number? "-i"))
    (it "3+i is really a number, not a symbol" (should-read-as-a-number? "3+i"))
    (it "1.5+2.5i is really a number, not a symbol" (should-read-as-a-number? "1.5+2.5i")))

  (describe "symbols"
    (it "sym-bol?" (should-read-like-native? "sym-bol?"))
    (it "+" (should-read-like-native? "+"))
    (it "-" (should-read-like-native? "-"))
    (it "..." (should-read-like-native? "..."))
    (it "->foo" (should-read-like-native? "->foo"))
    (it "list->vector" (should-read-like-native? "list->vector"))
    (it "a1b2" (should-read-like-native? "a1b2"))
    (it "|foo bar| pipe-quoted symbol" (should-read-like-native? "|foo bar|"))
    (it "|with \\| pipe| pipe-quoted symbol with an escaped pipe" (should-read-like-native? "|with \\| pipe|")))

  (describe "comments"
    (it "line comment" (should-read-like-native? "; comment\n42"))
    (it "block comment" (should-read-like-native? "#| block |# 42"))
    (it "nested block comment" (should-read-like-native? "#| nested #| deep |# still |# 42"))
    (it "datum comment" (should-read-like-native? "#;(ignored) 42")))

  (describe "bracket parens"
    (it "[1 2 3]" (should-read-like-native? "[1 2 3]"))
    (it "(a . [b])" (should-read-like-native? "(a . [b])"))))

(spec-summary!)
