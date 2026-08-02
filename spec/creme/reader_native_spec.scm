;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/modules/creme/reader_spec.cr's
;; own cases exercising (creme reader) directly -- see modules/creme/
;; spec.sld's own header comment for the framework this uses. NOT to be
;; confused with reader_literals_spec.scm, which ports a DIFFERENT file
;; (modules/creme/compiler/reader_spec.cr, the SELF-HOSTED reader's own
;; literal-classification tests) -- this one is about (creme reader)'s
;; lex-tokens/tokens->forms hook, exposing the real Lexer/Reader to Scheme
;; as a token stream (see src/creme/modules/creme/reader.cr's own header
;; comment: built so a `#lang` dialect's own parser can be written in
;; Scheme, rewriting the token list before handing it back to the
;; ordinary Reader).
;;
;; NOT runnable under icecreme/icecreme, structurally, not as a bug to fix: `(creme
;; reader)`'s lex-tokens/tokens->forms are native-Crystal-only (src/creme/
;; modules/creme/reader.cr) -- no pure-Scheme .sld fallback and no icecreme C
;; equivalent at all (unlike (creme bytecode)/(creme compiler compiler),
;; which icecreme's self-hosted loader can read straight off disk). Under
;; icecreme/icecreme, `lex-tokens` would simply be an unbound variable, aborting the
;; whole compile the same way compiler_numeric_tower_spec.scm used to
;; before rational/complex support existed -- except there's no realistic
;; fix here, since this is exposing native Crystal's own lexer/reader
;; internals, not a Scheme-expressible algorithm icecreme could reimplement.
;; Excluded from the Makefile's creme-spec-icecreme target's own sweep for
;; exactly this reason (see that target's own comment).
;;
;; Run with:
;;   ./bin/creme spec/creme/reader_native_spec.scm               (all 4 pass)
;;   ./bin/creme --self-hosted spec/creme/reader_native_spec.scm  (all 4 pass)
;; (not ./icecreme/icecreme -- see this file's own header comment above for why.)
;; ===========================================================================

(import (scheme base) (scheme write) (scheme read) (scheme process-context)
        (creme reader) (creme spec))

(define (write-to-string v)
  (let ((port (open-output-string)))
    (write v port)
    (get-output-string port)))

;; The "ordinary, unmodified reader" side of the comparison -- (creme
;; reader)'s own contract is that tokens->forms, fed lex-tokens' own
;; output back unchanged, must parse identically to a plain read loop.
(define (read-all-plain src)
  (let ((in (open-input-string src)))
    (let loop ((acc '()))
      (let ((form (read in)))
        (if (eof-object? form)
            (reverse acc)
            (loop (cons form acc)))))))

(describe "(creme reader)"
  (it "round-trips ordinary forms through lex-tokens + tokens->forms unchanged"
    (for-each
      (lambda (src)
        (should-equal?
          (map write-to-string (tokens->forms (lex-tokens src "t") "t"))
          (map write-to-string (read-all-plain src))))
      (list "(f x y)" "(define (add x y) (+ x y))" "'(1 2 3)" "\"a string\" 42 3.5")))

  (it "lex-tokens includes a trailing eof token"
    (should-equal? (write-to-string (lex-tokens "x" "t")) "((symbol \"x\" 1 1) (eof \"\" 1 2))"))

  (it "tokens->forms rejects a malformed token"
    (should-raise? (lambda () (tokens->forms (list (list 'symbol "x")) "t"))))

  (it "tokens->forms rejects an unknown token kind"
    (should-raise? (lambda () (tokens->forms (list (list 'bogus "x" 1 1)) "t")))))

(spec-summary!)
