;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/compile/prim_call_spec.cr's own
;; "primitive call specialization" cases -- see modules/creme/spec.sld's
;; own header comment for the framework this uses, and compiler_spec.scm's
;; own header comment for the general should-match-native? approach.
;;
;; The native BytecodeCompiler specializes a handful of fixed-arity
;; builtins (arithmetic/comparisons, vector-ref/-set!/-length,
;; string-ref/-set!, bytevector-u8-ref/-set!, eq?) into inlined ops when a
;; call site's head is a free, non-shadowed global still bound to the
;; expected builtin -- deopting cleanly to a runtime redefinition instead
;; of silently keeping the old behavior. Every case here is ported via
;; should-match-native?, even though this is a NATIVE-only optimization:
;; should-match-native? asserts the COMPUTED VALUE is correct, not which
;; internal bytecode path produced it, so it doubles as a genuine cross-
;; compiler (native/self-hosted/cvm) consistency check regardless of
;; whether the self-hosted compiler implements the same Imm/Up/fusion op
;; families internally.
;;
;; REORDERED from the original file's own describe grouping, for the same
;; shared-global-table reason compiler_defmacro_spec.scm's own trailing
;; "primitive-fusion suppression after redefinition" cases must run last
;; (see that file's own long comment on the mechanism) -- generalized
;; here to every case that permanently redefines a widely-used builtin.
;; Crystal's own w()/run() give native_eval a BRAND NEW Creme::Interpreter
;; every call; this file's should-match-native? runs bootstrap-eval and
;; native-eval alike against ONE shared global table for the whole
;; process. Every case that does `(define (+ ...) ...)` (or vector-ref/
;; vector-set!/vector-length/string-ref/string-set!/bytevector-u8-ref/
;; bytevector-u8-set!/</eq?) at the top level PERMANENTLY shadows that
;; name for every later should-match-native? call in this file -- and
;; those names are used constantly, for real, throughout every other
;; describe group below. So every such case (17 of the original 84,
;; spanning most describe groups) is moved into one final "deopt on
;; redefinition" block at the very end, after every case relying on the
;; real/unshadowed meaning of any of these names. should-match-native? is
;; still safe to use there (unlike compiler_defmacro_spec.scm's two
;; cases, which needed a literal should-equal? fallback): every repeated
;; redefinition of the SAME name across different original cases uses
;; the IDENTICAL shadow body (e.g. always `(define (+ a b) (list
;; 'shadowed a b))`), so bootstrap-eval then native-eval both redefining
;; the same way against the shared globals stays a symmetric, correct
;; comparison. A `let`-LOCAL shadow (e.g. "does not specialize a call
;; whose head is shadowed by a local binding") does NOT leak globally and
;; is left in its original position.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/prim_call_spec.scm
;;   ./bin/creme --self-hosted spec/creme/prim_call_spec.scm
;;   ./cvm/cvm spec/creme/prim_call_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself. (scheme cxr) is for caar/cdar,
;; used by one of the eq?-fusion cases below.
(import (scheme base) (scheme cxr) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "primitive call specialization"
  (it "still works normally (no redefinition) for every specialized op"
    (should-match-native? '((vector-ref (vector 1 2 3) 1)))
    (should-match-native? '((let ((v (vector 1 2 3))) (vector-set! v 1 99) v)))
    (should-match-native? '((vector-length (vector 1 2 3))))
    (should-match-native? '((string-ref "abc" 1)))
    (should-match-native? '((let ((s (make-string 3 #\a))) (string-set! s 1 #\z) s)))
    (should-match-native? '((bytevector-u8-ref (bytevector 1 2 3) 1)))
    (should-match-native? '((let ((b (make-bytevector 3 0))) (bytevector-u8-set! b 1 42) b))))

  (it "does not specialize a call whose head is shadowed by a local binding"
    (should-match-native? '((define v (vector 1 2)) (let ((vector-ref (lambda (v i) 'local))) (vector-ref v 0)))))

  (describe "inlined operand fast path"
    (it "computes correctly with local/global/literal operands mixed (arithmetic/comparison)"
      (should-match-native? '((define (f n) (+ (- n 1) (* n 2))) (f 5)))
      (should-match-native? '((< 1 2)))
      (should-match-native? '((<= 2 2)))
      (should-match-native? '((> 3 2)))
      (should-match-native? '((>= 2 2)))
      (should-match-native? '((= 2 2))))

    (it "computes correctly with local/global/literal operands (vector/string/bytevector)"
      (should-match-native? '((define (f v i) (vector-ref v i)) (f (vector 10 20 30) 1)))
      (should-match-native? '((define (f v i x) (vector-set! v i x) v) (f (vector 1 2) 0 9)))
      (should-match-native? '((define (f v) (vector-length v)) (f (vector 1 2 3))))
      (should-match-native? '((define (f s i) (string-ref s i)) (f "abc" 1)))
      (should-match-native? '((define (f s i c) (string-set! s i c) s) (f (make-string 2 #\z) 0 #\a)))
      (should-match-native? '((define (f b i) (bytevector-u8-ref b i)) (f (bytevector 1 2 3) 1)))
      (should-match-native? '((define (f b i x) (bytevector-u8-set! b i x) b) (f (make-bytevector 2) 0 42))))

    (it "still evaluates a non-leaf operand (not eligible for the inline fetch) correctly"
      (should-match-native? '((define (double x) (* x 2)) (+ (double 3) 1)))
      (should-match-native? '((define (idx) 1) (vector-ref (vector 10 20 30) (idx)))))

    (it "reports an unbound-variable error at the operand's own position, not the call's"
      (should-raise? (lambda () (bootstrap-eval-forms '((define x 1) (+ x y)))))))

  (describe "local-operand register reuse (no staging Move)"
    (it "still snapshots an earlier local operand before a later sibling's side effect mutates it"
      (should-match-native? '((let ((n 5)) (+ n (begin (set! n 10) n))))))

    (it "computes correctly when every operand is an eligible local/global/literal leaf"
      (should-match-native? '((let ((n 5)) (- n 1))))
      (should-match-native? '((let ((a 1) (b 2)) (+ a b))))
      (should-match-native? '((let ((n 3)) (< n 2)))))

    (it "still computes correctly when the same local is read twice in one call"
      (should-match-native? '((let ((n 5)) (+ n n))))))

  (describe "small-integer immediate operand (Imm ops)"
    (it "computes correctly for every Imm-eligible op, with a local 1st operand"
      (should-match-native? '((let ((n 5)) (+ n 1))))
      (should-match-native? '((let ((n 5)) (- n 1))))
      (should-match-native? '((let ((n 5)) (* n 2))))
      (should-match-native? '((let ((n 5)) (< n 2))))
      (should-match-native? '((let ((n 5)) (<= n 5))))
      (should-match-native? '((let ((n 5)) (> n 2))))
      (should-match-native? '((let ((n 5)) (>= n 5))))
      (should-match-native? '((let ((n 5)) (= n 5)))))

    (it "computes correctly with a global 1st operand"
      (should-match-native? '((define n 5) (+ n 1)))
      (should-match-native? '((define n 5) (- n 1)))
      (should-match-native? '((define n 5) (* n 2)))
      (should-match-native? '((define n 5) (< n 2)))
      (should-match-native? '((define n 5) (= n 5))))

    (it "falls back to the general path for a literal too large for Int32"
      (should-match-native? '((let ((n 10)) (- n 5000000000))))
      (should-match-native? '((let ((n 10)) (+ n 5000000000)))))

    (it "falls back to the numeric tower for a non-integer 1st operand"
      (should-match-native? '((< 1.5 2)))
      (should-match-native? '((let ((x 1.5)) (< x 2))))
      (should-match-native? '((let ((x (/ 3 2))) (< x 2))))
      (should-match-native? '((let ((x 1.5)) (+ x 1)))))

    (it "still respects ordinary set!-then-read sequencing"
      (should-match-native? '((let ((n 5)) (begin (set! n 7) (- n 1)))))))

  (describe "closed-over 2nd operand (arithmetic/comparison Up ops)"
    (it "computes correctly for every Up-eligible op, with the captured variable as the 2nd operand"
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (+ x n)))) (f 1)))))
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (- x n)))) (f 1)))))
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (* x n)))) (f 2)))))
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (< x n)))) (f 2)))))
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (<= x n)))) (f 5)))))
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (> x n)))) (f 6)))))
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (>= x n)))) (f 5)))))
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (= x n)))) (f 5))))))

    (it "still exercises the loop shape this was profiled from"
      (should-match-native?
        '((define (vector-sum-test n)
            (let ((v (make-vector n 0)))
              (let loop ((i 0))
                (if (< i n)
                    (begin (vector-set! v i (* i 2)) (loop (+ i 1)))))
              (let loop ((i 0) (acc 0))
                (if (= i n) acc (loop (+ i 1) (+ acc (vector-ref v i)))))))
          (vector-sum-test 5))))

    (it "falls back to the numeric tower for a non-integer captured operand"
      (should-match-native? '((let ((n 1.5)) (let ((f (lambda (x) (+ x n)))) (f 1))))))

    (it "does not fuse (and stays correct) when the 1st operand isn't a leaf"
      (should-match-native? '((let ((n 5)) (let ((f (lambda () (< (begin (set! n 100) 0) n)))) (f)))))))

  (describe "closed-over object operand (vector/string/bytevector Up ops)"
    (it "computes correctly for vector-ref/vector-set!/vector-length"
      (should-match-native? '((let ((v (vector 1 2 3))) (let ((f (lambda (i) (vector-ref v i)))) (f 1)))))
      (should-match-native? '((let ((v (vector 1 2 3))) (let ((f (lambda (i x) (vector-set! v i x) v))) (f 1 9)))))
      (should-match-native? '((let ((v (vector 1 2 3))) (let ((f (lambda () (vector-length v)))) (f))))))

    (it "computes correctly for string-ref/string-set!"
      (should-match-native? '((let ((s "abc")) (let ((f (lambda (i) (string-ref s i)))) (f 1)))))
      (should-match-native? '((let ((s (make-string 2 #\z))) (let ((f (lambda (i c) (string-set! s i c) s))) (f 0 #\a))))))

    (it "computes correctly for bytevector-u8-ref/bytevector-u8-set!"
      (should-match-native? '((let ((b (bytevector 1 2 3))) (let ((f (lambda (i) (bytevector-u8-ref b i)))) (f 1)))))
      (should-match-native? '((let ((b (make-bytevector 2 0))) (let ((f (lambda (i x) (bytevector-u8-set! b i x) b))) (f 0 42))))))

    (it "does not fuse (and stays correct) when a later argument mutates the captured object first"
      (should-match-native?
        '((let ((v (vector 10 20 30)))
            (let ((f (lambda (x)
                       (vector-set! v (begin (set! v (vector 99 99 99)) 0) x)
                       v)))
              (f 5)))))))

  (describe "vector/string/bytevector index immediate operand (*RefImm/*SetImm ops)"
    (it "computes correctly for vector-ref/vector-set! with a literal index"
      (should-match-native? '((vector-ref (vector 10 20 30) 1)))
      (should-match-native? '((let ((v (vector 1 2 3))) (vector-set! v 1 99) v))))

    (it "computes correctly with a local vector operand"
      (should-match-native? '((let ((v (vector 10 20 30))) (vector-ref v 2))))
      (should-match-native? '((let ((v (vector 1 2 3))) (vector-set! v 0 9) v))))

    (it "computes correctly with a global vector operand"
      (should-match-native? '((define v (vector 10 20 30)) (vector-ref v 0))))

    (it "still evaluates a non-literal index correctly (general path, not fused)"
      (should-match-native? '((vector-ref (vector 1 2 3) (+ 1 0)))))

    (it "still snapshots the object before a later argument's side effect mutates it (vector-set!)"
      (should-match-native?
        '((let ((v (vector 10 20 30)))
            (vector-set! v 0 (begin (set! v (vector 99 99 99)) 5))
            v))))

    (it "raises on an out-of-range literal index"
      (should-raise? (lambda () (bootstrap-eval-forms '((vector-ref (vector 1 2 3) 5))))))

    (it "computes correctly for string-ref/string-set! with a literal index"
      (should-match-native? '((string-ref "abc" 1)))
      (should-match-native? '((let ((s (make-string 3 #\a))) (string-set! s 1 #\z) s))))

    (it "still snapshots the string before a later argument's side effect mutates it (string-set!)"
      (should-match-native?
        '((let ((s (make-string 3 #\a)))
            (string-set! s 0 (begin (set! s (make-string 3 #\z)) #\q))
            s))))

    (it "raises on an out-of-range literal index (string-ref)"
      (should-raise? (lambda () (bootstrap-eval-forms '((string-ref "abc" 5))))))

    (it "computes correctly for bytevector-u8-ref/bytevector-u8-set! with a literal index"
      (should-match-native? '((bytevector-u8-ref (bytevector 1 2 3) 1)))
      (should-match-native? '((let ((b (make-bytevector 3 0))) (bytevector-u8-set! b 1 42) b))))

    (it "still snapshots the bytevector before a later argument's side effect mutates it (bytevector-u8-set!)"
      (should-match-native?
        '((let ((b (make-bytevector 3 0)))
            (bytevector-u8-set! b 0 (begin (set! b (make-bytevector 3 9)) 1))
            b))))

    (it "raises on an out-of-range literal index (bytevector-u8-ref)"
      (should-raise? (lambda () (bootstrap-eval-forms '((bytevector-u8-ref (bytevector 1 2 3) 5)))))))

  (describe "compare-and-branch fusion (if/when Test* ops)"
    (it "computes correctly for every comparison, plain register operands"
      (should-match-native? '((let ((a 1) (b 2)) (if (< a b) 'yes 'no))))
      (should-match-native? '((let ((a 2) (b 2)) (if (<= a b) 'yes 'no))))
      (should-match-native? '((let ((a 3) (b 2)) (if (> a b) 'yes 'no))))
      (should-match-native? '((let ((a 2) (b 2)) (if (>= a b) 'yes 'no))))
      (should-match-native? '((let ((a 2) (b 2)) (if (= a b) 'yes 'no))))
      (should-match-native? '((let ((a 5) (b 2)) (if (< a b) 'yes 'no)))))

    (it "computes correctly with a small-integer-literal 2nd operand (Imm)"
      (should-match-native? '((let ((n 1)) (if (< n 2) 'yes 'no))))
      (should-match-native? '((let ((n 5)) (if (< n 2) 'yes 'no))))
      (should-match-native? '((let ((n 5)) (if (<= n 5) 'yes 'no))))
      (should-match-native? '((let ((n 5)) (if (> n 5) 'yes 'no))))
      (should-match-native? '((let ((n 5)) (if (>= n 5) 'yes 'no))))
      (should-match-native? '((let ((n 5)) (if (= n 5) 'yes 'no)))))

    (it "computes correctly with a closed-over 2nd operand (Up)"
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (if (< x n) 'yes 'no)))) (f 2)))))
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (if (< x n) 'yes 'no)))) (f 9)))))
      (should-match-native?
        '((define (vector-sum-test n)
            (let ((v (make-vector n 0)))
              (let loop ((i 0))
                (if (< i n)
                    (begin (vector-set! v i (* i 2)) (loop (+ i 1)))))
              (let loop ((i 0) (acc 0))
                (if (= i n) acc (loop (+ i 1) (+ acc (vector-ref v i)))))))
          (vector-sum-test 5))))

    (it "works the same for when/unless (negated test)"
      (should-match-native? '((when (< 1 2) 'yes)))
      (should-match-native? '((unless (< 1 2) 'yes)))
      (should-match-native? '((unless (> 1 2) 'yes))))

    (it "falls back to the general path for a literal too large for Int32"
      (should-match-native? '((let ((n 10)) (if (< n 100000000000) 'yes 'no)))))

    (it "falls back to the numeric tower for a non-integer operand"
      (should-match-native? '((if (< 1.5 2) 'yes 'no)))
      (should-match-native? '((let ((x 1.5)) (if (< x 2) 'yes 'no)))))

    (it "does not fuse (and stays correct) when the 1st operand isn't a leaf"
      (should-match-native? '((let ((n 5)) (let ((f (lambda () (if (< (begin (set! n 100) 0) n) 'yes 'no)))) (f))))))

    (it "leaves cond/guard clause tests unfused, since their value can be observed"
      (should-match-native? '((cond ((< 1 2)) (else 'none))))
      (should-match-native? '((cond ((assoc 2 (list (cons 1 'a) (cons 2 'b))) => cdr) (else 'none)))))

    (it "still compiles a non-comparison test through the general path"
      (should-match-native? '((if 'ok 1 2)))
      (should-match-native? '((if (car (list #t)) 1 2)))))

  (describe "fused callee load (Call* ops)"
    (it "computes correctly for a global callee (non-tail and tail)"
      (should-match-native? '((define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10)))
      (should-match-native? '((define (sum-to n acc) (if (= n 0) acc (sum-to (- n 1) (+ acc n)))) (sum-to 1000 0))))

    (it "computes correctly for a local callee"
      (should-match-native? '((let ((sq (lambda (x) (* x x)))) (sq 7))))
      (should-match-native? '((let ((add (lambda (a b) (+ a b)))) (add 3 4)))))

    (it "computes correctly for a closed-over (upvalue) callee, incl. named-let loops"
      (should-match-native? '((define (build n) (let loop ((i 0) (acc '())) (if (= i n) acc (loop (+ i 1) (cons i acc))))) (length (build 100))))
      (should-match-native? '((let ((f (lambda (x) (* x 2)))) (let ((g (lambda (y) (f (f y))))) (g 5))))))

    (it "computes correctly for mutual recursion (both global)"
      (should-match-native? '((define (ev? n) (if (= n 0) #t (od? (- n 1)))) (define (od? n) (if (= n 0) #f (ev? (- n 1)))) (list (ev? 10) (ev? 7)))))

    (it "picks up a runtime redefinition of a global callee (cache version check)"
      (should-match-native? '((define (f) (g)) (define (g) 1) (define a (f)) (set! g (lambda () 2)) (define b (f)) (list a b))))

    (it "calls the global, not a same-named local shadowing it elsewhere"
      (should-match-native? '((define (h x) (* x 10)) (list (let ((h (lambda (x) (+ x 100)))) (h 5)) (h 5)))))

    (it "still compiles a compound callee through the general path"
      (should-match-native? '((define fns (list (lambda (x) (+ x 1)) (lambda (x) (* x 2)))) (list ((car fns) 5) ((cadr fns) 5))))
      (should-match-native? '(((lambda (x y) (+ x y)) 3 4)))))

  (describe "fused tail return (bare name in tail position)"
    (it "returns a local directly, including when dst differs from its own register"
      (should-match-native? '((define (second a b) b) (second 1 2)))
      (should-match-native? '((define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10))))

    (it "returns a global directly (ReturnGlobal)"
      (should-match-native? '((define x 5) (define (f) x) (f))))

    (it "returns a closed-over upvalue directly (ReturnUpval)"
      (should-match-native? '((let ((v 42)) (let ((g (lambda () v))) (g))))))

    (it "still works correctly for a non-tail read of the same shapes"
      (should-match-native? '((define x 5) (define (f) x) (+ 1 (f))))
      (should-match-native? '((+ 1 (let ((v 1)) (let ((h (lambda () v))) (h)))))))

    (it "picks up a runtime redefinition of a returned global"
      (should-match-native? '((define (f) g) (define g 1) (define a (f)) (set! g 2) (define b (f)) (list a b)))))

  (describe "fused tail return (prim call in tail position)"
    (it "fuses fib's own tail (+ (fib ...) (fib ...)) shape (AddReturn)"
      (should-match-native? '((define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10))))

    (it "fuses a plain 2-register-operand tail op"
      (should-match-native? '((define (f a b) (+ a b)) (f 3 4)))
      (should-match-native? '((define (f a b) (< a b)) (f 3 4))))

    (it "does not fuse a non-tail prim call"
      (should-match-native? '((define (f a b) (+ (+ a b) 1)) (f 3 4))))

    (it "does not affect vector-set!/string-set!/bytevector-u8-set! in tail position (unfused, still return the object)"
      (should-match-native? '((define (f v i x) (vector-set! v i x) v) (define v (vector 1 2 3)) (f v 0 9) (vector->list v)))
      (should-match-native? '((define (f v i x) (vector-set! v i x)) (define v (vector 1 2 3)) (f v 0 9) (vector->list v)))))

  (describe "eq? fusion (IsEq family)"
    (it "computes correctly for the base 2-register op, across value types"
      (should-match-native? '((let ((a 'x) (b 'x)) (eq? a b))))
      (should-match-native? '((let ((a 'x) (b 'y)) (eq? a b))))
      (should-match-native? '((let ((a 5) (b 5)) (eq? a b))))
      (should-match-native? '((let ((a 5) (b 5.0)) (eq? a b))))
      (should-match-native? '((let ((a #\a) (b #\a)) (eq? a b))))
      (should-match-native? '((let ((a #t) (b #t)) (eq? a b))))
      (should-match-native? '((let ((a '()) (b '())) (eq? a b))))
      (should-match-native? '((let ((p (cons 1 2))) (eq? p p))))
      (should-match-native? '((eq? (cons 1 2) (cons 1 2))))
      (should-match-native? '((eq? 0.0 -0.0))))

    (it "computes correctly with a small-integer-literal 2nd operand (Imm)"
      (should-match-native? '((let ((n 5)) (eq? n 5))))
      (should-match-native? '((let ((n 5)) (eq? n 6))))
      (should-match-native? '((let ((n 'sym)) (eq? n 5)))))

    (it "falls back to the general path for a literal too large for Int32"
      (should-match-native? '((let ((n 5)) (eq? n 5000000000)))))

    (it "computes correctly with a closed-over 2nd operand (Up)"
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (eq? x n)))) (f 5)))))
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (eq? x n)))) (f 6)))))
      (should-match-native? '((let ((n 'sym)) (let ((f (lambda (x) (eq? x n)))) (f 'sym))))))

    (it "computes correctly for the if/when fused compare-and-branch (TestIsEq family)"
      (should-match-native? '((if (eq? 'x 'x) 'yes 'no)))
      (should-match-native? '((if (eq? 'x 'y) 'yes 'no)))
      (should-match-native? '((let ((n 5)) (if (eq? n 5) 'yes 'no))))
      (should-match-native? '((let ((n 5)) (let ((f (lambda (x) (if (eq? x n) 'yes 'no)))) (f 5)))))
      (should-match-native? '((when (eq? 1 1) 'yes)))
      (should-match-native? '((unless (eq? 1 1) 'yes))))

    (it "leaves cond/guard clause tests unfused (materializes via base IsEq + TestFalse), since their value can be observed"
      (should-match-native? '((cond ((eq? 1 1)) (else 'none))))
      (should-match-native?
        '((define (get-list alist key)
            (cond ((null? alist) #f)
                  ((eq? (caar alist) key) (cdar alist))
                  (else (get-list (cdr alist) key))))
          (get-list (list (cons 'a 'a-val) (cons 'b 'b)) 'b))))

    (it "fuses a plain 2-register-operand tail call (IsEqReturn)"
      (should-match-native? '((define (f a b) (eq? a b)) (f 3 3)))
      (should-match-native? '((define (f a b) (eq? a b)) (f 3 4))))

    (it "does not specialize a call whose head is shadowed by a local binding"
      (should-match-native? '((let ((eq? (lambda (a b) 'local))) (eq? 1 1)))))))

;; ---------------------------------------------------------------------------
;; Moved here from throughout the describe groups above -- every case that
;; permanently redefines a widely-used builtin at the top level (see this
;; file's own header comment for the mechanism and why should-match-native?
;; is still safe here). MUST run last: nothing below this point may rely on
;; the real/unshadowed meaning of +, vector-ref, vector-set!, vector-length,
;; string-ref, string-set!, bytevector-u8-ref, bytevector-u8-set!, <, or eq?
;; ever again in this process.
;; ---------------------------------------------------------------------------
(describe "deopt on redefinition of a fusable primitive (moved to the end -- see header comment)"
  (describe "+"
    (it "deopts + to a runtime redefinition"
      (should-match-native? '((define (+ a b) (list 'shadowed a b)) (+ 1 2))))
    (it "still deopts to a runtime redefinition (Imm-shaped call site)"
      (should-match-native? '((define (+ a b) (list 'shadowed a b)) (+ 1 2))))
    (it "still deopts to a runtime redefinition (Up-shaped call site)"
      (should-match-native? '((define (+ a b) (list 'shadowed a b)) (let ((n 2)) (let ((f (lambda (x) (+ x n)))) (f 1))))))
    (it "still deopts a tail-position call when + is redefined before compiling"
      (should-match-native? '((define (+ a b) (list 'shadowed a b)) (define (f a b) (+ a b)) (f 1 2)))))

  (describe "vector-ref/vector-set!/vector-length"
    (it "deopts vector-ref to a runtime redefinition"
      (should-match-native? '((define (vector-ref v i) 'shadowed) (vector-ref (vector 1 2) 0))))
    (it "deopts vector-set! to a runtime redefinition"
      (should-match-native? '((define (vector-set! v i x) 'shadowed) (vector-set! (vector 1 2) 0 9))))
    (it "deopts vector-length to a runtime redefinition"
      (should-match-native? '((define (vector-length v) 'shadowed) (vector-length (vector 1 2)))))
    (it "still deopts to a runtime redefinition (closed-over object operand)"
      (should-match-native? '((define (vector-ref v i) 'shadowed) (let ((vv (vector 1 2))) (let ((f (lambda (i) (vector-ref vv i)))) (f 0))))))
    (it "still deopts to a runtime redefinition (VecRefImm/VecSetImm-shaped call site)"
      (should-match-native? '((define (vector-ref v i) 'shadowed) (vector-ref (vector 1 2) 0)))
      (should-match-native? '((define (vector-set! v i x) 'shadowed) (vector-set! (vector 1 2) 0 9)))))

  (describe "string-ref/string-set!"
    (it "deopts string-ref to a runtime redefinition"
      (should-match-native? '((define (string-ref s i) 'shadowed) (string-ref "ab" 0))))
    (it "deopts string-set! to a runtime redefinition"
      (should-match-native? '((define (string-set! s i c) 'shadowed) (string-set! (make-string 2) 0 #\a))))
    (it "still deopts to a runtime redefinition (string Imm-shaped call site)"
      (should-match-native? '((define (string-ref s i) 'shadowed) (string-ref "ab" 0)))
      (should-match-native? '((define (string-set! s i c) 'shadowed) (string-set! (make-string 2) 0 #\a)))))

  (describe "bytevector-u8-ref/bytevector-u8-set!"
    (it "deopts bytevector-u8-ref to a runtime redefinition"
      (should-match-native? '((define (bytevector-u8-ref b i) 'shadowed) (bytevector-u8-ref (make-bytevector 2) 0))))
    (it "deopts bytevector-u8-set! to a runtime redefinition"
      (should-match-native? '((define (bytevector-u8-set! b i x) 'shadowed) (bytevector-u8-set! (make-bytevector 2) 0 1))))
    (it "still deopts to a runtime redefinition (bytevector Imm-shaped call site)"
      (should-match-native? '((define (bytevector-u8-ref b i) 'shadowed) (bytevector-u8-ref (make-bytevector 2) 0)))
      (should-match-native? '((define (bytevector-u8-set! b i x) 'shadowed) (bytevector-u8-set! (make-bytevector 2) 0 1)))))

  (describe "<"
    (it "still deopts to a runtime redefinition"
      (should-match-native? '((define (< a b) 'shadowed) (if (< 1 2) 'yes 'no)))))

  (describe "eq?"
    (it "still deopts to a runtime redefinition"
      (should-match-native? '((define (eq? a b) 'shadowed) (eq? 1 1)))
      (should-match-native? '((define (eq? a b) 'shadowed) (if (eq? 1 1) 'yes 'no)))
      (should-match-native? '((define (eq? a b) 'shadowed) (define (f a b) (eq? a b)) (f 1 1))))))

(spec-summary!)
