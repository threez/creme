;; ===========================================================================
;; (creme scanner): small character-port scanning primitives shared by
;; hand-written `#lang` dialect parsers
;;
;; File-based (no FFI of its own — same rationale as modules/creme/
;; numfmt.sld's header comment). Factored out of (creme syntax scss)/
;; (creme syntax slim) — both hand-write a recursive-descent parser
;; straight from characters (see src/scheme/runner.cr's `#lang` doc
;; comment for why: their grammars don't fit Scheme's own Lexer at all),
;; and both kept re-deriving the same few peek-char/read-char idioms
;; under different names. A future from-characters dialect should reach
;; for these before writing its own. This library itself stays a
;; regular, ungrouped `(creme ...)` library rather than living under
;; `(creme syntax ...)` alongside its callers -- it's generically useful
;; text-parsing code, not specific to writing a `#lang` dialect.
;;
;;   (ident-char? c)                  -> alphanumeric, "-", or "_"
;;   (scan-while port pred)           -> the (possibly empty) run of
;;                                        characters at port's current
;;                                        position for which (pred c)
;;                                        holds, consumed; stops at EOF
;;                                        or the first non-matching char
;;                                        (not consumed)
;;   (skip-while port pred)           -> scan-while, discarding the text
;;   (scan-until-char port term?)     -> (cons text terminator), where
;;                                        text is everything up to the
;;                                        first character for which
;;                                        (term? c) holds (that
;;                                        character IS consumed, but not
;;                                        included in text); terminator
;;                                        is #f (at EOF) instead
;;   (scan-balanced-expr-text port)   -> cursor is right at an opening
;;                                        "(" (not yet consumed); returns
;;                                        the exact source text of one
;;                                        balanced expression (parens
;;                                        inside a string literal don't
;;                                        affect the depth count;
;;                                        backslash escapes inside such a
;;                                        string are NOT specially
;;                                        handled), leaving the cursor
;;                                        right after the matching close
;;                                        paren -- handy for a dialect
;;                                        that wants an "embed a raw
;;                                        Scheme expression" escape hatch
;;                                        (e.g. (creme syntax slim)'s `=`) without
;;                                        handing the real reader a
;;                                        partially-consumed shared port
;;                                        directly (see (creme syntax slim)'s own
;;                                        header comment for why that
;;                                        doesn't compose safely)
;;
;; Not auto-imported anywhere — every dialect that wants any of this must
;; (import (creme scanner)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme scanner)
  (export ident-char? scan-while skip-while scan-until-char scan-balanced-expr-text)
  (import (scheme base) (scheme char))
  (begin
    (define (ident-char? c)
      (or (char-alphabetic? c) (char-numeric? c) (char=? c #\-) (char=? c #\_)))

    (define (scan-while port pred)
      (let ((out (open-output-string)))
        (let loop ()
          (let ((c (peek-char port)))
            (if (and (char? c) (pred c))
                (begin (write-char (read-char port) out) (loop))
                (get-output-string out))))))

    (define (skip-while port pred)
      (let loop ()
        (let ((c (peek-char port)))
          (when (and (char? c) (pred c)) (read-char port) (loop)))))

    (define (scan-until-char port term?)
      (let ((out (open-output-string)))
        (let loop ()
          (let ((c (peek-char port)))
            (cond
              ((eof-object? c) (cons (get-output-string out) #f))
              ((term? c) (read-char port) (cons (get-output-string out) c))
              (else (write-char (read-char port) out) (loop)))))))

    (define (scan-balanced-expr-text port)
      (let ((out (open-output-string)))
        (let loop ((depth 0) (in-string #f))
          (let ((c (read-char port)))
            (if (eof-object? c)
                (error "scanner: unterminated expression")
                (begin
                  (write-char c out)
                  (cond
                    (in-string (loop depth (not (char=? c #\"))))
                    ((char=? c #\") (loop depth #t))
                    ((char=? c #\() (loop (+ depth 1) #f))
                    ((and (char=? c #\)) (= depth 1)) (get-output-string out))
                    ((char=? c #\)) (loop (- depth 1) #f))
                    (else (loop depth #f)))))))))))
