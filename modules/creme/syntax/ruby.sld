;; ===========================================================================
;; (creme syntax ruby): a minimal Ruby-flavored `#lang` dialect
;;
;; File-based (no FFI of its own — same rationale as modules/creme/
;; numfmt.sld's header comment). Built on `(creme lr)`, a from-scratch
;; SLR(1) parser generator (see that library's own header comment) --
;; unlike `(creme syntax scss)`/`(creme syntax slim)` (line/indentation-
;; shaped grammars, hand-written recursive descent), Ruby needs genuine
;; infix expression parsing with precedence, so this dialect defines its
;; whole grammar as `(creme lr)` rules instead. Operator precedence is
;; encoded structurally via layered nonterminals (or-expr > and-expr >
;; cmp-expr > add-expr > mul-expr > unary > postfix > primary) -- `(creme
;; lr)` itself has no precedence-declaration concept, by design (see its
;; own header comment).
;;
;; DELIBERATELY MINIMAL -- this is a real but small subset of Ruby, not a
;; second Ruby implementation:
;;   - def/end methods, if/elsif/else/end, unless/else/end, while/end,
;;     `name = expr` assignment (always becomes a Scheme `define` -- see
;;     LIMITATIONS below), no-paren and dotted method calls, do/end blocks
;;     with `|params|`, string interpolation, integer/float/string/symbol/
;;     array/nil/true/false literals, +-*/%  < > <= >= == != && || !
;;     operators.
;;   - NOT supported at all: classes, exceptions, case/when, multiple
;;     assignment, ranges, hashes, heredocs, `{ }` blocks (only do/end),
;;     string escapes beyond \n \t \" \\, comments other than `#` to end
;;     of line.
;;
;; LIMITATIONS worth knowing before relying on this -- several of these
;; trade away a capability specifically to keep the grammar genuinely
;; SLR(1) (see `(creme lr)`'s own header comment on why this dialect
;; doesn't just reach for a precedence table instead):
;;   - `nil` and `false` both compile to Scheme `#f` (there is no separate
;;     Ruby-nil value) -- this makes Ruby's own truthiness rule (only nil/
;;     false are falsy) fall out for free, since it's exactly Scheme's own
;;     #f-only-falsy rule, but it also means `nil == false` becomes
;;     indistinguishable after translation.
;;   - `name = expr` becomes `(define name expr)` the FIRST time `name` is
;;     assigned anywhere in the file, `(set! name expr)` every later time
;;     (reusing the same flat, file-scoped-not-method-scoped tracking as
;;     the bare-identifier rule below) -- needed for `while` loops driven
;;     by a counter (`i = i + 1`) to actually terminate rather than
;;     silently shadowing `i` with a fresh local every iteration. This is
;;     still not real per-method lexical scoping: two unrelated methods
;;     that happen to both assign a same-named local will incorrectly
;;     share one `define`/`set!` history across them.
;;   - A bare identifier with no block (`name`) is read as a variable
;;     reference if `name` was ever seen as a def/block parameter or an
;;     assignment target ANYWHERE EARLIER in the same file (tracked as one
;;     flat set, not per-method-scoped) -- otherwise it's a zero-arg call
;;     `(name)`. This is Ruby's own local-vs-method-call disambiguation
;;     rule, just flattened across the whole file instead of properly
;;     scoped per method.
;;   - `name(args)` (a call's own parens) requires the `(` to be
;;     IMMEDIATELY adjacent to `name`, no space -- same adjacency
;;     disambiguator `(creme syntax mex)` uses for its own `f(x)` sugar.
;;     `name (args)` (a space before the paren) instead parses as a
;;     no-paren call whose one argument happens to be parenthesized --
;;     these are two genuinely different grammar derivations for what
;;     would otherwise be identical token sequences, not just an SLR(1)
;;     limitation, so the lexer disambiguates them the same way real
;;     Ruby does (via whitespace) rather than picking one arbitrarily.
;;   - A no-paren call is its own STATEMENT (`puts n * 2` on its own line)
;;     -- it can't be nested inside a larger expression (`1 + puts x` is a
;;     parse error) and can't take a trailing block (`foo(a, b) do ... end`
;;     works; `foo a, b do ... end` does not). Nesting bare-args inside
;;     the general expression grammar made FOLLOW(bare-args) inherit every
;;     operator that can follow ANY expression (SLR tracks one FOLLOW set
;;     per nonterminal, not per calling context), which then collided with
;;     bare-args' own internal operators at parse-table-build time; a
;;     no-paren call used as a whole statement was the one capability this
;;     dialect actually needs, so it's carved out as its own production
;;     instead, sidestepping the cross-contamination entirely.
;;   - A no-paren call's arguments can't themselves start with unary `-`
;;     or `!` (`foo -1` is a parse error; write `foo(-1)`) or be ANOTHER
;;     no-paren call (`foo bar baz` -- write `foo(bar(baz))` instead) --
;;     both are genuinely context-sensitive in real Ruby (whitespace/
;;     lookahead-dependent), which a context-free SLR(1) grammar can't
;;     resolve; parenthesize instead.
;;   - `(dialect ruby)`'s `map`/`collect`/`select`/`reject`/`inject`/
;;     `reduce` take their proc/init BEFORE the receiver (`(select pred
;;     lst)`, not `(select lst pred)` -- see that library's own header
;;     comment on name collisions) -- unlike its receiver-first `each`/
;;     `times`/etc. This dialect has a small fixed table translating
;;     `arr.select { |x| ... }`-shaped calls into the right argument order
;;     for exactly those six methods; `inject`/`reduce` additionally
;;     require an explicit init argument (`arr.inject(0) { |a,x| ... }`) --
;;     Ruby's implicit-first-element-seed `inject` (no init arg at all) is
;;     not supported, since `(dialect ruby)`'s own `inject` requires one.
;;   - `def name(...) ... end` always requires the parens, even for a
;;     zero-parameter method (`def greet() ... end`, not `def greet ...
;;     end`) -- kept the def-stmt grammar simpler by not making them
;;     optional there too.
;;
;; A `#lang (creme syntax ruby)` file's whole content is one script, run
;; top-level (no `(export ...)`/`(params ...)` reusable-template mode, the
;; way `(creme syntax slim)` supports -- out of scope here). An optional
;; `(import lib-set ...)` header-arg adds extra libraries on top of the
;; always-available `(scheme base)`/`(scheme write)`/`(dialect ruby)`.
;; ===========================================================================

(define-library (creme syntax ruby)
  (export read-program)
  (import (scheme base) (scheme char) (scheme cxr) (scheme write) (creme lr) (creme hash-table) (dialect ruby))
  (begin
    ;; ------------------------------------------------------------------
    ;; lexer: src (a string) -> a list of (kind value line col) tokens.
    ;; Ruby's lexical grammar (no-paren calls, #{} interpolation, keyword-
    ;; delimited blocks) is too different from Scheme's own to reuse
    ;; (creme reader), same reasoning (creme syntax scss)/(creme syntax
    ;; slim) give for hand-writing their own.
    ;; ------------------------------------------------------------------

    (define (char-at src pos) (if (< pos (string-length src)) (string-ref src pos) #f))
    (define (ident-start-char? c) (or (char-alphabetic? c) (char=? c #\_)))
    (define (ident-char? c) (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

    (define keyword-table
      (list (cons "def" 'kw-def) (cons "end" 'kw-end) (cons "if" 'kw-if) (cons "elsif" 'kw-elsif)
            (cons "else" 'kw-else) (cons "unless" 'kw-unless) (cons "while" 'kw-while) (cons "do" 'kw-do)
            (cons "nil" 'kw-nil) (cons "true" 'kw-true) (cons "false" 'kw-false)))

    (define (skip-to-eol src pos)
      (let loop ((p pos))
        (if (or (not (char-at src p)) (char=? (char-at src p) #\newline)) p (loop (+ p 1)))))

    ;; A run of ident chars, plus one trailing "?" or "!" if present (Ruby's
    ;; own predicate/mutation naming convention -- needed to call
    ;; (dialect ruby)'s own empty?/zero?/has_key?/etc). Returns (cons
    ;; new-pos text).
    (define (scan-raw-ident-text src pos)
      (let loop ((p pos))
        (if (and (char-at src p) (ident-char? (char-at src p)))
            (loop (+ p 1))
            (let ((p2 (if (and (char-at src p) (memv (char-at src p) (list #\? #\!))) (+ p 1) p)))
              (cons p2 (substring src pos p2))))))

    (define (scan-ident-or-kw src pos line col)
      (let* ((r (scan-raw-ident-text src pos)) (p2 (car r)) (text (cdr r))
             (kw (assoc text keyword-table)))
        (list p2 (+ col (- p2 pos)) (if kw (list (cdr kw) #f line col) (list 'ident text line col)))))

    (define (scan-number src pos line col)
      (let loop ((p pos))
        (if (and (char-at src p) (char-numeric? (char-at src p)))
            (loop (+ p 1))
            (if (and (eqv? (char-at src p) #\.) (char-at src (+ p 1)) (char-numeric? (char-at src (+ p 1))))
                (let loop2 ((p2 (+ p 1)))
                  (if (and (char-at src p2) (char-numeric? (char-at src p2)))
                      (loop2 (+ p2 1))
                      (list p2 (+ col (- p2 pos)) (list 'float (string->number (substring src pos p2)) line col))))
                (list p (+ col (- p pos)) (list 'int (string->number (substring src pos p)) line col))))))

    (define (scan-operator src pos line col)
      (define (two c1 c2) (and (eqv? (char-at src pos) c1) (eqv? (char-at src (+ pos 1)) c2)))
      (cond
        ((two #\= #\=) (list (+ pos 2) (+ col 2) (list 'eqeq #f line col)))
        ((two #\! #\=) (list (+ pos 2) (+ col 2) (list 'noteq #f line col)))
        ((two #\< #\=) (list (+ pos 2) (+ col 2) (list 'le #f line col)))
        ((two #\> #\=) (list (+ pos 2) (+ col 2) (list 'ge #f line col)))
        ((two #\& #\&) (list (+ pos 2) (+ col 2) (list 'andand #f line col)))
        ((two #\| #\|) (list (+ pos 2) (+ col 2) (list 'oror #f line col)))
        (else
         (let* ((c (char-at src pos))
                (kind (cond
                        ((eqv? c #\() 'lparen) ((eqv? c #\)) 'rparen)
                        ((eqv? c #\[) 'lbracket) ((eqv? c #\]) 'rbracket)
                        ((eqv? c #\{) 'lbrace) ((eqv? c #\}) 'rbrace)
                        ((eqv? c #\,) 'comma) ((eqv? c #\.) 'dot)
                        ((eqv? c #\|) 'pipe) ((eqv? c #\=) 'assign)
                        ((eqv? c #\+) 'plus) ((eqv? c #\-) 'minus)
                        ((eqv? c #\*) 'star) ((eqv? c #\/) 'slash)
                        ((eqv? c #\%) 'percent) ((eqv? c #\<) 'lt) ((eqv? c #\>) 'gt)
                        ((eqv? c #\!) 'bang)
                        (else (error "ruby lex: unexpected character" c line col)))))
           (list (+ pos 1) (+ col 1) (list kind #f line col))))))

    ;; Scans one #{...} interpolation body (cursor right after the "{"),
    ;; tracking brace nesting so a nested `{`/`}` inside the expression
    ;; itself doesn't end the interpolation early (a `}` inside a NESTED
    ;; string literal within the interpolation is not specially handled --
    ;; a rare-enough case to accept as a limitation). Returns (list
    ;; new-pos new-line new-col inner-tokens); the extracted text is
    ;; re-lexed from scratch (its own line/col numbering, not the outer
    ;; file's), which is fine since error messages for interpolated
    ;; sub-expressions being approximate is an acceptable tradeoff here.
    (define (scan-interp src pos line col)
      (let loop ((p pos) (ln line) (cl col) (depth 1) (out (open-output-string)))
        (let ((c (char-at src p)))
          (cond
            ((not c) (error "ruby lex: unterminated interpolation" ln cl))
            ((and (char=? c #\}) (= depth 1))
             (list (+ p 1) ln (+ cl 1) (lex-tokens-inner (get-output-string out))))
            ((char=? c #\{) (write-char c out) (loop (+ p 1) ln (+ cl 1) (+ depth 1) out))
            ((char=? c #\}) (write-char c out) (loop (+ p 1) ln (+ cl 1) (- depth 1) out))
            ((char=? c #\newline) (write-char c out) (loop (+ p 1) (+ ln 1) 1 depth out))
            (else (write-char c out) (loop (+ p 1) ln (+ cl 1) depth out))))))

    ;; Scans a whole string literal (cursor right at the opening quote).
    ;; Returns (list new-pos new-line new-col tokens), tokens a
    ;; STRBEGIN ... STREND run with STRPART/INTERP-START-INTERP-END pieces
    ;; in between, in source order. Escapes: \n \t \" \\ ; anything else
    ;; after a backslash is passed through literally.
    (define (scan-string src pos line col)
      (let loop ((p (+ pos 1)) (ln line) (cl (+ col 1)) (buf (open-output-string))
                 (tokens (list (list 'strbegin #f line col))))
        (define (flush)
          (let ((text (get-output-string buf)))
            (if (> (string-length text) 0) (append tokens (list (list 'strpart text ln cl))) tokens)))
        (let ((c (char-at src p)))
          (cond
            ((not c) (error "ruby lex: unterminated string" ln cl))
            ((char=? c #\")
             (list (+ p 1) ln (+ cl 1) (append (flush) (list (list 'strend #f ln cl)))))
            ((and (char=? c #\#) (eqv? (char-at src (+ p 1)) #\{))
             (let* ((tokens1 (flush))
                    (inner (scan-interp src (+ p 2) ln (+ cl 2))))
               (loop (car inner) (cadr inner) (caddr inner) (open-output-string)
                     (append tokens1 (list (list 'interp-start #f ln cl))
                             (cadddr inner)
                             (list (list 'interp-end #f (cadr inner) (caddr inner)))))))
            ((char=? c #\\)
             (let* ((esc (char-at src (+ p 1)))
                    (actual (cond ((eqv? esc #\n) #\newline) ((eqv? esc #\t) #\tab) (else esc))))
               (write-char actual buf)
               (loop (+ p 2) ln (+ cl 2) buf tokens)))
            ((char=? c #\newline) (write-char c buf) (loop (+ p 1) (+ ln 1) 1 buf tokens))
            (else (write-char c buf) (loop (+ p 1) ln (+ cl 1) buf tokens))))))

    ;; Main driving loop: acc is the token list so far (source order).
    ;; last-kind is the previous token's own kind (or #f before the first
    ;; one) -- used to suppress a leading newline and to collapse a blank
    ;; line's run of newlines down to none. depth counts open (/[/{ so
    ;; newlines inside them (multi-line parenthesized args) aren't
    ;; statement separators. Returns (cons last-kind acc) so the trailing-
    ;; newline finalize step (ruby-lex, not used by interpolation's own
    ;; recursive lex) knows whether one is still needed.
    (define (lex-loop src pos line col depth last-kind acc)
      (let ((c (char-at src pos)))
        (cond
          ((not c) (cons last-kind acc))
          ((char=? c #\newline)
           (let ((emit? (and (= depth 0) last-kind (not (eq? last-kind 'newline)))))
             (lex-loop src (+ pos 1) (+ line 1) 1 depth (if emit? 'newline last-kind)
                       (if emit? (append acc (list (list 'newline #f line col))) acc))))
          ((or (char=? c #\space) (char=? c #\tab) (char=? c #\return))
           (lex-loop src (+ pos 1) line (+ col 1) depth last-kind acc))
          ((char=? c #\#) (lex-loop src (skip-to-eol src pos) line col depth last-kind acc))
          ((char=? c #\")
           (let ((r (scan-string src pos line col)))
             (lex-loop src (car r) (cadr r) (caddr r) depth 'strend (append acc (cadddr r)))))
          ((and (char=? c #\:) (char-at src (+ pos 1)) (ident-start-char? (char-at src (+ pos 1))))
           (let* ((r (scan-raw-ident-text src (+ pos 1))) (p2 (car r)) (name (cdr r)))
             (lex-loop src p2 line (+ col (- p2 (+ pos 1)) 1) depth 'symlit
                       (append acc (list (list 'symlit name line col))))))
          ((char-numeric? c)
           (let ((r (scan-number src pos line col)))
             (lex-loop src (car r) line (cadr r) depth (car (caddr r)) (append acc (list (caddr r))))))
          ((ident-start-char? c)
           (let ((r (scan-ident-or-kw src pos line col)))
             (lex-loop src (car r) line (cadr r) depth (car (caddr r)) (append acc (list (caddr r))))))
          ;; A "(" immediately adjacent (no space) to a preceding
          ;; identifier is a CALL's own arg-parens (lparen-call, a
          ;; distinct terminal from plain lparen) -- same adjacency
          ;; disambiguator (creme syntax mex) uses for its own f(x) sugar.
          ;; Without this distinction, `greet(name)` (explicit call args)
          ;; and `greet (name)` (a bare no-paren call whose one argument
          ;; happens to be a parenthesized expression) become the SAME
          ;; grammar derivation reachable two ways, which is a genuine
          ;; ambiguity, not just an SLR limitation -- see this file's own
          ;; header comment (LIMITATIONS).
          ((and (char=? c #\() (eq? last-kind 'ident) (> pos 0)
                (let ((p (char-at src (- pos 1)))) (and p (or (ident-char? p) (memv p (list #\? #\!))))))
           (lex-loop src (+ pos 1) line (+ col 1) (+ depth 1) 'lparen-call (append acc (list (list 'lparen-call #f line col)))))
          (else
           (let* ((r (scan-operator src pos line col)) (tok (caddr r)) (kind (car tok)))
             (lex-loop src (car r) line (cadr r)
                       (cond ((memq kind (list 'lparen 'lbracket 'lbrace)) (+ depth 1))
                             ((memq kind (list 'rparen 'rbracket 'rbrace)) (- depth 1))
                             (else depth))
                       kind (append acc (list tok))))))))

    ;; Used by scan-interp to lex an extracted #{...} body -- no trailing
    ;; synthetic newline (it's an expression, not a whole statement list).
    (define (lex-tokens-inner s) (cdr (lex-loop s 0 1 1 0 #f '())))

    ;; (ruby-lex src) -> the full token list for a whole file/program,
    ;; guaranteed to end with a NEWLINE token (synthesized if the source's
    ;; own last line didn't have one) so every statement-level grammar
    ;; rule's own trailing NEWLINE -- including the very last statement in
    ;; the file -- always has one to consume.
    (define (ruby-lex src)
      (let* ((r (lex-loop src 0 1 1 0 #f '())) (last-kind (car r)) (toks (cdr r)))
        (if (and (not (null? toks)) (not (eq? last-kind 'newline)))
            (append toks (list (list 'newline #f 0 0)))
            toks)))

    ;; ------------------------------------------------------------------
    ;; known-locals: a flat, file-scoped (not per-method) set of names
    ;; ever seen as a def/block parameter or an assignment target -- see
    ;; this file's own header comment (LIMITATIONS) for why this isn't
    ;; properly lexically scoped. Reset once per read-program call (`set!`
    ;; on this top-level binding, not a fresh table threaded through every
    ;; action -- the grammar/actions are built ONCE at library-load time,
    ;; so this is the only way each read-program call gets a clean slate).
    ;; ------------------------------------------------------------------

    (define known-locals (make-hash-table))
    (define (reset-known-locals!) (set! known-locals (make-hash-table)))
    (define (mark-local! name) (hash-table-set! known-locals name #t))
    (define (known-local? name) (hash-table-contains? known-locals name))

    ;; ------------------------------------------------------------------
    ;; translation helpers
    ;; ------------------------------------------------------------------

    ;; (dialect ruby)'s own proc-first exceptions to its usual receiver-
    ;; first convention -- see this file's own header comment.
    (define proc-first-methods (list "map" "collect" "select" "reject"))
    (define init-methods (list "inject" "reduce"))

    ;; Builds the Scheme call form for one method-call-shaped postfix node.
    ;; recv is #f for a bare (non-dotted) call. block, if present, is
    ;; already a `(do (param ...) body ...)` form (see the `block`
    ;; production below) -- (dialect ruby)'s own `do` macro, which
    ;; evaluates standalone to a lambda, so this composes with any callee.
    (define (build-call name-str recv args block)
      (let ((sym (string->symbol name-str)))
        (cond
          ((not recv) (append (list sym) args (if block (list block) (list))))
          ((member name-str proc-first-methods)
           (let ((proc (cond (block block) ((pair? args) (car args))
                              (else (error "ruby dialect: missing block/proc for" name-str)))))
             (list sym proc recv)))
          ((member name-str init-methods)
           (if (or (not block) (null? args))
               (error "ruby dialect: inject/reduce require an explicit init argument and a block, e.g. arr.inject(0) { |a,x| ... }" name-str)
               (list sym block (car args) recv)))
          (else (append (list sym recv) args (if block (list block) (list)))))))

    (define (postfix-ident-call name block)
      (cond
        (block (build-call name #f (list) block))
        ((known-local? name) (string->symbol name))
        (else (build-call name #f (list) #f))))

    ;; A string literal's parts (already parsed into (cons 'lit text) /
    ;; (cons 'interp expr-form) pairs) -> a single Scheme expression. A
    ;; plain (no-interpolation) string collapses to just the literal
    ;; string itself rather than a needless one-argument string-append.
    (define (build-string-lit parts)
      (if (and (= (length parts) 1) (eq? (car (car parts)) 'lit))
          (cdr (car parts))
          (cons 'string-append
                (map (lambda (p) (if (eq? (car p) 'lit) (cdr p) (list 'to_s (cdr p)))) parts))))

    ;; ------------------------------------------------------------------
    ;; grammar
    ;; ------------------------------------------------------------------

    (define rb-grammar
      (make-grammar 'program
        (list
         (make-rule 'program (list 'stmts) (lambda (v) v))

         (make-rule 'stmts (list 'stmts 'stmt) (lambda (prior s) (append prior (list s))))
         (make-rule 'stmts (list 'stmt) (lambda (s) (list s)))

         (make-rule 'stmt (list 'def-stmt) (lambda (v) v))
         (make-rule 'stmt (list 'if-stmt) (lambda (v) v))
         (make-rule 'stmt (list 'unless-stmt) (lambda (v) v))
         (make-rule 'stmt (list 'while-stmt) (lambda (v) v))
         (make-rule 'stmt (list 'assign-stmt) (lambda (v) v))
         (make-rule 'stmt (list 'bare-call-stmt) (lambda (v) v))
         (make-rule 'stmt (list 'expr-stmt) (lambda (v) v))

         (make-rule 'expr-stmt (list 'expr 'newline) (lambda (e nl) e))

         (make-rule 'assign-stmt (list 'ident 'assign 'expr 'newline)
                    (lambda (name eq e nl)
                      (let ((already-local (known-local? name)))
                        (mark-local! name)
                        (list (if already-local 'set! 'define) (string->symbol name) e))))

         (make-rule 'def-stmt (list 'kw-def 'ident 'lparen-call 'param-list-opt 'rparen 'newline 'stmts 'kw-end 'newline)
                    (lambda (kwdef name lp params rp nl body kwend nl2)
                      (cons 'define (cons (cons (string->symbol name) params) body))))

         (make-rule 'param-list-opt (list 'param-list) (lambda (v) v))
         (make-rule 'param-list-opt (list) (lambda () (list)))
         (make-rule 'param-list (list 'param-list 'comma 'ident)
                    (lambda (prior comma id) (mark-local! id) (append prior (list (string->symbol id)))))
         (make-rule 'param-list (list 'ident) (lambda (id) (mark-local! id) (list (string->symbol id))))

         (make-rule 'if-stmt (list 'kw-if 'expr 'newline 'stmts 'elsifs 'opt-else 'kw-end 'newline)
                    (lambda (kwif cond1 nl body elsifs else-body kwend nl2)
                      (cons 'cond (append (list (cons cond1 body)) elsifs
                                          (if else-body (list (cons 'else else-body)) (list))))))
         (make-rule 'elsifs (list 'elsifs 'kw-elsif 'expr 'newline 'stmts)
                    (lambda (prior kw cond1 nl body) (append prior (list (cons cond1 body)))))
         (make-rule 'elsifs (list) (lambda () (list)))
         (make-rule 'opt-else (list 'kw-else 'newline 'stmts) (lambda (kw nl body) body))
         (make-rule 'opt-else (list) (lambda () #f))

         (make-rule 'unless-stmt (list 'kw-unless 'expr 'newline 'stmts 'opt-else 'kw-end 'newline)
                    (lambda (kw cond1 nl body else-body kwend nl2)
                      (cons 'cond (append (list (cons (list 'not cond1) body))
                                          (if else-body (list (cons 'else else-body)) (list))))))

         (make-rule 'while-stmt (list 'kw-while 'expr 'newline 'stmts 'kw-end 'newline)
                    (lambda (kw cond1 nl body kwend nl2)
                      (list 'let 'ruby-while-loop (list)
                            (cons 'when (cons cond1 (append body (list (list 'ruby-while-loop))))))))

         (make-rule 'expr (list 'or-expr) (lambda (v) v))
         (make-rule 'or-expr (list 'or-expr 'oror 'and-expr) (lambda (a op b) (list 'or a b)))
         (make-rule 'or-expr (list 'and-expr) (lambda (v) v))
         (make-rule 'and-expr (list 'and-expr 'andand 'cmp-expr) (lambda (a op b) (list 'and a b)))
         (make-rule 'and-expr (list 'cmp-expr) (lambda (v) v))
         (make-rule 'cmp-expr (list 'cmp-expr 'lt 'add-expr) (lambda (a op b) (list '< a b)))
         (make-rule 'cmp-expr (list 'cmp-expr 'gt 'add-expr) (lambda (a op b) (list '> a b)))
         (make-rule 'cmp-expr (list 'cmp-expr 'le 'add-expr) (lambda (a op b) (list '<= a b)))
         (make-rule 'cmp-expr (list 'cmp-expr 'ge 'add-expr) (lambda (a op b) (list '>= a b)))
         (make-rule 'cmp-expr (list 'cmp-expr 'eqeq 'add-expr) (lambda (a op b) (list 'equal? a b)))
         (make-rule 'cmp-expr (list 'cmp-expr 'noteq 'add-expr) (lambda (a op b) (list 'not (list 'equal? a b))))
         (make-rule 'cmp-expr (list 'add-expr) (lambda (v) v))
         (make-rule 'add-expr (list 'add-expr 'plus 'mul-expr) (lambda (a op b) (list '+ a b)))
         (make-rule 'add-expr (list 'add-expr 'minus 'mul-expr) (lambda (a op b) (list '- a b)))
         (make-rule 'add-expr (list 'mul-expr) (lambda (v) v))
         (make-rule 'mul-expr (list 'mul-expr 'star 'unary) (lambda (a op b) (list '* a b)))
         (make-rule 'mul-expr (list 'mul-expr 'slash 'unary) (lambda (a op b) (list '/ a b)))
         (make-rule 'mul-expr (list 'mul-expr 'percent 'unary) (lambda (a op b) (list 'modulo a b)))
         (make-rule 'mul-expr (list 'unary) (lambda (v) v))
         (make-rule 'unary (list 'bang 'unary) (lambda (op v) (list 'not v)))
         (make-rule 'unary (list 'minus 'unary) (lambda (op v) (list '- v)))
         (make-rule 'unary (list 'postfix) (lambda (v) v))

         ;; A restricted mirror of add-expr/mul-expr, bottoming out at the
         ;; ordinary `postfix` (safe now -- see bare-call-stmt below for
         ;; why bare-args itself is no longer reachable FROM postfix at
         ;; all, which is what makes this safe). Used only for a no-paren
         ;; call's arguments -- see this file's own header comment
         ;; (LIMITATIONS) on why a leading unary -/! there is genuinely
         ;; ambiguous in a context-free grammar (competes with reading the
         ;; identifier as a zero-arg call followed by a binary `-`) and is
         ;; excluded rather than guessed at.
         (make-rule 'arg-add (list 'arg-add 'plus 'arg-mul) (lambda (a op b) (list '+ a b)))
         (make-rule 'arg-add (list 'arg-add 'minus 'arg-mul) (lambda (a op b) (list '- a b)))
         (make-rule 'arg-add (list 'arg-mul) (lambda (v) v))
         (make-rule 'arg-mul (list 'arg-mul 'star 'arg-unary) (lambda (a op b) (list '* a b)))
         (make-rule 'arg-mul (list 'arg-mul 'slash 'arg-unary) (lambda (a op b) (list '/ a b)))
         (make-rule 'arg-mul (list 'arg-mul 'percent 'arg-unary) (lambda (a op b) (list 'modulo a b)))
         (make-rule 'arg-mul (list 'arg-unary) (lambda (v) v))
         ;; arg-unary deliberately excludes unary's own leading -/! bang
         ;; alternatives (bottoms straight out at `postfix`, safe now that
         ;; bare-args is no longer reachable FROM postfix at all -- see
         ;; bare-call-stmt above) -- otherwise the very first token of a
         ;; no-paren call's argument list could ALSO shift a leading unary
         ;; minus/bang, which conflicts with reducing the identifier
         ;; itself to a plain zero-arg call/reference (`foo - 1`, binary
         ;; subtraction) right at the same state -- see this file's own
         ;; header comment (LIMITATIONS).
         (make-rule 'arg-unary (list 'postfix) (lambda (v) v))

         (make-rule 'postfix (list 'primary) (lambda (v) v))
         (make-rule 'postfix (list 'ident 'block-opt) (lambda (name block) (postfix-ident-call name block)))
         (make-rule 'postfix (list 'ident 'lparen-call 'arg-list-opt 'rparen 'block-opt)
                    (lambda (name lp args rp block) (build-call name #f args block)))
         (make-rule 'postfix (list 'postfix 'dot 'ident 'block-opt)
                    (lambda (recv dot name block) (build-call name recv (list) block)))
         (make-rule 'postfix (list 'postfix 'dot 'ident 'lparen-call 'arg-list-opt 'rparen 'block-opt)
                    (lambda (recv dot name lp args rp block) (build-call name recv args block)))

         (make-rule 'primary (list 'int) (lambda (v) v))
         (make-rule 'primary (list 'float) (lambda (v) v))
         (make-rule 'primary (list 'string-lit) (lambda (v) v))
         (make-rule 'primary (list 'symlit) (lambda (name) (list 'quote (string->symbol name))))
         (make-rule 'primary (list 'kw-nil) (lambda (kw) #f))
         (make-rule 'primary (list 'kw-true) (lambda (kw) #t))
         (make-rule 'primary (list 'kw-false) (lambda (kw) #f))
         (make-rule 'primary (list 'lbracket 'expr-list-opt 'rbracket) (lambda (lb elems rb) (cons 'list elems)))
         (make-rule 'primary (list 'lparen 'expr 'rparen) (lambda (lp e rp) e))

         (make-rule 'arg-list-opt (list 'arg-list) (lambda (v) v))
         (make-rule 'arg-list-opt (list) (lambda () (list)))
         (make-rule 'arg-list (list 'arg-list 'comma 'expr) (lambda (prior comma e) (append prior (list e))))
         (make-rule 'arg-list (list 'expr) (lambda (e) (list e)))

         ;; bare-args-rest's own later elements are ALSO restricted to
         ;; arg-add (not full expr) -- not because of the leading-unary
         ;; ambiguity (only the very first token after a bare call's name
         ;; is genuinely ambiguous), but because full `expr` reaches
         ;; or-expr's own left-recursive "or-expr OROR and-expr" rule,
         ;; whose FOLLOW(or-expr) legitimately includes OROR -- and since
         ;; that same `expr` nonterminal is what feeds bare-args-rest's
         ;; FOLLOW set back into FOLLOW(expr) itself (via "bare-args-rest
         ;; -> bare-args-rest COMMA expr", expr as the last symbol), SLR's
         ;; single GLOBAL per-nonterminal FOLLOW set (as opposed to
         ;; LALR(1)/canonical LR(1)'s per-state lookahead) ends up
         ;; over-broadening FOLLOW(expr) to also include OROR, which then
         ;; conflicts with "expr -> or-expr"'s own reduce action wherever
         ;; that state also has a legitimate or-expr-extending shift on
         ;; OROR. Capping bare-args-rest's elements at arg-add (which
         ;; never reaches or-expr/and-expr at all) breaks that feedback
         ;; loop -- at the cost of a further restriction: a later
         ;; no-paren argument can't itself be an unparenthesized
         ;; &&/||/comparison either (parenthesize it instead).
         (make-rule 'bare-args (list 'arg-add 'bare-args-rest) (lambda (first rest) (cons first rest)))
         (make-rule 'bare-args-rest (list 'bare-args-rest 'comma 'arg-add)
                    (lambda (prior comma e) (append prior (list e))))
         (make-rule 'bare-args-rest (list) (lambda () (list)))

         ;; A no-paren call is its OWN statement-level production -- NOT
         ;; one of postfix's own alternatives -- specifically so bare-args
         ;; is always followed by a concrete NEWLINE terminal, never by
         ;; "whatever can follow a full expression" (which, transitively,
         ;; is every binary operator in the whole precedence chain, since
         ;; that's exactly what FOLLOW(postfix) contains). Nesting
         ;; bare-args inside postfix made FOLLOW(bare-args) inherit that
         ;; full richness, which then leaked into arg-add/arg-mul's own
         ;; FOLLOW set (via the nullable bare-args-rest tail) and
         ;; conflicted with their own legitimate shift actions for the
         ;; very same operators -- a no-paren call nested inside a larger
         ;; expression (`1 + puts x`) was never a needed capability, so
         ;; this restriction costs nothing this dialect actually uses.
         (make-rule 'bare-call-stmt (list 'ident 'bare-args 'newline)
                    (lambda (name args nl) (build-call name #f args #f)))

         (make-rule 'expr-list-opt (list 'expr-list) (lambda (v) v))
         (make-rule 'expr-list-opt (list) (lambda () (list)))
         (make-rule 'expr-list (list 'expr-list 'comma 'expr) (lambda (prior comma e) (append prior (list e))))
         (make-rule 'expr-list (list 'expr) (lambda (e) (list e)))

         ;; Zero-or-more via left-recursion + an empty base case ONLY --
         ;; deliberately no separate "string-parts -> string-part" rule,
         ;; which would make a single part reachable two ways (directly,
         ;; or via the empty case then one extension) -- a genuine
         ;; ambiguity, not just an SLR limitation.
         (make-rule 'string-lit (list 'strbegin 'string-parts 'strend) (lambda (b parts e) (build-string-lit parts)))
         (make-rule 'string-parts (list 'string-parts 'string-part) (lambda (prior p) (append prior (list p))))
         (make-rule 'string-parts (list) (lambda () (list)))
         (make-rule 'string-part (list 'strpart) (lambda (text) (cons 'lit text)))
         (make-rule 'string-part (list 'interp-start 'expr 'interp-end) (lambda (s e1 e2) (cons 'interp e1)))

         ;; `{ |x| expr }` brace-blocks are NOT supported, only `do |x| ...
         ;; end` -- see this file's own header comment (LIMITATIONS).
         ;; Embedding `expr` directly inside `block` (needed for a brace-
         ;; block's single-expression body) reintroduced the same kind of
         ;; FOLLOW-set cross-contamination documented above for bare-args,
         ;; and do/end blocks (which use `stmts`, not `expr`, for their
         ;; body) already cover this dialect's one required use case.
         (make-rule 'block-opt (list 'block) (lambda (v) v))
         (make-rule 'block-opt (list) (lambda () #f))
         (make-rule 'block (list 'kw-do 'pipe 'param-list-opt 'pipe 'newline 'stmts 'kw-end)
                    (lambda (kwdo p1 params p2 nl body kwend) (cons 'do (cons params body)))))))

    (define rb-parser-table (build-parser rb-grammar))

    ;; The #lang contract (see src/creme/runner.cr): src is everything in
    ;; the file after the `#lang` line; the result is a proper list of
    ;; ordinary forms, ready for the analyzer/compiler/VM exactly as if
    ;; the plain Reader had produced them. header-args' optional `(import
    ;; lib-set ...)` entry adds extra libraries alongside the always-
    ;; available ones.
    (define (read-program src source-name header-args)
      (reset-known-locals!)
      (let* ((tokens (ruby-lex src))
             (forms (lr-parse rb-parser-table tokens car cadr))
             (import-form (assq 'import header-args))
             (extra-imports (if import-form (cdr import-form) (list))))
        (cons (cons 'import (cons '(scheme base) (cons '(scheme write) (cons '(dialect ruby) extra-imports))))
              forms)))))
