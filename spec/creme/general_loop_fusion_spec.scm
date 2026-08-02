;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/compile/general_loop_fusion_
;; spec.cr's own coverage -- see that file's own header comment and
;; bytecode_compiler.cr's try_compile_general_loop for the full rationale:
;; a self-tail-recursive named-let/do that ISN'T a numeric counter (e.g.
;; walking a list via `(cdr ...)`) still lowers to plain mutable registers
;; instead of allocating a fresh Closure on every call, the same way a
;; counted loop already does -- generalizing recognize-counted-loop/
;; compile-counted-loop! (modules/creme/compiler/compiler.sld) by dropping
;; the counter/step/limit requirements entirely.
;;
;; Unlike that native-only Crystal spec, THIS optimization was ported to
;; the self-hosted compiler specifically because icecreme (which always
;; compiles via the self-hosted path, never the native one) got none of
;; last session's native-only closure elimination -- hashtable-test's own
;; `scan` (competition/bench/workloads.scm) is exactly the cond-bodied
;; shape covered here. should-match-native? both confirms the computed
;; VALUE is unaffected and doubles as a native/self-hosted parity check;
;; the actual closure-free bytecode shape was verified interactively via
;; compile-source-to-bytes + --disassemble during development (see this
;; file's own commit message), not asserted inline here -- this compiler
;; has no direct Crystal-spec access to chunk.instructions the way
;; bytecode_compiler.cr's own spec does.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/general_loop_fusion_spec.scm
;;   ./bin/creme --self-hosted spec/creme/general_loop_fusion_spec.scm
;;   ./icecreme/icecreme spec/creme/general_loop_fusion_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "general (non-counted) loop closure elimination (self-hosted compiler)"

  (it "computes correctly for the motivating shape (a cond-based assoc scan, closing over its own key)"
    (should-match-native?
      '((define (make-alist n) (let loop ((i 1) (acc '())) (if (= i n) acc (loop (+ i 1) (cons (cons i (* i 10)) acc)))))
        (define (assoc-scan k alist)
          (let scan ((entries alist))
            (cond ((null? entries) 0)
                  ((= (caar entries) k) (cdar entries))
                  (else (scan (cdr entries))))))
        (define al (make-alist 20))
        (list (assoc-scan 5 al) (assoc-scan 19 al) (assoc-scan 999 al)))))

  (it "computes correctly with no accumulator (for-each style, walking cdr)"
    (should-match-native?
      '((define (count-list lst)
          (let loop ((l lst) (n 0))
            (if (null? l) n (loop (cdr l) (+ n 1)))))
        (count-list '(a b c d e)))))

  (it "computes correctly with multiple loop-carried values and no counter at all"
    (should-match-native?
      '((define (split-evens-odds lst)
          (let loop ((l lst) (evens '()) (odds '()))
            (if (null? l)
                (list (reverse evens) (reverse odds))
                (if (even? (car l))
                    (loop (cdr l) (cons (car l) evens) odds)
                    (loop (cdr l) evens (cons (car l) odds))))))
        (split-evens-odds '(1 2 3 4 5 6 7 8 9 10)))))

  (it "computes correctly when step expressions cross-reference each other's OLD values (needs-temp path)"
    (should-match-native?
      '((define (swap-walk lst a b)
          (let loop ((l lst) (a a) (b b))
            (if (null? l) (list a b) (loop (cdr l) b a))))
        (swap-walk '(x y z) 'first 'second))))

  (it "computes correctly with an early return in the recurse-in-conseq position"
    (should-match-native?
      '((define (find-first pred lst)
          (let loop ((l lst))
            (if (null? l)
                #f
                (if (pred (car l)) (car l) (loop (cdr l))))))
        (list (find-first even? '(1 3 5 6 7)) (find-first even? '(1 3 5 7))))))

  (it "still gives each closure captured inside the loop its own binding (escape check isn't over-eager)"
    (should-match-native?
      '((define (make-escaping-loop n)
          (let loop ((i 0) (acc '()))
            (if (= i n)
                (lambda () acc)
                (loop (+ i 1) (cons (lambda () i) acc)))))
        (map (lambda (f) (f)) ((make-escaping-loop 5))))))

  (it "computes correctly for the equivalent do-loop shape"
    (should-match-native?
      '((define (count-list-do lst)
          (do ((l lst (cdr l)) (n 0 (+ n 1)))
              ((null? l) n)))
        (count-list-do '(a b c d e f)))))

  (it "computes correctly at a larger scale (matching hashtable-test's own order of magnitude)"
    (should-match-native?
      '((define (build-chain n) (let loop ((i 0) (acc '())) (if (= i n) acc (loop (+ i 1) (cons i acc)))))
        (define (sum-via-cdr-walk lst) (let loop ((l lst) (acc 0)) (if (null? l) acc (loop (cdr l) (+ acc (car l))))))
        (sum-via-cdr-walk (build-chain 1000))))))

(spec-summary!)
