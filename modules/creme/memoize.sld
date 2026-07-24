;; ===========================================================================
;; (creme memoize): general-purpose function-result caching
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme html)/(creme path)/(creme extra) use) rather than compiled into
;; the interpreter binary, since every export here is expressible in plain
;; R7RS on top of (creme hash-table)'s own primitives, with no opaque
;; foreign object or third-party Crystal library of its own involved — see
;; modules/creme/extra.sld's own header comment for the same rationale.
;;
;;   (memoize f) -> a new procedure with the same arity/behavior as f,
;;                  except a repeat call with equal? arguments returns the
;;                  cached result instead of calling f again. The cache key
;;                  is the whole argument list, compared with equal? (same
;;                  key semantics as (creme hash-table) itself) — so
;;                  (memoize row->string) called as (cached id done title)
;;                  caches per distinct (id done title) triple, and a
;;                  later call with a *different* done/title for the same
;;                  id is simply a cache miss, not a stale hit.
;;   (memoize-forget! memoized-f arg ...) -> deletes the cache entry for
;;                  that exact argument list, if any, so the next call
;;                  with those arguments recomputes instead of returning a
;;                  now-stale result — the caller's job, since only it
;;                  knows when the underlying data an argument list used
;;                  to describe has actually changed. `memoized-f` must be
;;                  a value `memoize` itself returned.
;;
;; Entries are kept until explicitly forgotten — there's no automatic
;; expiry/size limit — so this is only correct to use on a pure function
;; (its result depends only on its arguments, with no side effects worth
;; re-running) whose caller is willing to memoize-forget! an argument list
;; whenever the data behind it changes; an argument list that's simply
;; never reused again (e.g. a deleted row's old id/done/title) is safe to
;; just leave uncollected — dead memory, but never served as a wrong
;; answer, since nothing will ever call with that exact argument list
;; again either. Appropriate for something like re-rendering a template
;; whose markup is fully determined by a handful of scalar values (e.g. a
;; database row's id/done/title), not for anything reading further mutable
;; state of its own.
;;
;;   (memoize-lru f max-size) -> like memoize, but self-bounding: once the
;;                  cache holds max-size entries, adding one more first
;;                  evicts whichever argument list was least recently
;;                  looked up (a cache hit counts as a look-up, so a
;;                  frequently-reused argument list is never the one
;;                  evicted just for being old). No memoize-forget! is
;;                  needed/supported for this one — the whole point is
;;                  that the caller never has to think about invalidation;
;;                  it's still only correct for a pure function, same as
;;                  memoize, and bounding *memory* this way says nothing
;;                  about whether a given argument list's real answer has
;;                  changed — as with memoize, correctness under changing
;;                  data comes from choosing a key (argument list) that
;;                  fully determines the result, e.g. (id done title)
;;                  rather than just (id).
;;
;;   (define-memoize (name arg ...) body ...) -> sugar for the dance a
;;                  self-recursive memoized function otherwise needs by
;;                  hand: a plain (define name (memoize (lambda (arg ...)
;;                  body ...))) would only ever cache the OUTERMOST call,
;;                  since body's own recursive calls to `name` close over
;;                  whatever `name` was bound to at lambda-creation time --
;;                  the raw, unmemoized lambda, not the wrapper memoize
;;                  returns a moment later -- so every recursive call
;;                  would bypass the cache entirely. define-memoize
;;                  expands instead to:
;;                    (define name #f)
;;                    (set! name (memoize (lambda (arg ...) body ...)))
;;                  so body's references to `name` resolve at CALL time
;;                  (once name has already been set! to the memoized
;;                  wrapper), not at closure-creation time -- the same
;;                  forward-reference trick (define x #f) ... (set! x
;;                  ...) always needs for a self-referential closure whose
;;                  own name must be the thing callers (including itself)
;;                  actually call. `(name arg ...)` accepts the same
;;                  shapes define's own function form does -- fixed args,
;;                  a dotted rest arg, or a single rest-arg symbol -- and
;;                  the result is a value memoize itself returned, so
;;                  memoize-forget! works on it exactly as it would on a
;;                  by-hand (memoize ...) call.
;;
;; Not auto-imported anywhere — every script that wants this must
;; (import (creme memoize)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme memoize)
  (export memoize memoize-forget! memoize-lru define-memoize)
  (import (scheme base) (creme hash-table))
  (begin
    ;; Maps each memoized wrapper procedure to its own cache, so
    ;; memoize-forget! can find the right cache given just the wrapper a
    ;; caller already has -- keyed by procedure identity (equal? on two
    ;; procedures that aren't the very same object is always #f, so this
    ;; is effectively an eq?-keyed side table, just reusing the same
    ;; equal?-keyed hash-table machinery everything else here uses).
    (define memoize-caches (make-hash-table))

    ;; (memoize f) -> f, wrapped so a repeat call with equal? arguments
    ;; returns the cached result. hash-table-contains? is checked before
    ;; hash-table-ref (rather than using a sentinel default) so a cached
    ;; result of #f or '() is never mistaken for a cache miss.
    (define (memoize f)
      (let* ((cache (make-hash-table))
             (wrapper
              (lambda args
                (if (hash-table-contains? cache args)
                    (hash-table-ref cache args)
                    (let ((result (apply f args)))
                      (hash-table-set! cache args result)
                      result)))))
        (hash-table-set! memoize-caches wrapper cache)
        wrapper))

    ;; (memoize-forget! memoized-f arg ...) -> deletes that one cached
    ;; entry, if present; a no-op if it isn't, or if memoized-f wasn't
    ;; something memoize itself returned.
    (define (memoize-forget! memoized-f . args)
      (let ((cache (hash-table-ref memoize-caches memoized-f (lambda () #f))))
        (if cache (hash-table-delete! cache args) #f)))

    (define (memoize-list-remove x lst)
      (cond
       ((null? lst) '())
       ((equal? (car lst) x) (cdr lst))
       (else (cons (car lst) (memoize-list-remove x (cdr lst))))))

    (define (memoize-list-last lst)
      (if (null? (cdr lst)) (car lst) (memoize-list-last (cdr lst))))

    ;; (memoize-lru f max-size) -> f, wrapped with a size-bounded cache:
    ;; `order` tracks argument lists most-recently-used first, so a hit
    ;; moves its argument list to the front, and a miss that would grow
    ;; the cache past max-size evicts whatever's at the back first.
    (define (memoize-lru f max-size)
      (if (< max-size 1) (error "memoize-lru: max-size must be at least 1" max-size))
      (let ((cache (make-hash-table))
            (order '()))
        (lambda args
          (cond
           ((hash-table-contains? cache args)
            (set! order (cons args (memoize-list-remove args order)))
            (hash-table-ref cache args))
           (else
            (let ((result (apply f args)))
              (if (>= (length order) max-size)
                  (let ((victim (memoize-list-last order)))
                    (hash-table-delete! cache victim)
                    (set! order (memoize-list-remove victim order))))
              (hash-table-set! cache args result)
              (set! order (cons args order))
              result))))))

    ;; (define-memoize (name arg ...) body ...) -- see this file's own
    ;; header comment for the forward-reference problem this solves.
    ;; header is (name . params): params ends up (arg ...) for fixed
    ;; args, (arg ... . rest) for a dotted rest arg, or a bare symbol for
    ;; an all-rest formals list -- exactly the three shapes a lambda's
    ;; own formals position accepts, so no shape-specific handling is
    ;; needed beyond car/cdr.
    (defmacro define-memoize (header . body)
      (let ((name (car header))
            (params (cdr header)))
        (list 'begin
              (list 'define name #f)
              (list 'set! name (list 'memoize (append (list 'lambda params) body))))))))
