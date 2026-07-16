# ===========================================================================
# Prelude
# ===========================================================================

module Scheme
  class Interpreter
    PRELUDE = <<-PRELUDE_SRC
      (define (caar x) (car (car x)))
      (define (cadr x) (car (cdr x)))
      (define (cdar x) (cdr (car x)))
      (define (cddr x) (cdr (cdr x)))
      (define (caddr x) (car (cddr x)))
      (define (cdddr x) (cdr (cddr x)))
      (define (cadddr x) (car (cdddr x)))
      (define (first x) (car x))
      (define (second x) (cadr x))
      (define (third x) (caddr x))
      (define (rest x) (cdr x))
      (define (zero? n) (= n 0))
      (define (positive? n) (> n 0))
      (define (negative? n) (< n 0))
      (define (even? n) (= (modulo (exact-integer-part n) 2) 0))
      (define (odd? n) (not (even? n)))
      (define (exact-integer-part n) (if (exact-integer? n) n (exact n)))
      (define (add1 n) (+ n 1))
      (define (sub1 n) (- n 1))
      (define (1+ n) (+ n 1))
      (define (identity x) x)
      (define (range-helper a b acc)
        (if (>= a b) (reverse acc) (range-helper (+ a 1) b (cons a acc))))
      (define (range a b) (range-helper a b '()))
      (define (last lst)
        (if (null? (cdr lst)) (car lst) (last (cdr lst))))
      PRELUDE_SRC

    private def load_prelude : Nil
      BytecodeCompiler.run_program(self, Reader.read_all(PRELUDE, "<prelude>"), @base_env)
    end
  end
end
