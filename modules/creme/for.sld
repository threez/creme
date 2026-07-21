;; ===========================================================================
;; (creme for): a Racket-`for`-family iteration/comprehension library
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme extra)/(creme html) use) rather than compiled into the interpreter
;; binary, since every export here is expressible in plain R7RS with no
;; opaque foreign object, stateful handle, or third-party Crystal library
;; involved — see modules/creme/extra.sld's own header comment for the same
;; rationale.
;;
;; Built with `define-syntax`/`syntax-rules`, NOT `defmacro` (the tool
;; (creme html)/(creme css)/(creme json-builder) use for their own `!`
;; macros): those exist specifically to fold STATIC template content into
;; string literals at macro-expansion time, and a `for` loop's body has no
;; static content to fold — using `defmacro` here would buy nothing while
;; adding its `@global`-only-visible-transformer-body constraint for free.
;; (creme extra)'s own `times` macro is the existing precedent for a plain
;; `syntax-rules` loop-building macro in this codebase and is the model
;; these follow.
;;
;; A macro's expansion is analyzed against the CALLING site's own
;; environment (not the defining library's), for `syntax-rules` exactly
;; the same as `defmacro` — so any free identifier a macro's own template
;; emits must be visible at the use site. Concretely: if `for/and`'s
;; expansion referenced, say, (creme extra)'s `every`, every script using
;; `for/and` would ALSO need `(import (creme extra))` itself, not just
;; `(creme for)`. To avoid that transitive-import footgun, this library is
;; kept FULLY SELF-CONTAINED — its own small helper procedures, duplicated
;; rather than borrowed from `(creme extra)`/`(creme hash-table)` — the
;; same choice those libraries' own header comments state outright for
;; their own escaping helpers. The only dependency is `(scheme base)`.
;;
;; Sequences here are ordinary, already-fully-built LISTS, not Racket's
;; lazy sequences — same spirit as this project's existing `range`/`iota`.
;; This is a deliberate simplification: it loses the ability to iterate a
;; genuinely unbounded sequence (so there is no `in-naturals`), but it lets
;; `for`/`for/list` reuse R7RS's own already-variadic, already-parallel-
;; zipping `map`/`for-each` (2+ lists zip together, stopping at the
;; shortest — see spec/scheme/r7rs/ch06_10_control_features_spec.cr)
;; directly, with no custom zip logic needed for the ordinary parallel-
;; clause case at all. There is deliberately no `in-hash`/`in-indexed`
;; either: `(in-list (hash-table->alist t))` (creme hash-table) already
;; covers hash-table iteration since `hash-table->alist` returns a plain
;; list, and "index + element" is already just a second zipped clause —
;; `(for/list ((x (in-list lst)) (i (in-range (length lst)))) ...)` — for
;; free from `for`'s native multi-clause zip.
;;
;; Every core form below shares the same clause shape as Racket's own:
;; `((var seq-expr) ...) body ...` — one or more `(var seq-expr)` clauses,
;; iterated IN PARALLEL (zipped, stopping at the shortest sequence), then
;; one or more body expressions. `for*`/`for*/list` are the nested
;; (Cartesian-product) counterparts of `for`/`for/list`.
;;
;;   (in-range end)                    -> a list 0, 1, ..., end-1
;;   (in-range start end)              -> a list start, start+1, ..., end-1
;;   (in-range start end step)         -> start, start+step, ... while below
;;                                        end (step > 0) or above it
;;                                        (step < 0); step must not be 0
;;   (in-list lst)                     -> lst itself (identity — purely for
;;                                        read-as-Racket symmetry at a for
;;                                        clause site)
;;   (in-vector v)                     -> (vector->list v)
;;   (in-string s)                     -> (string->list s)
;;
;;   (for ((var seq) ...) body ...)    -> for-each-based side-effecting
;;                                        parallel iteration; unspecified
;;                                        return value
;;   (for/list ((var seq) ...) body ...)     -> map-based collection into
;;                                              a list
;;   (for/vector ((var seq) ...) body ...)   -> collection into a vector
;;   (for/sum ((var seq) ...) body ...)      -> sum of every body result
;;   (for/product ((var seq) ...) body ...)  -> product of every body result
;;   (for/and ((var seq) ...) body ...)      -> #f as soon as body returns
;;                                              #f for some combination
;;                                              (not evaluating body for
;;                                              any later one), else the
;;                                              LAST result (or #t if any
;;                                              sequence is empty)
;;   (for/or ((var seq) ...) body ...)       -> the FIRST truthy body
;;                                              result (not evaluating
;;                                              body past it), or #f if
;;                                              every result was #f (or any
;;                                              sequence is empty)
;;   (for/first ((var seq) ...) body ...)    -> body's result for the
;;                                              FIRST combination only
;;                                              (body is evaluated exactly
;;                                              once), or #f if any
;;                                              sequence is empty
;;   (for/last ((var seq) ...) body ...)     -> body's result for the last
;;                                              combination (every
;;                                              combination must be
;;                                              evaluated — there's no way
;;                                              to know which is last
;;                                              without doing so), or #f if
;;                                              any sequence is empty
;;   (for/fold ((accvar accinit) ...)
;;             ((var seq) ...) body ...)     -> general accumulation: body
;;                                              returns the next round's
;;                                              accumulator value(s) via
;;                                              (values new-acc ...) (a
;;                                              bare single value covers
;;                                              the 1-accumulator case for
;;                                              free); the final
;;                                              accumulator value(s) are
;;                                              for/fold's own result
;;   (for/alist ((var seq) ...) body ...)    -> body returns (values key
;;                                              value); builds a (key .
;;                                              value) alist in iteration
;;                                              order — this project's own
;;                                              convention for object-shaped
;;                                              data, rather than a
;;                                              real (creme hash-table)
;;                                              object (which would need
;;                                              importing that separate
;;                                              opaque-object library too)
;;   (for* ((var seq) ...) body ...)         -> nested (nof for's zipped)
;;                                              iteration: each clause
;;                                              becomes its own loop
;;                                              level, body running once
;;                                              per COMBINATION (a full
;;                                              Cartesian product), purely
;;                                              for side effects
;;   (for*/list ((var seq) ...) body ...)    -> the same nested iteration,
;;                                              collecting every
;;                                              combination's body result
;;                                              into one flat list, in
;;                                              row-major order (first
;;                                              clause outermost)
;;
;; Example:
;;
;;   (for/list ((row (in-list (todo-all)))) (todo-row->html-node row))
;;   (for/list ((x (in-list '(1 2 3))) (y (in-list '(10 20 30)))) (+ x y))
;;     => (11 22 33)                    -- parallel (zipped) clauses
;;   (for*/list ((x (in-list '(1 2))) (y (in-list '(10 20)))) (+ x y))
;;     => (11 21 12 22)                 -- nested (Cartesian) clauses
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme for)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme for)
  (export
    in-range in-list in-vector in-string
    for for/list for/vector for/sum for/product for/and for/or
    for/first for/last for/fold for/alist for* for*/list
    for-and-lists for-or-lists for-first-lists for-fold-lists last-or-false)
  (import (scheme base))
  (begin
    ;; ---- sequence constructors ---------------------------------------------

    (define (in-range-count start end step)
      (if (= step 0) (error "in-range: step must not be 0"))
      (let loop ((i start) (acc '()))
        (if (if (> step 0) (>= i end) (<= i end))
            (reverse acc)
            (loop (+ i step) (cons i acc)))))

    ;; (in-range end) / (in-range start end) / (in-range start end step) --
    ;; see the header comment above.
    (define (in-range . args)
      (cond
       ((null? (cdr args)) (in-range-count 0 (car args) 1))
       ((null? (cddr args)) (in-range-count (car args) (cadr args) 1))
       (else (in-range-count (car args) (cadr args) (car (cddr args))))))

    ;; (in-list lst) -> lst itself -- identity, purely for read-as-Racket
    ;; symmetry with the other in-* forms at a for clause site.
    (define (in-list lst) lst)

    (define (in-vector v) (vector->list v))

    (define (in-string s) (string->list s))

    ;; ---- shared helpers for the forms that need genuine early-exit or
    ;; multi-accumulator threading (everything else below expands straight
    ;; into map/for-each, which already zip N lists natively) -------------

    ;; #t iff any of `lists` is empty -- the shared "any sequence
    ;; exhausted" check every helper below uses to know when to stop.
    (define (any-null-list? lists)
      (and (pair? lists) (or (null? (car lists)) (any-null-list? (cdr lists)))))

    ;; (for-and-lists proc lists) -> #f as soon as (apply proc row) is #f
    ;; for some row (never calling proc on any later row), else the LAST
    ;; result (or #t if any list is empty) -- for/and's engine.
    (define (for-and-lists proc lists)
      (if (any-null-list? lists)
          #t
          (let ((result (apply proc (map car lists))))
            (if result
                (if (any-null-list? (map cdr lists))
                    result
                    (for-and-lists proc (map cdr lists)))
                #f))))

    ;; (for-or-lists proc lists) -> the first truthy (apply proc row)
    ;; (never calling proc on any later row), else #f -- for/or's engine.
    (define (for-or-lists proc lists)
      (if (any-null-list? lists)
          #f
          (or (apply proc (map car lists))
              (for-or-lists proc (map cdr lists)))))

    ;; (for-first-lists proc lists) -> (apply proc row) for the FIRST row
    ;; only, or #f if any list is empty -- for/first's engine.
    (define (for-first-lists proc lists)
      (if (any-null-list? lists) #f (apply proc (map car lists))))

    ;; (last-or-false lst) -> lst's last element, or #f if lst is empty --
    ;; for/last's engine (built on top of for/list, since every combination
    ;; must be evaluated regardless to know which one is last).
    (define (last-or-false lst)
      (if (null? lst) #f (car (reverse lst))))

    ;; (for-fold-lists accs lists proc) -> the final accumulator list, once
    ;; every `lists` position has been folded in: proc is called as
    ;; (apply proc (append accs row)) and must return the next round's
    ;; accumulator(s) via (call-with-values ... list)-friendly (values ...)
    ;; (or a bare single value, for one accumulator) -- for/fold's engine.
    (define (for-fold-lists accs lists proc)
      (if (or (null? lists) (any-null-list? lists))
          accs
          (let* ((row (map car lists))
                 (new-accs (call-with-values (lambda () (apply proc (append accs row))) list)))
            (for-fold-lists new-accs (map cdr lists) proc))))

    ;; ---- core forms ---------------------------------------------------------

    (define-syntax for
      (syntax-rules ()
        ((_ ((var seq) ...) body ...)
         (for-each (lambda (var ...) body ...) seq ...))))

    (define-syntax for/list
      (syntax-rules ()
        ((_ ((var seq) ...) body ...)
         (map (lambda (var ...) body ...) seq ...))))

    (define-syntax for/vector
      (syntax-rules ()
        ((_ ((var seq) ...) body ...)
         (list->vector (for/list ((var seq) ...) body ...)))))

    (define-syntax for/sum
      (syntax-rules ()
        ((_ ((var seq) ...) body ...)
         (apply + (for/list ((var seq) ...) body ...)))))

    (define-syntax for/product
      (syntax-rules ()
        ((_ ((var seq) ...) body ...)
         (apply * (for/list ((var seq) ...) body ...)))))

    (define-syntax for/and
      (syntax-rules ()
        ((_ ((var seq) ...) body ...)
         (for-and-lists (lambda (var ...) body ...) (list seq ...)))))

    (define-syntax for/or
      (syntax-rules ()
        ((_ ((var seq) ...) body ...)
         (for-or-lists (lambda (var ...) body ...) (list seq ...)))))

    (define-syntax for/first
      (syntax-rules ()
        ((_ ((var seq) ...) body ...)
         (for-first-lists (lambda (var ...) body ...) (list seq ...)))))

    (define-syntax for/last
      (syntax-rules ()
        ((_ ((var seq) ...) body ...)
         (last-or-false (for/list ((var seq) ...) body ...)))))

    (define-syntax for/fold
      (syntax-rules ()
        ((_ ((accvar accinit) ...) ((var seq) ...) body ...)
         (apply (lambda (accvar ...) (values accvar ...))
                (for-fold-lists (list accinit ...)
                                (list seq ...)
                                (lambda (accvar ... var ...) body ...))))))

    (define-syntax for/alist
      (syntax-rules ()
        ((_ ((var seq) ...) body ...)
         (for/list ((var seq) ...) (call-with-values (lambda () body ...) cons)))))

    ;; Nested (Cartesian-product) variants: peel one clause off at a time,
    ;; recursing on the rest -- the standard syntax-rules recursive-macro
    ;; idiom (same shape as a textbook let* desugar).
    (define-syntax for*
      (syntax-rules ()
        ((_ ((var seq)) body ...)
         (for-each (lambda (var) body ...) seq))
        ((_ ((var seq) rest ...) body ...)
         (for-each (lambda (var) (for* (rest ...) body ...)) seq))))

    (define-syntax for*/list
      (syntax-rules ()
        ((_ ((var seq)) body ...)
         (map (lambda (var) body ...) seq))
        ((_ ((var seq) rest ...) body ...)
         (apply append (map (lambda (var) (for*/list (rest ...) body ...)) seq)))))))
