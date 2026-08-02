;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_04_pairs_lists_spec.cr's
;; own cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses.
;;
;; Unlike that Crystal file (which drives a fresh Creme::Interpreter per
;; `w`/`run` call, embedding each case's Scheme source as a string), this
;; file already runs directly in a real Scheme runtime, so every case is
;; written as ordinary Scheme forms and compared directly against literal
;; expected values via should-equal?/should-raise?, same as bytecode_spec.
;; scm's own approach for testing an API directly rather than comparing
;; two compilers' output.
;;
;; Every procedure exercised here (pair?, cons, car/cdr, set-car!/
;; set-cdr!, caar/cadr/cdar/cddr, null?, list?, list, length, append,
;; reverse, list-tail, list-ref, memq/memv, assq/assv) is an ordinary
;; (scheme base) export with a real icecreme/builtins.c native builtin, so
;; every case passes identically under all three backends. This USED to
;; document a handful of genuine, undocumented icecreme gaps here
;; (list-set!/list-copy/make-list entirely unbound; member/assoc's own C
;; implementations silently ignoring an optional 3rd comparison-predicate
;; argument, each gated behind `it-unless (equal? (spec-vm) "icecreme")`) --
;; all fixed now, so every case below runs unconditionally.
;;
;; Run with:
;;   ./bin/creme spec/creme/r7rs/ch06_04_pairs_lists_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_04_pairs_lists_spec.scm
;;     -- both: all cases pass, 0 pending.
;;   ./icecreme/icecreme spec/creme/r7rs/ch06_04_pairs_lists_spec.scm
;;     -- 0 failures; the five cases above show [PEND]; everything else
;;        passes.
;; ===========================================================================

(import (scheme base) (scheme char) (creme spec))

(describe "R7RS §6.4 Pairs and lists"
  (it "pair? is #t for dotted and proper-list pairs, #f for the empty list and vectors"
    (should-equal? (list (pair? '(a . b)) (pair? '(a b c)) (pair? '()) (pair? '#(a b)))
                   (list #t #t #f #f)))

  (it "cons returns a newly allocated pair whose car/cdr are its two arguments"
    (should-equal? (cons 'a '()) (list 'a))
    (should-equal? (cons '(a) '(b c d)) (list '(a) 'b 'c 'd))
    (should-equal? (cons 'a 3) (cons 'a 3)))

  (it "car/cdr access the pair's fields; it is an error to take car/cdr of the empty list"
    (should-equal? (car '(a b c)) 'a)
    (should-equal? (cdr '((a) b c d)) (list 'b 'c 'd))
    (should-raise? (lambda () (car '()))))

  (it "set-car!/set-cdr! mutate the pair's fields in place"
    (let ((x (list 'a 'b)))
      (set-car! x 'z)
      (should-equal? x (list 'z 'b))))

  (it "caar/cadr/cdar/cddr are the depth-2 compositions of car and cdr"
    (should-equal? (cadr '(a b c)) 'b)
    (should-equal? (caar '((a) b)) 'a))

  (it "null? is #t only for the empty list"
    (should-equal? (list (null? '()) (null? '(a)) (null? 0)) (list #t #f #f)))

  (it "list? is #t for every proper (finite, ()-terminated) list, #f for improper lists"
    (should-equal? (list (list? '(a b c)) (list? '()) (list? '(a . b))) (list #t #t #f)))

  (it "list constructs a newly allocated list of its arguments"
    (should-equal? (list 'a (+ 3 4) 'c) (list 'a 7 'c))
    (should-equal? (list) '()))

  (it "length returns a list's element count"
    (should-equal? (length '(a b c)) 3)
    (should-equal? (length '()) 0))

  (it "append concatenates lists, sharing structure with (only) its last argument"
    (should-equal? (append '(x) '(y)) (list 'x 'y))
    (should-equal? (append '(a) '(b c d)) (list 'a 'b 'c 'd))
    (should-equal? (append '(a b) '(c . d)) (cons 'a (cons 'b (cons 'c 'd))))
    (should-equal? (append) '())
    (should-equal? (append '() 'a) 'a))

  (it "reverse returns a newly allocated list with elements in reverse order"
    (should-equal? (reverse '(a b c)) (list 'c 'b 'a)))

  (it "list-tail returns the sublist obtained by omitting the first k elements"
    (should-equal? (list-tail '(a b c d) 2) (list 'c 'd)))

  (it "list-ref returns the kth element (0-indexed)"
    (should-equal? (list-ref '(a b c d) 2) 'c))

  (it "list-set! stores obj in element k of list"
    (let ((ls (list 'one 'two 'five)))
      (list-set! ls 2 'three)
      (should-equal? ls (list 'one 'two 'three))))

  (it "memq/memv/member return the first sublist whose car matches obj (eq?/eqv?/equal? respectively)"
    (should-equal? (memq 'a '(a b c)) (list 'a 'b 'c))
    (should-equal? (memq 'b '(a b c)) (list 'b 'c))
    (should-be-false? (memq 'a '(b c d)))
    (should-equal? (memv 101 '(100 101 102)) (list 101 102)))

  (it "member accepts an optional third comparison-predicate argument"
    (should-equal? (member "B" '("a" "b" "c") string-ci=?) (list "b" "c")))

  (it "assq/assv/assoc find the first pair in an alist whose car matches obj"
    (let ((e '((a 1) (b 2) (c 3))))
      (should-equal? (assq 'a e) (list 'a 1))
      (should-be-false? (assq 'd e)))
    (should-equal? (assv 5 '((2 3) (5 7) (11 13))) (list 5 7)))

  (it "assoc accepts an optional third comparison-predicate argument"
    (should-equal? (assoc 2.0 (list (list 1 1) (list 2 4) (list 3 9)) =) (list 2 4)))

  (it "list-copy returns a newly allocated shallow copy of a list"
    (let* ((a (list 1 8 2 8))
           (b (list-copy a)))
      (set-car! b 3)
      (should-equal? (list a b) (list (list 1 8 2 8) (list 3 8 2 8)))))

  (it "make-list returns a newly allocated list of k elements, optionally initialized to fill"
    (should-equal? (make-list 2 3) (list 3 3))))

(spec-summary!)
