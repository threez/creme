;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_08_vectors_spec.cr's
;; own cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses, and spec/creme/r7rs/ch06_13_input_output_spec.scm's
;; own header comment for this project's existing precedent of testing
;; directly (no string-embedding-and-sub-eval needed, since this file
;; already runs in a real Scheme runtime).
;;
;; `vector->list`'s optional start argument USED to be a genuine icecreme gap
;; (icecreme's own bi_vector_to_list, icecreme/builtins.c, used to always convert
;; the WHOLE vector, silently ignoring any start/end arguments) -- fixed,
;; so every case below runs unconditionally now.
;;
;; Run with (all cases pass, 0 pending, under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_08_vectors_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_08_vectors_spec.scm
;;   ./icecreme/icecreme spec/creme/r7rs/ch06_08_vectors_spec.scm
;; ===========================================================================

(import (scheme base) (creme spec))

(describe "R7RS §6.8 Vectors"
  (it "vector? is #t for vector objects, #f for lists"
    (should-equal? (list (vector? #(1 2 3)) (vector? '(1 2))) (list #t #f)))

  (it "make-vector returns a newly allocated vector of k elements, optionally initialized to fill"
    (should-equal? (make-vector 3 'a) #(a a a)))

  (it "vector returns a newly allocated vector whose elements are its arguments"
    (should-equal? (vector 'a 'b 'c) #(a b c)))

  (it "vector-length returns the number of elements in the vector"
    (should-equal? (vector-length (vector 1 2 3)) 3))

  (it "vector-ref returns the contents of element k"
    (should-equal? (vector-ref #(1 1 2 3 5 8 13 21) 5) 8))

  (it "vector-set! stores obj in element k of vector"
    (should-equal?
     (let ((vec (vector 0 '(2 2 2) "Anna")))
       (vector-set! vec 1 (list "Sue" "Sue"))
       vec)
     (vector 0 (list "Sue" "Sue") "Anna")))

  (it "vector->list/list->vector convert between a vector and a list, preserving order, with optional start"
    (should-equal? (vector->list '#(dah dah didah) 1) (list 'dah 'didah))
    (should-equal? (list->vector (list 'dididit 'dah)) #(dididit dah)))

  (it "vector->string/string->vector convert between a vector of characters and a string"
    (should-equal? (vector->string #(#\1 #\2 #\3)) "123")
    (should-equal? (string->vector "ABC") #(#\A #\B #\C)))

  (it "vector-copy returns a newly allocated copy of the given range"
    (should-equal?
     (let* ((a (vector 1 8 2 8))
            (b (vector-copy a)))
       (vector-set! b 0 3)
       (list a b))
     (list #(1 8 2 8) #(3 8 2 8))))

  (it "vector-copy! copies a range of elements from one vector into another at a given offset"
    (should-equal?
     (let ((a (vector 1 2 3 4 5))
           (b (vector 10 20 30 40 50)))
       (vector-copy! b 1 a 0 2)
       b)
     #(10 1 2 40 50)))

  (it "vector-append returns a newly allocated concatenation of its vector arguments"
    (should-equal? (vector-append #(a b c) #(d e f)) #(a b c d e f)))

  (it "vector-fill! stores fill in the elements of a vector between start and end"
    (should-equal?
     (let ((a (vector 1 2 3 4 5)))
       (vector-fill! a 'smash 2 4)
       a)
     #(1 2 smash smash 5)))

  (it "vector-map applies a procedure element-wise across one or more vectors, returning a new vector"
    (should-equal? (vector-map (lambda (n) (expt n n)) #(1 2 3 4 5)) #(1 4 27 256 3125))
    (should-equal? (vector-map + #(1 2 3) #(4 5 6 7)) #(5 7 9)))

  (it "vector-for-each calls a procedure for its side effects over each element in order"
    (should-equal?
     (let ((v (make-vector 5)))
       (vector-for-each (lambda (i) (vector-set! v i (* i i))) #(0 1 2 3 4))
       v)
     #(0 1 4 9 16))))

(spec-summary!)
