;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_05_symbols_spec.cr's
;; own cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses. The original Crystal spec evaluated each case's
;; Scheme source via a fresh sub-interpreter (run(src)/w(src)) since it was
;; testing a Scheme interpreter from OUTSIDE, as Crystal code; here, running
;; directly as Scheme, each case's forms are written and asserted directly
;; via should-equal?/should-be-true? instead of comparing write_string'd
;; output against a literal string.
;;
;; The last case here (write's own |...| vertical-bar escaping for a
;; symbol name containing a space) used to expose a genuine,
;; undocumented cvm gap -- cvm/builtins.c's write_value had no T_SYM
;; case of its own, so `write` of a symbol under cvm never bar-escaped a
;; name needing it. Fixed (write_value's new T_SYM case, backed by
;; write_symbol_literal/symbol_needs_pipe_escape), so this case runs
;; unconditionally now.
;;
;; Run with (all cases pass, 0 pending, under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_05_symbols_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_05_symbols_spec.scm
;;   ./cvm/cvm spec/creme/r7rs/ch06_05_symbols_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme read) (creme spec))

(describe "R7RS §6.5 Symbols"
  (it "symbol? is #t for symbols"
    (should-be-true? (symbol? 'foo))
    (should-be-true? (symbol? (car '(a b))))
    (should-be-false? (symbol? "bar"))
    (should-be-false? (symbol? '()))
    (should-be-false? (symbol? #f)))

  (it "symbol=? is #t if all arguments are symbols with the same name"
    (should-be-true? (symbol=? 'a 'a 'a))
    (should-be-false? (symbol=? 'a 'b)))

  (it "symbol->string returns the symbol's name as a string"
    (should-equal? (symbol->string 'flying-fish) "flying-fish")
    (should-equal? (symbol->string 'Martin) "Martin"))

  (it "string->symbol returns the symbol whose name is the given string, without interpreting escapes"
    (should-equal? (string->symbol "mISSISSIppi") (string->symbol "mISSISSIppi"))
    (should-be-true? (eqv? 'bitBlt (string->symbol "bitBlt"))))

  (it "symbol->string and string->symbol are inverses for round-tripping a symbol through a string"
    (should-be-true? (eqv? 'LollyPop (string->symbol (symbol->string 'LollyPop)))))

  (it "string->symbol can create symbols whose names contain characters needing escapes when written"
    (should-be-true? (string=? "K. Harper, M.D." (symbol->string (string->symbol "K. Harper, M.D.")))))

  (it "a symbol read/written via write round-trips back to the identical symbol, using |...| vertical-bar escaping for names containing special characters"
    (let ((op (open-output-string)))
      (write (string->symbol "two words") op)
      (should-equal? (get-output-string op) "|two words|"))
    (let* ((s (string->symbol "two words"))
           (p (open-output-string)))
      (write s p)
      (should-be-true? (eqv? s (read (open-input-string (get-output-string p))))))))

(spec-summary!)
