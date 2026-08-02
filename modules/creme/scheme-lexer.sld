;; ===========================================================================
;; (creme scheme-lexer): a real Scheme-source tokenizer, in pure R7RS -- the
;; shared foundation for a syntax-highlighting REPL that must behave
;; IDENTICALLY across all three runtimes (native Crystal interpreter,
;; --self-hosted, and cvm/cvm). File-based, same rationale as (creme
;; scanner)'s own header comment: every export here is expressible in plain
;; R7RS, so it belongs alongside the other file-based creme.* libraries
;; rather than as native code duplicated per-runtime.
;;
;;   (scheme-tokenize str) -> a list of (kind . text) pairs, in order, whose
;;                             texts concatenate back to EXACTLY str (same
;;                             round-trip contract as this project's other
;;                             TextEdit-facing highlighters -- see (creme
;;                             highlight)'s own header comment). `kind` is
;;                             one of:
;;
;;   open              "(" "[" "#(" "#u8(" -- the FULL prefix text, so
;;                      concatenation still round-trips
;;   close             ")" "]"
;;   string             a complete "..." literal, backslash-escapes honored
;;                      (an escaped quote does not end the string early)
;;   unterminated-string  same, but str ended before the closing quote --
;;                      covers the rest of the input; tells a live-typing
;;                      caller "needs more input" instead of "this is a
;;                      complete, valid string"
;;   char               a complete #\x character literal -- #\a, #\space,
;;                      #\newline, #\x41, including multi-letter names, so a
;;                      "(" that happens to appear inside one is never
;;                      misread as its own token (n/a here: none of R7RS's
;;                      character names contain parens, but this scans the
;;                      full alnum run regardless of what it spells)
;;   line-comment       ";" through end-of-line, NOT including the newline
;;                      itself (the newline becomes its own `whitespace`
;;                      token right after)
;;   block-comment      a complete, properly-nested "#| ... |#" -- an inner
;;                      "#|" increases nesting depth rather than ending the
;;                      outer comment at its first "|#"
;;   unterminated-block-comment  same, but str ended before every level
;;                      closed -- covers the rest of the input
;;   datum-comment      the literal 2 characters "#;" -- just the marker
;;                      itself; which following datum it applies to is out
;;                      of scope for a tokenizer and left to a real reader
;;   symbol             an ordinary identifier/atom that isn't a number or
;;                      boolean literal
;;   number             an atom matching one of the numeric-literal shapes
;;                      below (int/rational/float/complex, +inf.0/-inf.0/
;;                      +nan.0, or a #x/#o/#b/#d/#e/#i-prefixed atom)
;;   boolean            #t #f #true #false (case-insensitive on the long
;;                      forms, matching R7RS)
;;   quote-mark         one of the reader-sugar prefixes: ' ` , ,@ -- as its
;;                      own token, separate from whatever it prefixes
;;   whitespace         a maximal run of spaces/tabs/newlines/etc.
;;   unknown            single-character fallback so the tokenizer always
;;                      makes progress; in practice every character is
;;                      classified by one of the cases above, so this
;;                      should never actually appear, but it's kept as a
;;                      defensive net against a caller ever calling this on
;;                      a character we didn't anticipate (see
;;                      scheme-tokenize's own defensive `end` clamp below)
;;
;; Incomplete-input tolerance is a first-class design goal, not an
;; afterthought: this runs live against a still-being-typed REPL buffer, so
;; scheme-tokenize NEVER raises on truncated input -- an unterminated string
;; or block comment just becomes a distinctly-tagged trailing token that
;; still covers 100% of the remaining text (see unterminated-string /
;; unterminated-block-comment above), letting a caller (a highlighter, or
;; (creme highlight)'s paren-balance) tell "this buffer needs more input"
;; apart from "this token is complete."
;;
;; Implementation note: operates on the string directly via an integer
;; index rather than a port -- (creme scanner)'s port-based primitives
;; don't fit here as-is (its scan-balanced-expr-text's string handling is
;; explicitly naive -- no backslash-escape awareness -- which is exactly
;; what this library needs to get right), and a plain string index turned
;; out simplest to get the nested-comment/escaped-string/char-literal
;; lookahead correct. Not layered on (creme scanner) at all as a result;
;; every helper below is self-contained.
;;
;; Numeric-literal classification below (lex-int-regexp/lex-rational-regexp/
;; lex-float-regexp/lex-complex-regexp/lex-inf-nan-literals, plus
;; lex-delimiter-char? below) is copied VERBATIM (values/logic) from
;; modules/creme/compiler/reader.sld's own classify-token/delimiter-char?,
;; for consistency -- deliberately copied rather than imported: reader.sld
;; doesn't export these (they're internal to its own reader pipeline), and
;; duplicating a handful of regex literals is simpler and safer than
;; reaching into another library's internals. Keep the two in sync by hand
;; if either changes.
;;
;; NAMES are deliberately prefixed (lex-*) rather than reused verbatim,
;; unlike the values/logic above: cvm's self-hosted library loader (see
;; (creme compiler compiler)'s own ensure-library-loaded!) compiles every
;; library's top-level bindings -- exported or not -- into ONE flat global
;; table (cvm's own accepted "no per-import scoping" design; see that
;; file's own comments). Reusing reader.sld's own internal names unprefixed
;; here used to mean importing (creme scheme-lexer) anywhere alongside
;; (scheme eval)/(scheme read) under cvm would silently clobber reader.sld's
;; OWN same-named globals with this library's own (differently-behaved --
;; e.g. this file's own delimiter-char? doesn't treat whitespace as a
;; delimiter, unlike reader.sld's) definitions the moment this library's
;; body ran, corrupting every LATER `read`/`eval` call for the rest of the
;; process (observed as a bogus "unbound variable: <mashed-together tokens>"
;; from `read` no longer treating spaces as token boundaries). Confirmed
;; empirically as the exact cause of that failure before this rename; see
;; cvm/compiler-run.scm's own `read`/`eval` bridge doc comments for the
;; general reentrant-compilation background this bug lives in.
;; ===========================================================================

(define-library (creme scheme-lexer)
  (export scheme-tokenize)
  (import (scheme base) (scheme char) (creme regex))
  (begin

    ;; ---- numeric-literal shapes (copied from (creme compiler reader)) ----
    (define lex-int-regexp (regexp "\\A[+-]?[0-9]+\\z"))
    (define lex-float-regexp (regexp "\\A[+-]?([0-9]+\\.[0-9]*|\\.[0-9]+|[0-9]+)([eE][+-]?[0-9]+)?\\z"))
    (define lex-rational-regexp (regexp "\\A[+-]?[0-9]+/[0-9]+\\z"))
    (define lex-real-part-pattern "[+-]?([0-9]+\\.[0-9]*|\\.[0-9]+|[0-9]+)([eE][+-]?[0-9]+)?")
    (define lex-ureal-pattern "([0-9]+\\.[0-9]*|\\.[0-9]+|[0-9]+)([eE][+-]?[0-9]+)?")
    (define lex-complex-regexp
      (regexp (string-append "\\A(" lex-real-part-pattern "i|(" lex-real-part-pattern ")?[+-](" lex-ureal-pattern ")?i)\\z")))
    (define lex-inf-nan-literals (list "+inf.0" "-inf.0" "+nan.0" "-nan.0"))

    (define (char-index-of str ch start)
      (let ((len (string-length str)))
        (let loop ((i start))
          (cond
            ((>= i len) #f)
            ((char=? (string-ref str i) ch) i)
            (else (loop (+ i 1)))))))

    (define (number-atom? text)
      (cond
        ((member text lex-inf-nan-literals) #t)
        ((regexp-matches? lex-int-regexp text) #t)
        ((regexp-matches? lex-rational-regexp text) #t)
        ((and (regexp-matches? lex-float-regexp text)
              (or (char-index-of text #\. 0) (char-index-of text #\e 0) (char-index-of text #\E 0)))
         #t)
        ((regexp-matches? lex-complex-regexp text) #t)
        (else #f)))

    ;; #x1A / #o17 / #b101 / #d10 / #e1.5 / #i1.5 -- prefix recognized only,
    ;; not further validated (e.g. "#xzz" would still be tagged `number`
    ;; here); punted for v1, see this file's own header comment.
    (define (prefixed-number-atom? text)
      (and (>= (string-length text) 2)
           (char=? (string-ref text 0) #\#)
           (memv (char-downcase (string-ref text 1)) (list #\x #\o #\b #\d #\e #\i))))

    (define (boolean-atom? text)
      (or (string=? text "#t") (string=? text "#f")
          (string-ci=? text "#true") (string-ci=? text "#false")))

    ;; ---- character classes ----
    (define (lex-delimiter-char? c)
      (memv c (list #\( #\) #\[ #\] #\" #\; #\' #\` #\,)))

    ;; Anything that isn't whitespace and isn't one of the delimiters above
    ;; -- deliberately permissive (includes "#" itself, "?" "!" "*" "+" "-"
    ;; "/" "<" ">" "=" ":" "&" etc.) rather than an exact R7RS identifier
    ;; grammar; see this file's own header comment ("doesn't need to be
    ;; 100% R7RS-perfect for this v1").
    (define (atom-char? c) (not (or (char-whitespace? c) (lex-delimiter-char? c))))

    (define (scan-run str i len pred)
      (let loop ((j i))
        (if (and (< j len) (pred (string-ref str j))) (loop (+ j 1)) j)))

    ;; str[i] is the opening double-quote.
    (define (scan-string-token str i len)
      (let loop ((j (+ i 1)))
        (cond
          ((>= j len) (cons 'unterminated-string len))
          ((char=? (string-ref str j) #\\)
           (loop (if (< (+ j 1) len) (+ j 2) (+ j 1))))
          ((char=? (string-ref str j) #\") (cons 'string (+ j 1)))
          (else (loop (+ j 1))))))

    ;; str[i] is "#", str[i+1] is "|". Tracks nesting depth so an inner
    ;; "#|" doesn't end the outer comment at its first "|#".
    (define (scan-block-comment str i len)
      (let loop ((j (+ i 2)) (depth 1))
        (cond
          ((>= j len) (cons 'unterminated-block-comment len))
          ((and (< (+ j 1) len) (char=? (string-ref str j) #\#) (char=? (string-ref str (+ j 1)) #\|))
           (loop (+ j 2) (+ depth 1)))
          ((and (< (+ j 1) len) (char=? (string-ref str j) #\|) (char=? (string-ref str (+ j 1)) #\#))
           (if (= depth 1)
               (cons 'block-comment (+ j 2))
               (loop (+ j 2) (- depth 1))))
          (else (loop (+ j 1) depth)))))

    ;; str[i] is "#", str[i+1] is "\". Consumes the FULL literal: a single
    ;; non-alphabetic char (space, "(", a lone digit, ...) as one character,
    ;; or a full alnum run for a named literal ("space" "newline" "tab") or
    ;; a hex escape ("x41").
    (define (scan-char-token str i len)
      (let ((pos (+ i 2)))
        (cond
          ((>= pos len) (cons 'char len))
          ((char-alphabetic? (string-ref str pos))
           (cons 'char (scan-run str pos len (lambda (c) (or (char-alphabetic? c) (char-numeric? c))))))
          (else (cons 'char (+ pos 1))))))

    ;; Returns (kind . end-index) for the token starting at str[i].
    (define (next-token str i len)
      (let ((c (string-ref str i)))
        (cond
          ((char-whitespace? c) (cons 'whitespace (scan-run str i len char-whitespace?)))
          ((char=? c #\;) (cons 'line-comment (scan-run str i len (lambda (ch) (not (char=? ch #\newline))))))
          ((char=? c #\") (scan-string-token str i len))
          ((or (char=? c #\() (char=? c #\[)) (cons 'open (+ i 1)))
          ((or (char=? c #\)) (char=? c #\])) (cons 'close (+ i 1)))
          ((or (char=? c #\') (char=? c #\`)) (cons 'quote-mark (+ i 1)))
          ((char=? c #\,)
           (if (and (< (+ i 1) len) (char=? (string-ref str (+ i 1)) #\@))
               (cons 'quote-mark (+ i 2))
               (cons 'quote-mark (+ i 1))))
          ((char=? c #\#)
           (let ((c2 (if (< (+ i 1) len) (string-ref str (+ i 1)) #f)))
             (cond
               ((eqv? c2 #\() (cons 'open (+ i 2)))
               ((eqv? c2 #\|) (scan-block-comment str i len))
               ((eqv? c2 #\;) (cons 'datum-comment (+ i 2)))
               ((eqv? c2 #\\) (scan-char-token str i len))
               ((and (eqv? c2 #\u) (< (+ i 3) len)
                     (char=? (string-ref str (+ i 2)) #\8) (char=? (string-ref str (+ i 3)) #\())
                (cons 'open (+ i 4)))
               (else
                (let* ((end (scan-run str i len atom-char?)) (text (substring str i end)))
                  (cons (cond ((boolean-atom? text) 'boolean)
                              ((prefixed-number-atom? text) 'number)
                              (else 'symbol))
                        end))))))
          (else
           (let* ((end (scan-run str i len atom-char?)) (text (substring str i end)))
             (cons (if (number-atom? text) 'number 'symbol) end))))))

    (define (scheme-tokenize str)
      (let ((len (string-length str)))
        (let loop ((i 0) (acc '()))
          (if (>= i len)
              (reverse acc)
              (let* ((result (next-token str i len))
                     (raw-end (cdr result))
                     ;; Defensive: guarantee forward progress even if some
                     ;; future edge case above ever returned end <= i.
                     (progressed? (> raw-end i))
                     (end (if progressed? raw-end (+ i 1)))
                     (kind (if progressed? (car result) 'unknown)))
                (loop end (cons (cons kind (substring str i end)) acc)))))))))
