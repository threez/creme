;; ===========================================================================
;; (creme compiler reader): a self-hosted R7RS reader, built on (creme peg).
;; ===========================================================================
;;
;; Part of the self-hosting bootstrap effort (see the project's own compile
;; pipeline: src/creme/read/lexer.cr + src/creme/read/reader.cr, which this
;; is meant to eventually replace as a Scheme-written equivalent). Verified
;; against the native reader in spec/scheme/modules/creme/compiler/reader_spec.cr:
;; every test string is read by BOTH this file and Creme::Reader.read_all,
;; then the results are compared via `write` (same underlying value objects
;; either way, since this file runs as ordinary Scheme code on top of the
;; real Crystal interpreter/VM -- see (creme bootstrap)/(creme bytecode) for
;; the next stage, which lets a self-hosted COMPILER be verified the same
;; way).
;;
;; Design: (creme peg) combinators drive the lexical layer -- tokens,
;; strings, piped symbols, character literals' name lookup, escape
;; sequences, booleans -- since that's exactly the kind of small ordered-
;; choice grammar PEG is good at. A handful of leaf parsers are hand-written
;; functions sharing the exact same (lambda (str pos) -> (cons value pos) |
;; #f) calling convention instead of being built from smaller combinators:
;; nested block comments (needs a depth counter), dotted-list detection
;; (needs one-token lookahead before deciding whether to recurse or stop),
;; and the list/vector/bytevector structural recursion itself. PEG doesn't
;; naturally express counted nesting or "peek at the next token, then
;; branch" without contortion, so these stay plain recursive Scheme --
;; mirroring the split this project's OWN Lexer/Reader already has.
;;
;; Known gaps (matching this Scheme's own documented R7RS caveats where
;; applicable, see README's "Known caveats"): no #!fold-case directive
;; support (not implemented natively either); datum labels (#n=/#n#) are
;; supported for pairs, including genuine cycles (parse-datum-label,
;; below), but NOT for a self-referential vector specifically (a labeled
;; non-pair datum is just bound to its own value directly, which can't
;; capture a cycle through a vector -- no test in this project's own
;; spec suite needs one); only "\n"-style line continuations inside
;; strings (not "\r\n"); the identifier delimiter set is a reasonable
;; approximation of R7RS's real one, not a byte-for-byte port of
;; lexer.cr's.
;; ===========================================================================

(define-library (creme compiler reader)
  (export read-program form-source-position)
  (import (scheme base) (scheme char) (scheme complex) (creme peg) (creme regex) (creme hash-table)
          (only (creme bytes) list->bytevector))
  (begin

    ;; ---- per-form source positions -----------------------------------------
    ;; For every list form it reads, the reader records the (line . col) where
    ;; that form starts, so the compiler can stamp each instruction with a
    ;; source position (see modules/creme/bytecode.sld's instr `pos` field and
    ;; compiler.sld's compile-expr!). Keyed by FORM IDENTITY via (eq-hash form):
    ;; a plain make-hash-table keys structurally (equal?) and would collide two
    ;; identical sub-forms (e.g. every `(newline)`) onto one line; eq-hash gives
    ;; each object a distinct identity key (its address under non-moving GC).
    ;; current-line-starts holds the offset each source line begins at (rebuilt
    ;; per read-program), so offset->line-col is an O(log lines) binary search
    ;; rather than an O(offset) newline count each time.
    (define form-positions (make-hash-table))
    (define current-line-starts (vector 0))

    (define (compute-line-starts str)
      (let ((len (string-length str)))
        (let loop ((i 0) (acc (list 0)))
          (if (>= i len)
              (list->vector (reverse acc))
              (loop (+ i 1)
                    (if (char=? (string-ref str i) #\newline) (cons (+ i 1) acc) acc))))))

    ;; offset -> (line . col), both 1-based -- the last line whose start is <=
    ;; offset, via binary search on current-line-starts.
    (define (offset->line-col offset)
      (let ((starts current-line-starts))
        (let loop ((lo 0) (hi (- (vector-length starts) 1)))
          (if (>= lo hi)
              (cons (+ lo 1) (+ (- offset (vector-ref starts lo)) 1))
              (let ((mid (quotient (+ lo hi 1) 2)))
                (if (<= (vector-ref starts mid) offset)
                    (loop mid hi)
                    (loop lo (- mid 1))))))))

    (define (record-form-position! form offset)
      (hash-table-set! form-positions (eq-hash form) (offset->line-col offset)))

    ;; (form-source-position form) -> (line . col), or #f if the reader never
    ;; saw this exact form (e.g. one a macro synthesized).
    (define (form-source-position form)
      (let ((k (eq-hash form)))
        (if (hash-table-contains? form-positions k)
            (hash-table-ref form-positions k)
            #f)))

    ;; ---------------------------------------------------------------------
    ;; Numeric literal classification -- `string->number` (the RUNTIME
    ;; procedure) only understands plain unprefixed integers/floats in this
    ;; implementation; radix/exactness prefixes, rationals, and complex
    ;; literals are parsed by the LEXER instead (src/creme/read/lexer.cr's
    ;; own INT_RE/FLOAT_RE/RATIONAL_RE/COMPLEX_RE), so this reader must
    ;; replicate that grammar itself rather than delegating to string->number
    ;; wholesale. (creme regex) gives real regex objects to classify a raw
    ;; token's shape faithfully instead of hand-rolling character-class
    ;; scanners for it; extracting the pieces (rational numerator/
    ;; denominator, complex real/imaginary parts) is still plain string
    ;; splitting, same division of labor as the rest of this file.
    ;; ---------------------------------------------------------------------

    (define int-regexp (regexp "\\A[+-]?[0-9]+\\z"))
    (define float-regexp (regexp "\\A[+-]?([0-9]+\\.[0-9]*|\\.[0-9]+|[0-9]+)([eE][+-]?[0-9]+)?\\z"))
    (define rational-regexp (regexp "\\A[+-]?[0-9]+/[0-9]+\\z"))
    (define real-part-pattern "[+-]?([0-9]+\\.[0-9]*|\\.[0-9]+|[0-9]+)([eE][+-]?[0-9]+)?")
    (define ureal-pattern "([0-9]+\\.[0-9]*|\\.[0-9]+|[0-9]+)([eE][+-]?[0-9]+)?")
    (define complex-regexp
      (regexp (string-append "\\A(" real-part-pattern "i|(" real-part-pattern ")?[+-](" ureal-pattern ")?i)\\z")))

    ;; +inf.0/-inf.0/+nan.0 are written here as literals, read by the REAL
    ;; native reader that loads this very file -- reusing the host's own
    ;; literal support instead of re-deriving IEEE infinity/NaN by hand.
    (define inf-nan-literals
      (list (cons "+inf.0" +inf.0) (cons "-inf.0" -inf.0) (cons "+nan.0" +nan.0) (cons "-nan.0" +nan.0)))

    (define (char-index-of str ch start)
      (let ((len (string-length str)))
        (let loop ((i start))
          (cond
            ((>= i len) #f)
            ((char=? (string-ref str i) ch) i)
            (else (loop (+ i 1)))))))

    (define (parse-rational text)
      (let ((slash (char-index-of text #\/ 0)))
        (/ (string->number (substring text 0 slash))
           (string->number (substring text (+ slash 1) (string-length text))))))

    ;; Splits a complex literal's body (the text before the trailing "i") into
    ;; its real and imaginary parts by scanning backward for the separating
    ;; sign -- skipping one that's actually an exponent's sign (the char right
    ;; before it would be "e"/"E" in that case, e.g. the "+" in "1e+5i").
    (define (find-imag-split body)
      (let loop ((i (- (string-length body) 1)))
        (cond
          ((< i 1) #f)
          ((and (or (char=? (string-ref body i) #\+) (char=? (string-ref body i) #\-))
                (not (memv (string-ref body (- i 1)) (list #\e #\E))))
           i)
          (else (loop (- i 1))))))

    (define (parse-signed-imag-magnitude s)
      (cond
        ((string=? s "+") 1)
        ((string=? s "-") -1)
        ((= (string-length s) 0) 1)
        (else (string->number s))))

    (define (parse-complex text)
      (let* ((body (substring text 0 (- (string-length text) 1)))
             (split (find-imag-split body)))
        (if (not split)
            (make-rectangular 0 (parse-signed-imag-magnitude body))
            (make-rectangular (string->number (substring body 0 split))
                               (parse-signed-imag-magnitude (substring body split (string-length body)))))))

    (define (classify-token text)
      (cond
        ((assoc text inf-nan-literals) => cdr)
        ((regexp-matches? int-regexp text) (string->number text))
        ((regexp-matches? rational-regexp text) (parse-rational text))
        ((and (regexp-matches? float-regexp text)
              (or (char-index-of text #\. 0) (char-index-of text #\e 0) (char-index-of text #\E 0)))
         (string->number text))
        ((regexp-matches? complex-regexp text) (parse-complex text))
        (else (string->symbol text))))

    ;; Radix (#b/#o/#d/#x) and exactness (#e/#i) prefixes -- lexer-side only,
    ;; same restriction as lex_prefixed_number: no rational/complex support
    ;; here, and #e truncates a float source to an exact integer (matching
    ;; that method's own `value.to_i64` — a real, intentionally-replicated
    ;; quirk of this Scheme's own reader, not a new one).
    (define (parse-prefixed-number str pos)
      (let loop ((p pos) (radix 10) (exactness #f))
        (if (and (< (+ p 1) (string-length str)) (char=? (string-ref str p) #\#))
            (let ((letter (char-downcase (string-ref str (+ p 1)))))
              (cond
                ((char=? letter #\b) (loop (+ p 2) 2 exactness))
                ((char=? letter #\o) (loop (+ p 2) 8 exactness))
                ((char=? letter #\d) (loop (+ p 2) 10 exactness))
                ((char=? letter #\x) (loop (+ p 2) 16 exactness))
                ((char=? letter #\e) (loop (+ p 2) radix #\e))
                ((char=? letter #\i) (loop (+ p 2) radix #\i))
                (else (finish-prefixed-number str pos p radix exactness))))
            (finish-prefixed-number str pos p radix exactness))))

    (define (finish-prefixed-number str start-pos token-start radix exactness)
      (let ((r (raw-token-parser str token-start)))
        (if (not r)
            (error "reader: expected digits after numeric prefix" start-pos)
            (let* ((text (car r))
                   (end (cdr r))
                   (value (if (= radix 10) (string->number text) (string->number text radix))))
              (if (not value)
                  (error "reader: invalid numeric literal" text)
                  (cons (apply-exactness value exactness) end))))))

    (define (apply-exactness value exactness)
      (cond
        ((eqv? exactness #\i) (inexact value))
        ((eqv? exactness #\e) (exact (truncate value)))
        (else value)))

    ;; ---------------------------------------------------------------------
    ;; Character classes
    ;; ---------------------------------------------------------------------

    (define (whitespace-char? c)
      (or (char=? c #\space) (char=? c #\tab) (char=? c #\newline) (char=? c #\return)))

    (define (delimiter-char? c)
      (or (char=? c #\() (char=? c #\)) (char=? c #\[) (char=? c #\])
          (char=? c #\") (char=? c #\;) (char=? c #\|) (whitespace-char? c)))

    (define (token-char? c) (not (delimiter-char? c)))

    (define (hex-digit? c)
      (or (and (char>=? c #\0) (char<=? c #\9))
          (and (char>=? (char-downcase c) #\a) (char<=? (char-downcase c) #\f))))

    (define (hex-string? s)
      (and (> (string-length s) 0)
           (let loop ((i 0))
             (or (= i (string-length s))
                 (and (hex-digit? (string-ref s i)) (loop (+ i 1)))))))

    (define (remove-false lst)
      (cond
        ((null? lst) '())
        ((eq? (car lst) #f) (remove-false (cdr lst)))
        (else (cons (car lst) (remove-false (cdr lst))))))

    ;; ---------------------------------------------------------------------
    ;; Atmosphere (whitespace + comments) -- hand-written: nested block
    ;; comments need a depth counter, and datum comments (#;) need to read
    ;; and discard one full datum, recursing back into read-datum.
    ;; ---------------------------------------------------------------------

    (define (skip-line-comment str pos)
      (let ((len (string-length str)))
        (let loop ((p (+ pos 1)))
          (cond
            ((>= p len) p)
            ((char=? (string-ref str p) #\newline) (+ p 1))
            (else (loop (+ p 1)))))))

    (define (skip-block-comment str pos)
      ;; str[pos..pos+1] == "#|"
      (let ((len (string-length str)))
        (let loop ((p (+ pos 2)) (depth 1))
          (cond
            ((>= p len) (error "reader: unterminated block comment"))
            ((and (< (+ p 1) len) (char=? (string-ref str p) #\#) (char=? (string-ref str (+ p 1)) #\|))
             (loop (+ p 2) (+ depth 1)))
            ((and (< (+ p 1) len) (char=? (string-ref str p) #\|) (char=? (string-ref str (+ p 1)) #\#))
             (if (= depth 1) (+ p 2) (loop (+ p 2) (- depth 1))))
            (else (loop (+ p 1) depth))))))

    (define (skip-atmosphere str pos)
      (let ((len (string-length str)))
        (cond
          ((>= pos len) pos)
          ((whitespace-char? (string-ref str pos)) (skip-atmosphere str (+ pos 1)))
          ((char=? (string-ref str pos) #\;) (skip-atmosphere str (skip-line-comment str pos)))
          ((and (< (+ pos 1) len) (char=? (string-ref str pos) #\#) (char=? (string-ref str (+ pos 1)) #\|))
           (skip-atmosphere str (skip-block-comment str pos)))
          ((and (< (+ pos 1) len) (char=? (string-ref str pos) #\#) (char=? (string-ref str (+ pos 1)) #\;))
           (let ((r (read-datum str (+ pos 2))))
             (if (not r)
                 (error "reader: expected a datum after #;" pos)
                 (skip-atmosphere str (cdr r)))))
          (else pos))))

    ;; ---------------------------------------------------------------------
    ;; Lexical layer -- built from (creme peg) combinators.
    ;; ---------------------------------------------------------------------

    ;; A maximal run of token chars -- fails (via peg-many1) if there's
    ;; nothing to consume at `pos`, so callers can tell "no token here" apart
    ;; from "an empty token".
    (define raw-token-parser (peg-map (peg-many1 (peg-char-pred token-char?)) list->string))

    (define escape-body-parser
      (peg-alt
        (peg-map (peg-lit "n") (lambda (v) #\newline))
        (peg-map (peg-lit "t") (lambda (v) #\tab))
        (peg-map (peg-lit "r") (lambda (v) #\return))
        (peg-map (peg-lit "a") (lambda (v) (integer->char 7)))
        (peg-map (peg-lit "b") (lambda (v) (integer->char 8)))
        (peg-map (peg-lit "0") (lambda (v) (integer->char 0)))
        (peg-map (peg-lit "\\") (lambda (v) #\\))
        (peg-map (peg-lit "\"") (lambda (v) #\"))
        (peg-map (peg-lit "|") (lambda (v) #\|))
        (peg-seq-map (list (peg-skip (peg-lit "x")) (peg-many1 (peg-char-pred hex-digit?)) (peg-skip (peg-lit ";")))
                     (lambda (digits) (integer->char (string->number (list->string digits) 16))))
        ;; Line continuation: backslash already consumed; <intraline ws>* <newline> <intraline ws>*
        ;; elides to nothing (represented here as #f, filtered out by remove-false).
        (peg-map
          (peg-seq (peg-many (peg-char-in (list #\space #\tab)))
                   (peg-lit "\n")
                   (peg-many (peg-char-in (list #\space #\tab))))
          (lambda (v) #f))))

    (define (quoted-literal-parser delim)
      (let ((close-char (string-ref delim 0)))
        (peg-seq-map
          (list (peg-skip (peg-lit delim))
                (peg-many (peg-alt
                            (peg-seq-map (list (peg-skip (peg-lit "\\")) escape-body-parser) (lambda (v) v))
                            (peg-char-not-in (list close-char #\\))))
                (peg-skip (peg-lit delim)))
          (lambda (chars) (list->string (remove-false chars))))))

    (define string-literal-parser (quoted-literal-parser "\""))
    (define piped-symbol-parser (peg-map (quoted-literal-parser "|") string->symbol))

    (define bool-literal-parser
      (peg-map
        (peg-seq (peg-alt (peg-lit "#true") (peg-lit "#false") (peg-lit "#t") (peg-lit "#f"))
                 (peg-not (peg-char-pred token-char?)))
        (lambda (parts) (let ((text (car parts))) (or (string=? text "#t") (string=? text "#true"))))))

    (define char-names
      (list (cons "space" #\space) (cons "newline" #\newline) (cons "tab" #\tab)
            (cons "return" #\return) (cons "nul" (integer->char 0)) (cons "null" (integer->char 0))
            (cons "alarm" (integer->char 7)) (cons "backspace" (integer->char 8))
            (cons "delete" (integer->char 127)) (cons "rubout" (integer->char 127))
            (cons "escape" (integer->char 27)) (cons "altmode" (integer->char 27))))

    ;; ---------------------------------------------------------------------
    ;; Structural layer -- hand-written recursion over (str, pos).
    ;; ---------------------------------------------------------------------

    (define (parse-token str pos)
      (let ((r (raw-token-parser str pos)))
        (if (not r)
            #f
            (cons (classify-token (car r)) (cdr r)))))

    (define (parse-char-literal str pos)
      ;; str[pos..pos+1] == "#\"
      (let ((start (+ pos 2)))
        (if (>= start (string-length str))
            (error "reader: unexpected end of input after #\\" pos)
            (let ((r (raw-token-parser str start)))
              (cond
                ((and r (> (- (cdr r) start) 1))
                 (let* ((name (car r)) (end (cdr r)) (lname (string-downcase name)))
                   (cond
                     ((and (>= (string-length lname) 2)
                           (char=? (string-ref lname 0) #\x)
                           (hex-string? (substring lname 1 (string-length lname))))
                      (cons (integer->char (string->number (substring lname 1 (string-length lname)) 16)) end))
                     ((assoc lname char-names) => (lambda (p) (cons (cdr p) end)))
                     (else (error "reader: unknown character name" name)))))
                (else (cons (string-ref str start) (+ start 1))))))))

    (define (parse-vector str pos)
      ;; str[pos..pos+1] == "#("
      (let ((r (parse-list-items str (+ pos 2) #\))))
        (cons (list->vector (car r)) (cdr r))))

    (define (parse-bytevector str pos)
      ;; str[pos..pos+3] == "#u8("
      (let ((r (parse-list-items str (+ pos 4) #\))))
        (cons (list->bytevector (car r)) (cdr r))))

    (define (dot-marker? str pos)
      (and (char=? (string-ref str pos) #\.)
           (let ((r (raw-token-parser str pos)))
             (and r (= (cdr r) (+ pos 1))))))

    (define (read-dotted-tail str pos close)
      (let* ((after-dot (+ pos 1))
             (r (read-datum str after-dot)))
        (if (not r)
            (error "reader: expected a datum after ." pos)
            (let ((p2 (skip-atmosphere str (cdr r))))
              (if (or (>= p2 (string-length str)) (not (char=? (string-ref str p2) close)))
                  (error "reader: expected close paren after dotted tail" p2)
                  (cons (car r) (+ p2 1)))))))

    (define (parse-list-items str pos close)
      (let ((p (skip-atmosphere str pos)))
        (cond
          ((>= p (string-length str)) (error "reader: unterminated list" pos))
          ((char=? (string-ref str p) close) (cons '() (+ p 1)))
          ((dot-marker? str p) (read-dotted-tail str p close))
          (else
           (let ((r (read-datum str p)))
             (if (not r)
                 (error "reader: expected a datum in list" p)
                 (let ((rest (parse-list-items str (cdr r) close)))
                   (cons (cons (car r) (car rest)) (cdr rest)))))))))

    (define (parse-list str pos)
      ;; str[pos] is "(" or "["
      (let* ((open (string-ref str pos))
             (close (if (char=? open #\() #\) #\])))
        (parse-list-items str (+ pos 1) close)))

    (define (parse-quote-sugar str pos tag-name prefix-len)
      (let ((r (read-datum str (+ pos prefix-len))))
        (if (not r)
            (error "reader: expected a datum after quote sugar" pos)
            (cons (list (string->symbol tag-name) (car r)) (cdr r)))))

    (define (parse-hash str pos)
      (let ((len (string-length str)))
        (if (>= (+ pos 1) len)
            (error "reader: unexpected end of input after #" pos)
            (let ((c2 (string-ref str (+ pos 1))))
              (cond
                ((char=? c2 #\() (parse-vector str pos))
                ((and (char=? c2 #\u) (>= len (+ pos 4))
                      (char=? (string-ref str (+ pos 2)) #\8) (char=? (string-ref str (+ pos 3)) #\())
                 (parse-bytevector str pos))
                ((char=? c2 #\\) (parse-char-literal str pos))
                ((memv (char-downcase c2) (list #\t #\f)) (bool-literal-parser str pos))
                ((memv (char-downcase c2) (list #\e #\i #\b #\o #\d #\x)) (parse-prefixed-number str pos))
                ((char-numeric? c2) (parse-datum-label str pos))
                (else (error "reader: unknown # syntax" (substring str pos (min len (+ pos 2))))))))))

    ;; ---------------------------------------------------------------------
    ;; Datum labels (R7RS §2.4, #n=/#n#) -- a mutable alist (id . value),
    ;; reset once per TOP-LEVEL datum by read-toplevel-datum below (R7RS:
    ;; "a datum label's scope is only the outermost datum it appears in"),
    ;; NOT by read-datum itself (which also runs for every NESTED datum --
    ;; resetting there would lose a label defined while parsing an earlier
    ;; sibling/child of the same outermost datum). `assv` finds the FIRST
    ;; (most recently prepended) binding for a given id, so re-binding an
    ;; id (the def half, below) via a fresh cons onto the front correctly
    ;; shadows an earlier one with no need to remove it.
    ;;
    ;; Genuine cycles (`#0=(1 2 . #0#)`) need the same placeholder-then-
    ;; patch trick the native Crystal reader/icecreme's own loader.c use: the
    ;; def half allocates an empty (mutable) placeholder PAIR and binds
    ;; the label to THAT before recursing into the labeled datum's own
    ;; contents, so a `#0#` reached while still parsing those contents
    ;; (a real cycle) resolves to the placeholder's own identity; once
    ;; the labeled datum finishes parsing, set-car!/set-cdr! patch the
    ;; placeholder to match, and the placeholder itself (not the
    ;; freshly-consed value read-datum returned) is what gets returned
    ;; from and stays bound under this label -- so every occurrence of
    ;; `#0#` and the `#0=`-labeled position ITSELF all share one identity.
    ;; Only pairs get this treatment: a labeled non-pair datum (a bare
    ;; symbol/number/string/vector/...) can't participate in a genuine
    ;; CYCLE in the first place (nothing about it is self-referential),
    ;; so it's simply bound to its own already-computed value directly --
    ;; this does mean a self-referential VECTOR literal specifically
    ;; (`#0=#(#0#)`) isn't supported (no test in this project's own spec
    ;; suite exercises one), a deliberate, narrower scope cut mirroring
    ;; this file's other documented simplifications.
    (define current-datum-labels '())

    (define (digit-run-end str pos)
      (if (and (< pos (string-length str)) (char-numeric? (string-ref str pos)))
          (digit-run-end str (+ pos 1))
          pos))

    (define (parse-datum-label str pos)
      ;; str[pos] is #\#, str[pos+1] is a digit already confirmed by parse-hash
      (let* ((digits-start (+ pos 1))
             (digits-end (digit-run-end str digits-start))
             (id (string->number (substring str digits-start digits-end))))
        (if (>= digits-end (string-length str))
            (error "reader: malformed datum label (expected = or #)" pos)
            (let ((marker (string-ref str digits-end)))
              (cond
                ((char=? marker #\#)
                 (let ((entry (assv id current-datum-labels)))
                   (if (not entry) (error "reader: reference to undefined datum label" id))
                   (cons (cdr entry) (+ digits-end 1))))
                ((char=? marker #\=)
                 (let ((placeholder (cons '() '())))
                   (set! current-datum-labels (cons (cons id placeholder) current-datum-labels))
                   (let ((r (read-datum str (+ digits-end 1))))
                     (if (not r) (error "reader: expected a datum after datum label =" pos))
                     (let ((value (car r)))
                       (if (pair? value)
                           (begin
                             (set-car! placeholder (car value))
                             (set-cdr! placeholder (cdr value))
                             (cons placeholder (cdr r)))
                           (begin
                             (set! current-datum-labels (cons (cons id value) current-datum-labels))
                             (cons value (cdr r))))))))
                (else (error "reader: malformed datum label (expected = or #)" pos)))))))

    (define (read-datum str pos)
      (let ((p (skip-atmosphere str pos)))
        (if (>= p (string-length str))
            #f
            (let ((result
                    (let ((c (string-ref str p)))
                      (cond
                        ((or (char=? c #\() (char=? c #\[)) (parse-list str p))
                        ((char=? c #\") (string-literal-parser str p))
                        ((char=? c #\|) (piped-symbol-parser str p))
                        ((char=? c #\') (parse-quote-sugar str p "quote" 1))
                        ((char=? c #\`) (parse-quote-sugar str p "quasiquote" 1))
                        ((and (char=? c #\,) (< (+ p 1) (string-length str)) (char=? (string-ref str (+ p 1)) #\@))
                         (parse-quote-sugar str p "unquote-splicing" 2))
                        ((char=? c #\,) (parse-quote-sugar str p "unquote" 1))
                        ((char=? c #\#) (parse-hash str p))
                        (else (parse-token str p))))))
              ;; result is (value . end-offset), or #f. Record the source
              ;; position of any list form (pair value) at its start offset p.
              (if (and (pair? result) (pair? (car result)))
                  (record-form-position! (car result) p))
              result))))

    ;; Public entry point: reads every top-level datum in `str`, in order.
    ;; Resets current-datum-labels before each TOP-LEVEL datum only (see
    ;; that variable's own doc comment) -- every recursive/nested call
    ;; goes through plain read-datum, unchanged, so labels stay visible
    ;; across an entire outermost datum's own nested structure.
    (define (read-toplevel-datum str pos)
      (set! current-datum-labels '())
      (read-datum str pos))

    (define (read-program str)
      (set! current-line-starts (compute-line-starts str))
      (let ((len (string-length str)))
        (let loop ((pos 0) (acc '()))
          (let ((p (skip-atmosphere str pos)))
            (if (>= p len)
                (reverse acc)
                (let ((r (read-toplevel-datum str p)))
                  (if (not r)
                      (error "reader: failed to read a datum" p)
                      (loop (cdr r) (cons (car r) acc)))))))))))
