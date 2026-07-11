# ===========================================================================
# Prelude
# ===========================================================================

module LISP
  class Interpreter
    PRELUDE = <<-PRELUDE_SRC
      (define (caar x) (car (car x)))
      (define (cadr x) (car (cdr x)))
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
      (define (even? n) (= (modulo n 2) 0))
      (define (odd? n) (not (even? n)))
      (define (add1 n) (+ n 1))
      (define (sub1 n) (- n 1))
      (define (1+ n) (+ n 1))
      (define (identity x) x)
      (define (range-helper a b acc)
        (if (>= a b) (reverse acc) (range-helper (+ a 1) b (cons a acc))))
      (define (range a b) (range-helper a b '()))
      (define (last lst)
        (if (null? (cdr lst)) (car lst) (last (cdr lst))))
      (define (assoc key lst)
        (cond ((null? lst) #f)
              ((equal? (caar lst) key) (car lst))
              (else (assoc key (cdr lst)))))
      (define (member x lst)
        (cond ((null? lst) #f)
              ((equal? (car lst) x) lst)
              (else (member x (cdr lst)))))
      PRELUDE_SRC

    private def load_prelude : Nil
      Reader.read_all(PRELUDE, "<prelude>").each do |form|
        eval(form, @global)
      end
    end
  end
end
