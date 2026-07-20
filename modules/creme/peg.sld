;; ===========================================================================
;; (creme peg): a small parser-combinator library (PEG-style)
;;
;; File-based (no FFI of its own — same rationale as modules/creme/
;; numfmt.sld's header comment). Deliberately built as ordinary
;; higher-order functions, not macros: this Scheme's define-syntax/
;; syntax-rules is unhygienic (see the README's Known caveats), so a
;; macro-heavy grammar DSL risks subtle capture bugs exactly where a
;; grammar needs to be trustworthy. Composing plain closures sidesteps
;; that entirely, at the cost of an explicit (str pos) pair everywhere
;; instead of a terser macro syntax -- a thin `define-peg`-style macro
;; could still be layered on top of this later without changing the
;; underlying combinators at all.
;;
;; A parser is a procedure (lambda (str pos) ...) returning either
;;   (cons value new-pos)   on success (new-pos >= pos), or
;;   #f                     on failure (never mutates/consumes anything)
;; Purely functional, so backtracking (peg-alt trying its next
;; alternative from the SAME starting pos after a failure) needs no
;; port-rewind support at all -- every combinator just threads pos
;; through by value.
;;
;;   (peg-lit text)              -> matches `text` literally
;;   (peg-char-pred pred)        -> matches one char satisfying pred
;;   (peg-char-in chars)         -> matches one char that's a member of
;;                                   `chars` (a list of chars)
;;   (peg-char-not-in chars)     -> matches one char that ISN'T a member
;;                                   of `chars` (a list of chars)
;;   (peg-any)                   -> matches any one char (not at EOF)
;;   (peg-eof)                   -> matches only at the end of the string
;;   (peg-seq p ...)             -> each in order; value is the list of
;;                                   each sub-parser's own value, same
;;                                   order (except any (peg-skip p)
;;                                   sub-parser -- see below -- whose
;;                                   value is dropped from that list
;;                                   entirely), fails (whole thing, no
;;                                   partial consumption visible to the
;;                                   caller) if any sub-parser fails
;;   (peg-seq-map (list p ...) f) -> peg-seq's positional-list result is
;;                                   exactly the kind of thing that's easy
;;                                   to miscount (get the wrong list-ref,
;;                                   or forget a peg-skip'd element still
;;                                   changes indices) -- this instead
;;                                   spreads the matched values as
;;                                   SEPARATE ARGUMENTS to `f`, so each
;;                                   one gets a real, meaningful parameter
;;                                   name at the call site instead of a
;;                                   position: (peg-seq-map (list a b c)
;;                                   (lambda (av bv cv) ...))
;;   (peg-skip p)                -> `p`, but its value is omitted from the
;;                                   enclosing peg-seq's result list
;;                                   entirely (not even as #f) -- for a
;;                                   delimiter/punctuation piece a
;;                                   grammar needs to MATCH but never
;;                                   actually uses (a literal "{"/","/
;;                                   whitespace run), so the action
;;                                   doesn't need a throwaway parameter
;;                                   for it at all
;;   (peg-alt p ...)             -> ordered choice: the first alternative
;;                                   that succeeds (from the SAME starting
;;                                   pos each try); fails only if all do
;;   (peg-many p)                -> zero or more `p`, value a list;
;;                                   always succeeds
;;   (peg-many1 p)                -> one or more `p`, value a list
;;   (peg-opt p)                 -> `p` or nothing; value #f if `p`
;;                                   didn't match; always succeeds
;;   (peg-not p)                 -> negative lookahead: succeeds (value
;;                                   #f, consuming nothing) iff `p`
;;                                   itself fails at pos
;;   (peg-map p f)               -> `p`, with its value passed through f
;;   (peg-while pred)            -> (possibly empty) run of chars
;;                                   satisfying pred, value the matched
;;                                   string; always succeeds
;;   (peg-until-lit text)        -> chars up to (not including) the next
;;                                   occurrence of `text`, value the
;;                                   matched string; fails if `text`
;;                                   never occurs before the end of input
;;   (peg-lazy thunk)            -> defers building the actual parser
;;                                   until first USED (parse time), not
;;                                   when peg-lazy itself is called --
;;                                   the standard trick for a
;;                                   self-referential/recursive grammar
;;                                   rule, e.g. (letrec ((stmt (peg-seq
;;                                   ... (peg-lazy (lambda () stmt-list))
;;                                   ...)) (stmt-list (peg-many stmt)))
;;                                   stmt-list) -- stmt's own definition
;;                                   only captures a thunk referencing
;;                                   stmt-list, not stmt-list's value, so
;;                                   it doesn't matter that stmt-list is
;;                                   bound (by this same letrec) after
;;                                   stmt is
;;   (peg-must p message)        -> `p`, but a FAILURE becomes a hard
;;                                   Scheme error (via R7RS `error`,
;;                                   carrying `message`) instead of an
;;                                   ordinary backtrackable failure --
;;                                   for a point in a grammar where
;;                                   there's no other alternative left
;;                                   to try (a "cut"/"commit" point in
;;                                   PEG terms), so a malformed input
;;                                   fails loudly and specifically
;;                                   instead of silently backtracking
;;                                   out of the whole surrounding rule
;;   (peg-balanced-parens)       -> matches one balanced "(...)" group
;;                                   (parens inside a string literal
;;                                   don't affect the depth count;
;;                                   backslash escapes inside such a
;;                                   string are NOT specially handled),
;;                                   value the exact matched text
;;                                   INCLUDING the outer parens; handy
;;                                   for a dialect's "embed a raw Scheme
;;                                   expression" escape hatch
;;   (peg-run p str)             -> runs `p` against str from position 0;
;;                                   returns its value, or raises if `p`
;;                                   fails OR doesn't consume the whole
;;                                   string
;;
;; Example -- a decimal integer:
;;   (define digit (peg-char-pred char-numeric?))
;;   (define integer (peg-map (peg-many1 digit)
;;                             (lambda (ds) (string->number (list->string ds)))))
;;   (peg-run integer "42") ;; => 42
;;
;; Example -- a parenthesized pair "(a, b)", named args + a skipped comma:
;;   (define item (peg-while char-alphabetic?))
;;   (define pair
;;     (peg-seq-map (list (peg-skip (peg-lit "(")) item (peg-skip (peg-lit ","))
;;                         (peg-skip (peg-while char-whitespace?)) item (peg-skip (peg-lit ")")))
;;                  (lambda (a b) (cons a b))))
;;   (peg-run pair "(x, y)") ;; => ("x" . "y") -- `f` only ever sees the two
;;                              real items, not the punctuation around them
;;
;; Not auto-imported anywhere — every parser that wants any of this must
;; (import (creme peg)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme peg)
  (export peg-lit peg-char-pred peg-char-in peg-char-not-in peg-any peg-eof
          peg-seq peg-seq-map peg-skip peg-alt peg-many peg-many1 peg-opt
          peg-not peg-map peg-while peg-until-lit peg-lazy peg-must
          peg-balanced-parens peg-run)
  (import (scheme base))
  (begin
    (define (peg-lit text)
      (lambda (str pos)
        (let ((end (+ pos (string-length text))))
          (if (and (<= end (string-length str)) (string=? (substring str pos end) text))
              (cons text end)
              #f))))

    (define (peg-char-pred pred)
      (lambda (str pos)
        (if (and (< pos (string-length str)) (pred (string-ref str pos)))
            (cons (string-ref str pos) (+ pos 1))
            #f)))

    (define (peg-char-in chars) (peg-char-pred (lambda (c) (memv c chars))))
    (define (peg-char-not-in chars) (peg-char-pred (lambda (c) (not (memv c chars)))))

    (define (peg-any) (peg-char-pred (lambda (c) #t)))

    (define (peg-eof)
      (lambda (str pos)
        (if (= pos (string-length str)) (cons #t pos) #f)))

    ;; A private, unforgeable sentinel (only this module's own peg-skip
    ;; ever produces it) -- peg-seq drops any value `eq?` to it from the
    ;; result list entirely, distinguishing "matched but genuinely not
    ;; interesting" from an ordinary #f/'() value a real sub-parser might
    ;; legitimately produce.
    (define skip-marker (list 'peg-skip))

    (define (peg-skip p) (peg-map p (lambda (v) skip-marker)))

    (define (drop-skipped lst)
      (cond
        ((null? lst) '())
        ((eq? (car lst) skip-marker) (drop-skipped (cdr lst)))
        (else (cons (car lst) (drop-skipped (cdr lst))))))

    (define (peg-seq . parsers)
      (lambda (str pos)
        (let loop ((ps parsers) (p pos) (acc '()))
          (if (null? ps)
              (cons (drop-skipped (reverse acc)) p)
              (let ((r ((car ps) str p)))
                (if r (loop (cdr ps) (cdr r) (cons (car r) acc)) #f))))))

    ;; peg-seq's own positional result list is exactly the kind of thing
    ;; that's easy to miscount -- this spreads it as separate, nameable
    ;; arguments to `f` instead (via `apply`), no macro required.
    (define (peg-seq-map parsers f)
      (peg-map (apply peg-seq parsers) (lambda (vs) (apply f vs))))

    (define (peg-alt . parsers)
      (lambda (str pos)
        (let loop ((ps parsers))
          (if (null? ps)
              #f
              (or ((car ps) str pos) (loop (cdr ps)))))))

    (define (peg-many p)
      (lambda (str pos)
        (let loop ((p2 pos) (acc '()))
          (let ((r (p str p2)))
            (if r (loop (cdr r) (cons (car r) acc)) (cons (reverse acc) p2))))))

    (define (peg-many1 p)
      (peg-map (peg-seq p (peg-many p))
               (lambda (v) (cons (car v) (cadr v)))))

    (define (peg-opt p)
      (lambda (str pos)
        (or (p str pos) (cons #f pos))))

    (define (peg-not p)
      (lambda (str pos)
        (if (p str pos) #f (cons #f pos))))

    (define (peg-map p f)
      (lambda (str pos)
        (let ((r (p str pos)))
          (and r (cons (f (car r)) (cdr r))))))

    (define (peg-while pred)
      (peg-map (peg-many (peg-char-pred pred)) list->string))

    (define (peg-until-lit text)
      (peg-map (peg-many (peg-seq (peg-not (peg-lit text)) (peg-any)))
               (lambda (pairs) (list->string (map cadr pairs)))))

    (define (peg-lazy thunk)
      (lambda (str pos) ((thunk) str pos)))

    (define (peg-must p message)
      (lambda (str pos)
        (or (p str pos) (error message pos))))

    (define (peg-balanced-parens)
      (lambda (str pos)
        (if (or (>= pos (string-length str)) (not (char=? (string-ref str pos) #\()))
            #f
            (let loop ((p (+ pos 1)) (depth 1) (in-string #f))
              (if (>= p (string-length str))
                  #f
                  (let ((c (string-ref str p)))
                    (cond
                      (in-string (loop (+ p 1) depth (not (char=? c #\"))))
                      ((char=? c #\") (loop (+ p 1) depth #t))
                      ((char=? c #\() (loop (+ p 1) (+ depth 1) #f))
                      ((and (char=? c #\)) (= depth 1)) (cons (substring str pos (+ p 1)) (+ p 1)))
                      ((char=? c #\)) (loop (+ p 1) (- depth 1) #f))
                      (else (loop (+ p 1) depth #f)))))))))

    (define (peg-run p str)
      (let ((r (p str 0)))
        (cond
          ((not r) (error "peg: parse failed" str))
          ((< (cdr r) (string-length str)) (error "peg: did not consume all input" (cdr r)))
          (else (car r)))))))
