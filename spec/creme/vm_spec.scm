;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/compile/bytecode_vm_spec.cr's
;; own cases -- language/VM-semantics tests of the register VM/bytecode
;; compiler (closures/upvalues, tail calls, cond/case, multiple values,
;; parameterize, guard, dynamic-wind/call/cc, quasiquote, delay/force,
;; define-record-type, do) -- ported here as should-match-native?
;; comparisons (self-hosted compiler vs native evaluation), the same
;; pattern compiler_spec.scm uses, rather than against the ORIGINAL
;; file's own hardcoded expected-value strings (which only ever exercised
;; the native VM directly, with no self-hosted compiler involved).
;;
;; Skipped from the original file (see spec/creme/README-worthy note --
;; actually just this comment): the three "memoizes a zero-upvalue
;; lambda/case-lambda clause" cases, which assert `eq?`-identity of
;; distinct closure evaluations -- an unspecified-by-R7RS Crystal-VM-
;; internal performance optimization (VM#make_closure's memoization),
;; not a language guarantee the self-hosted compiler needs to reproduce.
;; Also skipped: the plain define-record-type/plain swap! cases, both
;; near-duplicates of cases already in compiler_spec.scm's own "records"/
;; "define-syntax" sections.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/vm_spec.scm
;;   ./bin/creme --self-hosted spec/creme/vm_spec.scm
;;   ./cvm/cvm spec/creme/vm_spec.scm
;; cvm previously had no call/cc/dynamic-wind/with-exception-handler at
;; all; all three are now real cvm builtins (cvm/builtins.c/vm.c/vm.h --
;; call/cc is an escape-only, one-shot continuation via setjmp/longjmp,
;; reusing the same unwind-stack mechanism parameterize already used;
;; dynamic-wind generalizes that same mechanism; with-exception-handler/
;; raise-continuable are pure Scheme atop dynamic-wind, defined in
;; cvm/compiler-run.scm -- see each one's own comment for the full story).
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "BytecodeCompiler + VM language semantics match native evaluation"

  (describe "literals, arithmetic, control flow"
    (it "evaluates arithmetic and comparisons"
      (should-match-native? '((+ 1 2)))
      (should-match-native? '((* 6 7)))
      (should-match-native? '((< 1 2)))
      (should-match-native? '((>= 2 3))))
    (it "evaluates if/begin/and/or/when/unless"
      (should-match-native? '((if (< 1 2) 'yes 'no)))
      (should-match-native? '((begin 1 2 3)))
      (should-match-native? '((and 1 2 3)))
      (should-match-native? '((and 1 #f 3)))
      (should-match-native? '((or #f #f 5)))
      (should-match-native? '((when (> 2 1) 'a 'b)))
      (should-match-native? '((unless (> 2 1) 'a 'b))))
    (it "evaluates let/let*/letrec"
      (should-match-native? '((let ((a 1) (b 2)) (+ a b))))
      (should-match-native? '((let* ((a 1) (b (+ a 1))) (+ a b))))
      (should-match-native?
        '((letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
                   (odd? (lambda (n) (if (= n 0) #f (even? (- n 1))))))
            (even? 10))))))

  (describe "functions, recursion, tail calls"
    (it "computes non-tail recursion (fact)"
      (should-match-native?
        '((define (fact n) (if (< n 2) 1 (* n (fact (- n 1))))) (fact 10))))
    (it "computes non-tail recursion (fib)"
      (should-match-native?
        '((define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 15))))
    (it "handles a large self-tail-recursive named-let loop without stack growth"
      (should-match-native?
        '((let loop ((i 0) (acc 0)) (if (= i 1000000) acc (loop (+ i 1) (+ acc i)))))))
    (it "handles rest args"
      (should-match-native? '((define (f . xs) xs) (f 1 2 3)))
      (should-match-native? '((define (f a . rest) (list a rest)) (f 1 2 3)))))

  (describe "closures and upvalues"
    (it "mutates a shared upvalue across calls"
      (should-match-native?
        '((define (make-counter) (let ((n 0)) (lambda () (set! n (+ n 1)) n)))
          (define c (make-counter)) (c) (c) (c))))
    (it "captures each loop iteration's own value independently (not aliased)"
      (should-match-native?
        '((define (make-adders n)
            (let loop ((i 0) (acc '()))
              (if (= i n) acc (loop (+ i 1) (cons (lambda (x) (+ x i)) acc)))))
          (define adders (make-adders 3))
          (map (lambda (f) (f 100)) adders))))
    (it "still captures the current value correctly for a lambda literal with real (non-zero) upvalues"
      (should-match-native?
        '((define (make-adders n)
            (let loop ((i 0) (acc '()))
              (if (= i n) acc (loop (+ i 1) (cons (lambda () i) acc)))))
          (map (lambda (f) (f)) (make-adders 3))))))

  (describe "vectors, strings, bytevectors (fused prim ops)"
    (it "vector-ref/vector-set!/vector-length"
      (should-match-native? '((define v (vector 1 2 3)) (vector-set! v 1 99) (vector-ref v 1)))
      (should-match-native? '((vector-length (vector 1 2 3)))))
    (it "string-ref/string-set!"
      (should-match-native? '((let ((s (make-string 3 #\a))) (string-set! s 1 #\z) s))))
    (it "bytevector-u8-ref/bytevector-u8-set!"
      (should-match-native?
        '((let ((b (make-bytevector 2))) (bytevector-u8-set! b 0 42) (bytevector-u8-ref b 0))))))

  (describe "cons/not/null?/pair?/eq? (fused prim ops)"
    (it "computes correctly"
      (should-match-native? '((cons 1 2)))
      (should-match-native? '((not #f)))
      (should-match-native? '((not 5)))
      (should-match-native? '((null? '())))
      (should-match-native? '((null? 5)))
      (should-match-native? '((pair? (cons 1 2))))
      (should-match-native? '((pair? '())))
      (should-match-native? '((eq? 'x 'x)))
      (should-match-native? '((eq? 'x 'y)))))

  ;; A bare local prim operand can alias its own register (skipping a Move)
  ;; only when nothing evaluated after it mutates that local -- these pin
  ;; the evaluation order the elision must preserve, in both the safe
  ;; (alias) and unsafe (must-snapshot) directions.
  (describe "prim operand Move-elision preserves left-to-right evaluation"
    (it "aliases a bare local when its suffix is side-effect-free"
      (should-match-native? '((let ((x '(9 9)) (col 3)) (= (car x) col))))
      (should-match-native? '((let ((x '(3 9)) (col 3)) (= (car x) col))))
      (should-match-native? '((let ((n 10) (c 2)) (- n (* c 2))))))
    (it "snapshots a bare local when a later sibling can mutate it"
      (should-match-native? '((let ((b 7)) (- b (* (begin (set! b 100) 2) 1)))))
      (should-match-native?
        '((let ((d 5)) (define (bump!) (set! d 99) 1) (- d (* (bump!) 2)))))))

  (describe "tail-call argument register reuse"
    (it "passes an accumulator through unchanged across many iterations"
      (should-match-native?
        '((let loop ((i 0) (acc 'ok)) (if (= i 1000) acc (loop (+ i 1) acc))))))
    (it "handles a register swap between two accumulators"
      (should-match-native?
        '((let loop ((n 5) (a 1) (b 2)) (if (= n 0) (list a b) (loop (- n 1) b a))))))
    (it "preserves left-to-right evaluation order for tail-call arguments"
      (should-match-native?
        '((define log '())
          (define (tag! x) (set! log (cons x log)) x)
          (let loop ((i 0) (a 0) (b 0))
            (if (= i 2) (reverse log) (loop (+ i 1) (tag! 'first) (tag! 'second)))))))
    (it "falls back safely when an argument creates a closure over the loop's own state"
      (should-match-native?
        '((define (make-adders n)
            (let loop ((i 0) (acc '()))
              (if (= i n) acc (loop (+ i 1) (cons (lambda (x) (+ x i)) acc)))))
          (map (lambda (f) (f 100)) (make-adders 3)))))
    (it "relocates a callee whose own register coincides with an argument target"
      (should-match-native? '(((lambda (f) (f 100)) (lambda (x) (+ x 1))))))
    (it "does not corrupt an earlier closure's still-open upvalue into a target register"
      (should-match-native? '((let ((b 41)) (let ((f (lambda (x) (+ b x)))) (f 1)))))))

  (describe "cond"
    (it "picks the first matching clause, supports else/=>/empty-body"
      (should-match-native? '((cond ((= 1 2) 'a) ((= 1 1) 'b) (else 'c))))
      (should-match-native? '((cond (#f 'a) (else 'c))))
      (should-match-native? '((cond ((assv 1 '((1 . one) (2 . two))) => cdr) (else 'none))))
      (should-match-native? '((cond (#f 'a))))
      (should-match-native? '((cond (42))))))

  (describe "case"
    (it "matches via eqv?, supports else/=>/empty-body"
      (should-match-native? '((case (* 2 3) ((2 3 5 7) 'prime) ((1 4 6 8 9) 'composite) (else 'unknown))))
      (should-match-native?
        '((case (car '(c d)) ((a e i o u) 'vowel) ((w y) 'semivowel) (else => (lambda (x) (list 'other x))))))
      (should-match-native? '((case 99 ((1 2) 'a))))
      (should-match-native? '((case 1 ((1))))))
    ;; 8+ total datums, all hashable (ints here) -- exercises the native
    ;; compiler's Op::CaseDispatch hash-dispatch path instead of the
    ;; linear CaseMatch/TestFalse chain; the self-hosted compiler always
    ;; desugars case into the linear cond/memv form (documented, out of
    ;; scope opcode-parity gap) but the RESULT must still match.
    (it "hash-dispatches large all-literal case forms (Op::CaseDispatch on the native side)"
      (should-match-native?
        '((define n 0)
          (case n ((0 1) 'zero-or-one) ((2 3) 'two-or-three) ((4 5) 'four-or-five) ((6 7) 'six-or-seven) (else 'other))))
      (should-match-native?
        '((define n 7)
          (case n ((0 1) 'zero-or-one) ((2 3) 'two-or-three) ((4 5) 'four-or-five) ((6 7) 'six-or-seven) (else 'other))))
      (should-match-native?
        '((define n 42)
          (case n ((0 1) 'zero-or-one) ((2 3) 'two-or-three) ((4 5) 'four-or-five) ((6 7) 'six-or-seven) (else 'other))))
      (should-match-native?
        '((define n 42) (case n ((0 1) 'a) ((2 3) 'b) ((4 5) 'c) ((6 7) 'd)))))
    (it "hash-dispatch: first clause wins on a duplicate datum across clauses"
      (should-match-native? '((case 1 ((1 2) 'first) ((1 3) 'second) ((4 5) 'x) ((6 7) 'y) (else 'z)))))
    (it "hash-dispatch: distinguishes datum types that could otherwise collide"
      (should-match-native?
        '((case #\a ((0 1) 'int-zero-or-one) ((#\a #\b) 'char-a-or-b) ((foo bar) 'sym) ((#t #f) 'bool) (else 'none))))
      (should-match-native?
        '((case #f ((0 1) 'int-zero-or-one) ((#\a #\b) 'char-a-or-b) ((foo bar) 'sym) ((#t #f) 'bool) (else 'none)))))
    (it "falls back to the linear path when else isn't last"
      (should-match-native? '((case 9 ((0 1) 'a) (else 'else-first) ((2 3) 'b) ((4 5) 'c) ((6 7) 'd)))))
    (it "falls back to the linear path for non-hashable datum types"
      (should-match-native? '((case 1.5 ((0 1) 'a) ((2 3) 'b) ((1.5 2.5) 'floats) ((4 5) 'c) (else 'z)))))
    (it "raises on a malformed (empty) clause"
      (should-raise?
        (lambda ()
          (bootstrap-eval-forms '((case 99 ((0 1) 'a) ((2 3) 'b) ((4 5) 'c) ((6 7) 'd) ()))))))
    )

  (describe "case-lambda"
    (it "dispatches by argument count, including a rest clause"
      (should-match-native?
        '((define f (case-lambda
                      (() 'zero)
                      ((a) (list 'one a))
                      ((a b) (list 'two a b))
                      ((a . rest) (list 'many a rest))))
          (list (f) (f 1) (f 1 2) (f 1 2 3 4))))))

  (describe "multiple values"
    (it "define-values, including a rest binding"
      (should-match-native? '((define-values (q r) (values 3 4)) (list q r)))
      (should-match-native? '((define-values (a . rest) (values 1 2 3)) (list a rest))))
    (it "let-values (non-sequential) and let*-values (sequential)"
      (should-match-native? '((let-values (((a b) (values 1 2)) ((c) (values 3))) (list a b c))))
      (should-match-native? '((let*-values (((a b) (values 1 2)) ((c) (values (+ a b)))) (list a b c)))))
    (it "call-with-values bridges through apply correctly"
      (should-match-native? '((call-with-values (lambda () (values 1 2)) (lambda (a b) (+ a b)))))))

  (describe "parameterize"
    (it "restores the saved value after the body, including nested and converter cases"
      (should-match-native?
        '((define p (make-parameter 10)) (list (p) (parameterize ((p 20)) (p)) (p))))
      (should-match-native?
        '((define p (make-parameter 5 (lambda (v) (* v 2))))
          (list (p) (parameterize ((p 3)) (p)) (p))))
      (should-match-native?
        '((define p (make-parameter 1))
          (define (f) (p))
          (parameterize ((p 99)) (list (f) (parameterize ((p 100)) (f)) (f)))))))

  (describe "guard"
    (it "catches an error and runs the matching clause"
      (should-match-native?
        '((guard (e (#t (list 'caught (error-object? e) (error-object-message e)))) (error "boom" 1 2))))
      (should-match-native?
        '((guard (e ((symbol? e) (list 'sym e)) (#t (list 'other e))) (raise 'oops)))))
    (it "catches an error raised from a non-tail call deep inside the body"
      (should-match-native?
        '((define (f n) (guard (e (#t (list 'caught n))) (if (= n 0) (error "boom") 'ok)))
          (list (f 1) (f 0)))))
    (it "re-raises to an outer guard when no clause matches"
      (should-match-native?
        '((guard (e1 (#t (list 'outer e1)))
            (guard (e2 ((string? e2) (list 'inner-string e2))) (raise 'not-a-string))))))
    (it "unwinds cleanly through several levels of non-tail recursion"
      (should-match-native?
        '((define log '())
          (define (rec n)
            (guard (e (#t (set! log (cons 'caught log)) 'handled))
              (if (= n 0) (error "deep")
                  (begin (set! log (cons n log)) (rec (- n 1))))))
          (rec 5) (reverse log))))
    (it "can appear as an ordinary operand mid-expression"
      (should-match-native? '((+ 1 (guard (e (#t 100)) (car 5)))))))

  (describe "dynamic-wind, call/cc, with-exception-handler"
    (it "runs before/thunk/after in order"
      (should-match-native?
        '((define log '())
          (dynamic-wind
            (lambda () (set! log (cons 'before log)))
            (lambda () (set! log (cons 'during log)))
            (lambda () (set! log (cons 'after log))))
          (reverse log))))
    (it "still runs after when thunk errors, caught by an outer guard"
      (should-match-native?
        '((define log '())
          (guard (e (#t 'caught))
            (dynamic-wind
              (lambda () (set! log (cons 'before log)))
              (lambda () (error "fail"))
              (lambda () (set! log (cons 'after log)))))
          (reverse log))))
    (it "call/cc escapes immediately, discarding the rest of its own call site"
      (should-match-native? '((+ 1 (call/cc (lambda (k) (+ 2 (k 10))))))))
    (it "call/cc escapes a for-each loop early"
      (should-match-native?
        '((call/cc (lambda (return)
                     (for-each (lambda (x) (if (= x 3) (return x))) '(1 2 3 4 5))
                     'not-found)))))
    (it "escaping a dynamic-wind's thunk via a captured continuation still runs after"
      (should-match-native?
        '((define log '())
          (call/cc (lambda (k)
                     (dynamic-wind
                       (lambda () (set! log (cons 'in log)))
                       (lambda () (k 'escaped))
                       (lambda () (set! log (cons 'out log))))))
          (reverse log))))
    (it "raise-continuable calls the handler in-line and uses its return value"
      (should-match-native?
        '((with-exception-handler
            (lambda (e) 1000)
            (lambda () (+ 1 (raise-continuable 'oops))))))))

  (describe "quasiquote"
    (it "evaluates unquote, unquote-splicing, vectors, and nested quasiquote"
      (should-match-native? '((define x 5) `(a b ,x ,(+ x 1))))
      (should-match-native? '((define lst '(2 3 4)) `(1 ,@lst 5)))
      (should-match-native? '(`#(1 ,(+ 1 1) 3)))
      (should-match-native? '(``(a ,(b ,(+ 1 2)))))))

  (describe "delay / force"
    (it "memoizes -- the thunk runs only once across repeated force calls"
      (should-match-native?
        '((import (scheme lazy))
          (define count 0)
          (define p (delay (begin (set! count (+ count 1)) count)))
          (list (force p) (force p) count)))))

  (describe "define-syntax"
    (it "expands syntax-rules macros, including ones affecting LATER top-level forms"
      (should-match-native?
        '((define-syntax my-if (syntax-rules () ((_ c t e) (cond (c t) (else e)))))
          (my-if #t 'yes 'no)))))

  (describe "do"
    (it "builds a vector via mutation across iterations"
      (should-match-native?
        '((do ((vec (make-vector 5)) (i 0 (+ i 1))) ((= i 5) vec) (vector-set! vec i i)))))
    (it "supports a self-tail-recursive accumulation with no explicit step for some vars"
      (should-match-native? '((do ((x 1 (* x 2)) (i 0 (+ i 1))) ((= i 20) x)))))
    (it "returns unspecified with no result forms"
      (should-match-native? '((do ((i 0 (+ i 1))) ((= i 3))))))))

(spec-summary!)
