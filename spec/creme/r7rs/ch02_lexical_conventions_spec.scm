;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch02_lexical_conventions_
;; spec.cr's own cases -- see modules/creme/spec.sld's own header comment
;; for the framework this uses, and spec/creme/r7rs/ch06_13_input_output_
;; spec.scm's own header comment for this project's existing precedent of
;; testing reader/port behavior directly (no string-embedding-and-sub-eval
;; needed, since this file already runs in a real Scheme runtime).
;;
;; Most cases below exercise identifier/comment/boolean syntax that this
;; SPEC FILE'S OWN source text already contains literally (e.g. a `let`
;; binding named `|two words|`, or a real `; ...` line comment) -- since
;; the whole file is parsed by the very same reader under test, that's
;; already a faithful exercise of the reader, not a shortcut around it.
;; Where the original Crystal case's whole point was to test how a
;; specific piece of RAW TEXT reads as data (rather than just how it reads
;; as code) -- the #; / #| |# comment cases and the #n=/#n# datum-label
;; cases -- (scheme read)'s `read` on an `(open-input-string ...)` is used
;; instead, exactly mirroring the original's own `(import (scheme read))
;; (read (open-input-string ...))` approach.
;;
;; Skipped from the original file (matching its own `pending`): "#!fold-
;; case / #!no-fold-case directives are not implemented (reader raises
;; 'unknown # syntax')" -- nothing to assert against here either, same
;; reason the original left it a no-op pending.
;;
;; §2.4 Datum labels (#n=/#n#) USED to be a genuine icecreme reader gap --
;; icecreme's own `read` is backed by the self-hosted reader
;; (modules/creme/compiler/reader.sld), which used to raise "unknown #
;; syntax #0" on `#0=...`/`#0#` at all (a documented, deliberate scope
;; cut in that file's own header comment). Now supported there
;; (parse-datum-label) -- pairs, including genuine cycles, preserving
;; real eq? identity; a labeled non-pair datum is just bound to its own
;; value directly (can't participate in a cycle anyway); only a
;; self-referential VECTOR specifically remains unsupported (no test
;; here or elsewhere needs one) -- so every case runs unconditionally
;; now. Separately, icecreme's OWN --emit-icecreme + icecreme/icecreme precompiled pipeline
;; (a different code path from this file's `read`-based cases, native
;; Crystal's reader/serializer + icecreme/loader.c) has its own, independent
;; #n=/#n# support -- see icecreme/README.md's own "Datum labels" section.
;;
;; Run with (all cases pass, 0 pending, under all three):
;;   ./bin/creme spec/creme/r7rs/ch02_lexical_conventions_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch02_lexical_conventions_spec.scm
;;   ./icecreme/icecreme spec/creme/r7rs/ch02_lexical_conventions_spec.scm
;; ===========================================================================

(import (scheme base) (scheme read) (creme spec))

(describe "R7RS §2.1 Identifiers"
  (it "accepts the extended identifier characters ! $ % & * + - . / : < = > ? @ ^ _ ~"
    (should-equal? (let ((->string 1)) ->string) 1)
    (should-equal? (let ((+soup+ 2)) +soup+) 2)
    (should-equal? (let ((list->vector 3)) list->vector) 3)
    (should-equal? (let ((the-word-recursion-has-many-meanings 4)) the-word-recursion-has-many-meanings) 4))

  (it "a delimited + or - by itself is an identifier (bound to the addition/subtraction procedure in the base library)"
    (should-be-true? (procedure? +)))

  (it "|...| vertical-line identifiers can contain arbitrary characters, including whitespace"
    (should-equal? (let ((|two words| 5)) |two words|) 5))

  (it "|H\\x65;llo| denotes the same identifier as Hello (hex-escape inside a |...| identifier)"
    (should-be-true? (eqv? 'Hello '|H\x65;llo|))
    (should-equal? (let ((Hello 6)) |H\x65;llo|) 6)))

(describe "R7RS §2.2 Whitespace and comments"
  (it "; starts a line comment extending to end of line"
    (should-equal? (+ 1 2) ; this is a comment
                   3))

  (it "#; is a datum comment, skipping exactly one following datum"
    (should-equal? (read (open-input-string "(+ 1 #;(this is ignored) 2)")) (list '+ 1 2)))

  (it "#| ... |# is a nestable block comment"
    (should-equal? (read (open-input-string "#| outer #| inner |# still outer |# (+ 1 2)")) (list '+ 1 2))))

(describe "R7RS §2.3 Other notations"
  (it "#t and #true both denote the boolean true"
    (should-be-true? #t)
    (should-be-true? #true)
    (should-be-true? (eqv? #t #true)))

  (it "#f and #false both denote the boolean false"
    (should-be-false? #f)
    (should-be-false? #false)
    (should-be-true? (eqv? #f #false)))

  (it "parentheses group and notate lists; apostrophe indicates literal data"
    (should-equal? '(+ 1 2) (list '+ 1 2))))

(describe "R7RS §2.4 Datum labels"
  (it "#n=datum labels a datum, and #n# elsewhere in the same outermost datum refers back to it, preserving identity"
    (let ((x (read (open-input-string "(#0=(a b c) #0#)"))))
      (should-be-true? (eq? (car x) (car (cdr x))))))

  (it "supports genuinely circular structure, e.g. #0=(1 2 . #0#)"
    (let ((x (read (open-input-string "#0=(1 2 . #0#)"))))
      (should-equal? (car x) 1)
      (should-equal? (car (cdr x)) 2)
      (should-be-true? (eq? x (cdr (cdr x))))))

  (it "a datum label's scope is only the outermost datum it appears in -- reusing the same label number in a later top-level form is not an error"
    (let ((p (open-input-string "#0=a #0=b")))
      (should-equal? (list (read p) (read p)) (list 'a 'b)))))

(spec-summary!)
