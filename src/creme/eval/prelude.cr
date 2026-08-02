# ===========================================================================
# Prelude
# ===========================================================================

module Creme
  class Interpreter
    PRELUDE = <<-PRELUDE_SRC
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
