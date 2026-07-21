;; ===========================================================================
;; (creme extra): this project's own non-R7RS conveniences
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme sxql) uses) rather than compiled into the interpreter binary,
;; since every export here is expressible in plain R7RS with no opaque
;; foreign object, stateful handle, or third-party Crystal library
;; involved — see modules/creme/sxql.sld's own header comment for the same
;; rationale.
;;
;; Not auto-imported anywhere (unlike (scheme base)/(scheme write), which
;; the REPL still auto-imports at construction — see
;; src/scheme/interpreter/base_library.cr's AUTO_IMPORTED_LIBRARIES).
;; Auto-importing a file-based library would mean reading it off
;; library_search_path before any script runs, which an embedder who
;; never sets library_search_path shouldn't be forced into. Every script
;; that wants filter/reduce/println/etc. must (import (creme extra))
;; explicitly, same as any other file-based library.
;;
;; SRFI-1-style list procedures (filter/reduce/fold*/any/every/count/
;; iota/partition/cons*/append-map/filter-map/last-pair/delete/delete!),
;; interpreter-agnostic printing helpers (print/println), and legacy
;; R5RS numeric-tower aliases (exact->inexact/inexact->exact, both exact
;; synonyms for R7RS's own inexact/exact) plus float?.
;;
;; Does NOT include caddr/cdddr/cadddr/first/second/third/rest/add1/
;; sub1/1+/identity/range/last — those are PRELUDE conveniences defined
;; directly in @base_env (see interpreter/prelude.cr) rather than
;; exported through any library; caddr/cdddr/cadddr are also real
;; (scheme cxr) exports for scripts that want them portably.
;;
;; Deliberately excludes macro?/gensym: both are genuine interpreter-level
;; operations with no R7RS equivalent (macro? needs Crystal-side
;; is_a?(Macro) introspection; a real R7RS syntax-rules transformer isn't
;; a first-class runtime value at all, so there's no way to even ask the
;; question portably — and gensym has no R7RS analog since hygienic
;; syntax-rules expansion generates fresh identifiers automatically,
;; without a runtime call). Both moved to (creme introspection) instead —
;; see src/scheme/interpreter/creme_libraries.cr.
;; ===========================================================================

(define-library (creme extra)
  (export
    any append-map cons* count delete delete!
    every exact->inexact filter filter-map float? foldl foldr
    inexact->exact iota last-pair map-indexed partition print println
    reduce times)
  (import (scheme base) (scheme write))
  (begin
    ;; (times n body ...) — run body n times, purely for its side effects
    ;; (a fresh loop variable isn't bound the way `do` normally provides
    ;; one, since callers using this just want repetition, not an index).
    (define-syntax times
      (syntax-rules ()
        ((_ n body ...)
         (do ((%times-i 0 (+ %times-i 1))) ((= %times-i n))
           body ...))))

    (define (filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
            (else (filter pred (cdr lst)))))

    (define (reduce f init lst)
      (if (null? lst)
          init
          (reduce f (f init (car lst)) (cdr lst))))

    (define foldl reduce)

    (define (foldr f init lst)
      (if (null? lst)
          init
          (f (car lst) (foldr f init (cdr lst)))))

    ;; (iota count [start [step]]) — SRFI-1: a list of count numbers
    ;; starting at start (default 0), stepping by step (default 1).
    (define (iota count . opt)
      (if (< count 0) (error "iota: count must be non-negative"))
      (let ((start (if (pair? opt) (car opt) 0))
            (step (if (and (pair? opt) (pair? (cdr opt))) (cadr opt) 1)))
        (let loop ((i 0) (cur start) (acc '()))
          (if (= i count)
              (reverse acc)
              (loop (+ i 1) (+ cur step) (cons cur acc))))))

    ;; (any pred list...) / (every pred list...) — SRFI-1: short-circuit
    ;; on the first success/failure, stopping at the shortest list.
    (define (any pred . lists)
      (if (null? (car lists))
          #f
          (or (apply pred (map car lists))
              (apply any pred (map cdr lists)))))

    (define (every pred . lists)
      (if (null? (car lists))
          #t
          (let ((result (apply pred (map car lists))))
            (if result
                (if (null? (cdr (car lists)))
                    result
                    (apply every pred (map cdr lists)))
                #f))))

    (define (count pred . lists)
      (let loop ((lists lists) (total 0))
        (if (or (null? lists) (null? (car lists)))
            total
            (loop (map cdr lists) (if (apply pred (map car lists)) (+ total 1) total)))))

    ;; (partition pred list) — two values, matching then non-matching.
    (define (partition pred lst)
      (let loop ((lst lst) (yes '()) (no '()))
        (cond ((null? lst) (values (reverse yes) (reverse no)))
              ((pred (car lst)) (loop (cdr lst) (cons (car lst) yes) no))
              (else (loop (cdr lst) yes (cons (car lst) no))))))

    ;; (filter-map f list...) — maps then drops falsy results.
    (define (filter-map f . lists)
      (let loop ((lists lists) (acc '()))
        (if (or (null? lists) (null? (car lists)))
            (reverse acc)
            (let ((result (apply f (map car lists))))
              (loop (map cdr lists) (if result (cons result acc) acc))))))

    ;; (append-map f list...) — maps then appends (flattens) the results.
    (define (append-map f . lists)
      (apply append (apply map f lists)))

    ;; (delete x list [=]) — removes every element equal? (or =-per the
    ;; optional comparator) to x.
    (define (delete x lst . opt)
      (define same? (if (pair? opt) (car opt) equal?))
      (filter (lambda (candidate) (not (same? x candidate))) lst))
    (define delete! delete)

    (define (cons* . args)
      (let loop ((args args))
        (if (null? (cdr args))
            (car args)
            (cons (car args) (loop (cdr args))))))

    (define (last-pair lst)
      (if (pair? (cdr lst)) (last-pair (cdr lst)) lst))

    ;; (map-indexed f list) — f applied to each element AND its 0-based
    ;; index; e.g. used to unroll a fixed-size, compile-time-known-length
    ;; structure (one vector-ref/vector-set! pair per element, literal
    ;; index baked in) instead of needing a run-time loop.
    (define (map-indexed f lst)
      (let loop ((lst lst) (i 0) (acc '()))
        (if (null? lst)
            (reverse acc)
            (loop (cdr lst) (+ i 1) (cons (f (car lst) i) acc)))))

    (define exact->inexact inexact)
    (define inexact->exact exact)
    (define (float? x) (inexact? x))

    (define (print . args)
      (for-each display args))

    (define (println . args)
      (for-each display args)
      (newline))))
