;; ===========================================================================
;; A (creme spec)-based port of (creme repl)'s process-key cursor-movement
;; cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses.
;;
;; process-key is a pure function (lines/row/col in, an (edit ...) result
;; out) exported from (creme repl) purely for this kind of direct testing --
;; see repl.sld's own export comment -- so these cases drive it with
;; hand-built key alists (matching the ((kind . "...")) shape (creme
;; term)'s term-read-key already produces) instead of a real terminal.
;; Deliberately does NOT cover (creme term)'s own key-parsing (which byte
;; sequence produces which kind) -- that's spec/scheme/modules/creme/
;; term_spec.cr's job, against the native Crystal build specifically, since
;; word-nav's raw-terminal reading is duplicated by hand between term.cr and
;; icecreme/term.c (see that file's own header comment) rather than shared code.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/repl_spec.scm
;;   ./bin/creme --self-hosted spec/creme/repl_spec.scm
;;   ./icecreme/icecreme spec/creme/repl_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (creme repl) (creme spec))

(define (key kind) (list (cons 'kind kind)))

;; process-key returns (edit new-lines new-row new-col new-menu); these
;; cases only ever produce an 'edit result with no menu, so pull out just
;; the row/col to compare against.
(define (edit-row+col result) (list (list-ref result 2) (list-ref result 3)))

(describe "(creme repl) process-key: cursor movement"
  (it "ctrl-a moves to column 0, same as home"
    (should-equal? (edit-row+col (process-key (key "ctrl-a") '("hello world") 0 7 2 #f))
                    '(0 0)))

  (it "ctrl-e moves to end of line, same as end"
    (should-equal? (edit-row+col (process-key (key "ctrl-e") '("hello world") 0 3 2 #f))
                    '(0 11)))

  (it "word-left skips back to the start of the current/previous word"
    (should-equal? (edit-row+col (process-key (key "word-left") '("foo bar baz") 0 11 2 #f))
                    '(0 8)))

  (it "word-left skips over multiple whitespace characters"
    (should-equal? (edit-row+col (process-key (key "word-left") '("foo   bar") 0 9 2 #f))
                    '(0 6)))

  (it "word-right skips forward to the start of the next word"
    (should-equal? (edit-row+col (process-key (key "word-right") '("foo bar baz") 0 0 2 #f))
                    '(0 4)))

  (it "word-left wraps to the end of the previous line at column 0"
    (should-equal? (edit-row+col (process-key (key "word-left") '("first" "") 1 0 2 #f))
                    '(0 5)))

  (it "word-right wraps to the start of the next line at end-of-line"
    (should-equal? (edit-row+col (process-key (key "word-right") '("first" "second") 0 5 2 #f))
                    '(1 0)))

  (it "word-left/word-right are no-ops at the very start/end of the buffer"
    (should-equal? (edit-row+col (process-key (key "word-left") '("only") 0 0 2 #f))
                    '(0 0))
    (should-equal? (edit-row+col (process-key (key "word-right") '("only") 0 4 2 #f))
                    '(0 4))))

(spec-summary!)
