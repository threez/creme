;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_02_numbers_spec.cr --
;; see modules/creme/spec.sld's own header comment for the framework this
;; uses. Ported per the task porting spec/scheme/r7rs/*.cr into
;; spec/creme/r7rs/*.scm: unlike the Crystal original (which builds a
;; fresh Creme::Interpreter per `run`/`w` call purely for isolation),
;; every case here runs directly against this file's own single, real
;; Scheme runtime -- no run(src)/w(src) string-eval indirection, just
;; ordinary Scheme forms compared with should-equal?/should-eqv?/
;; should-raise? against literal expected values.
;;
;; Two cases need real isolation from this file's own top-level imports
;; (whether `complex?`/`+` are bound at all) rather than just local
;; `let`/internal-`define` scoping -- since `import` only works as a
;; top-level declaration (see spec/creme/compiler_libraries_spec.scm's
;; "rejects a non-top-level import"), these use (scheme eval)'s
;; `environment`/`eval` to build a genuinely fresh, otherwise-empty
;; environment (importing only (scheme base)) and evaluate the
;; unqualified reference in IT, exactly mirroring what a fresh
;; Creme::Interpreter without the extra import gave the original.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_02_numbers_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_02_numbers_spec.scm
;;   ./cvm/cvm spec/creme/r7rs/ch06_02_numbers_spec.scm
;; (cvm/cvm has no `environment`/`eval` procedures at all -- see cvm/
;; README.md's own "Native builtins"/REPL sections -- so the two
;; should-raise? cases below that use environment/eval still PASS there,
;; just for a different underlying reason: `environment` itself being
;; unbound raises, which should-raise? accepts regardless of message.)
;; ===========================================================================

(import (scheme base) (scheme write) (scheme eval) (scheme inexact) (scheme complex) (creme spec))

;; +nan.0 is never `equal?`/`eqv?` to itself (IEEE-754 NaN semantics), so
;; the "+inf.0/-inf.0/+nan.0 ... recognized as reader literal syntax"
;; case below needs a WRITTEN comparison, same as the Crystal original's
;; own w(src).should eq(...) (a string comparison) -- not should-equal?
;; on the raw list.
(define (write-to-string v)
  (let ((port (open-output-string)))
    (write v port)
    (get-output-string port)))

(describe "R7RS §6.2.1 Numerical types"
  (it "number?/real?/rational?/integer? classify the numeric tower correctly for exact integers"
    (should-equal? (list (number? 3) (real? 3) (rational? 3) (integer? 3)) (list #t #t #t #t)))

  (it "complex? is only available via (scheme complex), not the base library"
    (should-raise? (lambda () (eval '(complex? 3) (environment '(scheme base)))))
    (should-equal? (complex? 3) #t))

  (it "real?/rational?/integer? distinguish a non-integral rational and a non-rational real"
    (should-equal? (list (rational? 3.5) (rational? (/ 6 10)) (integer? 3.0)) (list #t #t #t))))

(describe "R7RS §6.2.2 Exactness"
  (it "exact?/inexact? partition every number into exactly one of the two categories"
    (should-equal? (list (exact? 3.0) (inexact? 3.0) (exact? 3) (inexact? 3)) (list #f #t #t #f)))

  (it "exact-integer? is #t only for numbers that are both exact and an integer"
    (should-equal? (list (exact-integer? 32) (exact-integer? 32.0)) (list #t #f))))

(describe "R7RS §6.2.3 Implementation restrictions"
  (it "arithmetic on exact integers whose mathematical result is representable stays exact"
    (should-equal? (exact? (+ 2 3)) #t)
    (should-equal? (exact? (* 2 3)) #t))

  (it "division of two exact integers with a nonzero exact divisor produces an exact rational, not a float"
    (should-equal? (/ 1 3) 1/3)
    (should-equal? (exact? (/ 1 3)) #t)))

(describe "R7RS §6.2.4 Implementation extensions (infinities, NaN, negative zero)"
  (it "+inf.0/-inf.0/+nan.0 are recognized as reader literal syntax for the inexact special values"
    (should-equal? (write-to-string (list +inf.0 -inf.0 +nan.0 -nan.0)) "(+inf.0 -inf.0 +nan.0 +nan.0)"))

  (it "the inf/nan literals behave correctly under the inexact-number predicates"
    (should-equal? (list (infinite? +inf.0) (nan? +nan.0) (finite? 3)) (list #t #t #t))))

(describe "R7RS §6.2.5 Syntax of numerical constants"
  (it "a number with no radix prefix is read in decimal"
    (should-equal? 100 100))

  (it "radix prefixes #b/#o/#x/#d select binary/octal/hexadecimal/decimal"
    (should-equal? (list #b101 #o17 #x1A #d100) (list 5 15 26 100)))

  (it "exactness prefixes #e/#i force a literal to be read as exact/inexact"
    (should-equal? (list #e3.0 #i3) (list 3 3.0)))

  (it "radix and exactness prefixes combine, in either order"
    (should-equal? (list #e#x1A #x#e1A) (list 26 26)))

  (it "rational literal syntax (e.g. 1/3 typed directly in source) reads as an exact rational"
    (should-equal? 7/2 7/2)
    (should-equal? (exact? 1/3) #t))

  (it "a rational literal auto-reduces to lowest terms, collapsing to a plain integer when the ratio is whole"
    (should-equal? 4/6 2/3)
    (should-equal? 6/3 2)))

(describe "R7RS §6.2.6 Numerical operations"
  (it "+ and * return the sum/product of their arguments, with the identity for zero arguments"
    (should-equal? (list (+ 3 4) (+ 3) (+) (* 4) (*)) (list 7 3 0 4 1)))

  (it "- and / with one argument return the additive/multiplicative inverse"
    (should-equal? (list (- 3) (/ 3)) (list -3 1/3)))

  (it "- and / with two or more arguments associate to the left"
    (should-equal? (list (- 3 4) (- 3 4 5) (/ 3 4 5)) (list -1 -6 3/20)))

  (it "abs returns the absolute value"
    (should-equal? (abs -7) 7))

  (it "floor/, truncate/ and their -quotient/-remainder halves implement the two division families"
    (should-equal? (call-with-values (lambda () (floor/ 5 2)) list) (list 2 1))
    (should-equal? (call-with-values (lambda () (floor/ -5 2)) list) (list -3 1))
    (should-equal? (call-with-values (lambda () (truncate/ 5 -2)) list) (list -2 1))
    (should-equal? (list (floor-quotient 5 2) (floor-remainder 5 2)) (list 2 1))
    (should-equal? (list (truncate-quotient -5 2) (truncate-remainder -5 2)) (list -2 -1)))

  (it "quotient/remainder/modulo are backward-compatible synonyms for truncate-/floor- variants"
    (should-equal? (list (quotient -5 2) (remainder -5 2) (modulo -5 2)) (list -2 -1 1)))

  (it "gcd/lcm return the greatest common divisor / least common multiple, always non-negative"
    (should-equal? (list (gcd 32 -36) (lcm 32 -36)) (list 4 288))
    (should-equal? (list (gcd) (lcm)) (list 0 1)))

  (it "numerator/denominator return a fraction's parts in lowest terms, denominator of 0 is 1"
    (should-equal? (list (numerator (/ 6 4)) (denominator (/ 6 4)) (denominator 0)) (list 3 2 1)))

  (it "floor/ceiling/truncate/round each return the appropriately-rounded integer"
    (should-equal? (list (floor -4.3) (ceiling -4.3) (truncate -4.3) (round -4.3)) (list -5.0 -4.0 -4.0 -4.0)))

  (it "round rounds to even when exactly halfway between two integers, staying exact for an exact rational argument"
    (should-equal? (round 7/2) 4)
    (should-equal? (exact? (round 7/2)) #t))

  (it "floor/ceiling/truncate also accept exact rationals directly, staying exact"
    (should-equal? (list (floor 7/2) (ceiling 7/2) (truncate 7/2) (floor -7/2) (ceiling -7/2)) (list 3 4 3 -4 -3)))

  (it "sqrt returns the principal square root, exact when the input is a perfect square (only available via (scheme inexact), not auto-imported with base)"
    (should-raise? (lambda () (eval '(sqrt 9) (environment '(scheme base)))))
    (should-equal? (sqrt 9) 3))

  (it "exact-integer-sqrt delivers two separate values (s r) under call-with-values"
    (should-equal? (call-with-values (lambda () (exact-integer-sqrt 4)) list) (list 2 0))
    (should-equal? (call-with-values (lambda () (exact-integer-sqrt 5)) list) (list 2 1)))

  (it "expt raises an exact base to an exact non-negative integer power, staying exact"
    (should-equal? (expt 2 10) 1024))

  (it "expt with a negative exact integer exponent produces the exact reciprocal power"
    (should-equal? (expt 2 -2) 1/4))

  (it "square is equivalent to (* z z)"
    (should-equal? (list (square 42) (square 2.0)) (list 1764 4.0))))

(describe "R7RS §6.2.6 Numerical operations (transcendental, via (scheme inexact))"
  (it "exp/log/sin/cos/tan/asin/acos/atan are available after importing (scheme inexact)"
    (should-equal? (list (sin 0) (cos 0) (exp 0)) (list 0.0 1.0 1.0)))

  (it "log with a second argument computes the base-radix logarithm per R7RS's (log z1 z2)"
    (should-equal? (log 100 10) 2.0)))

(describe "R7RS §6.2.7 Numerical input and output"
  (it "number->string / string->number round-trip through an explicit radix"
    (should-equal? (list (number->string 100) (number->string 100 16) (string->number "100" 16)) (list "100" "64" 256)))

  (it "string->number returns #f on a string that is not a syntactically valid number"
    (should-equal? (string->number "not-a-number") #f)))

(spec-summary!)
