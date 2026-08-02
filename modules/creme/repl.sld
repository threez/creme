;; ===========================================================================
;; (creme repl): a single, shared REPL loop -- native Crystal, --self-hosted,
;; and cvm/cvm all import and run the SAME (run-repl) instead of each having
;; their own (src/main.cr's `repl`, cvm/repl.scm) -- built entirely out of
;; the already-built, already-cross-runtime-verified building blocks:
;; (creme scheme-lexer)/(creme highlight) for tokenizing/coloring/paren-
;; balance, (creme term) for raw-mode key-at-a-time input and relative
;; cursor moves, (creme introspection) for the runtime/tty-detection alist.
;; No backend is ever special-cased in here -- every difference between the
;; three runtimes is already absorbed by those libraries.
;;
;; ---- Two completely different code paths, chosen once at startup -------
;;
;; (stdin-tty?) #f (piped input -- scripts, `... | ./bin/creme`, CI):
;;   a PLAIN loop, no raw mode, no highlighting, no live redraw -- just
;;   `read-line`, accumulate, and use `paren-balance` (instead of the old
;;   read/SchemeIncompleteError-exception dance src/main.cr's `repl` used)
;;   to decide when a full top-level form (or several) is ready to run.
;;   This deliberately reproduces src/main.cr's existing piped-script
;;   behavior byte-for-byte in spirit (prompt printed every line via
;;   `display`, buffer resets after a complete submission, clean EOF) --
;;   nothing about this path may regress previously-passing piped specs.
;;
;; (stdin-tty?) #t (a real interactive terminal):
;;   raw mode (`term-raw-mode-enter!`) plus a hand-rolled line editor that
;;   mirrors the `tui` shard's own TextEdit widget model 1:1 (see
;;   lib/tui/src/tui/widgets/text_edit.cr, and this library's own
;;   process-key below): a list of logical lines plus a (row . col)
;;   cursor, backspace/delete merge across a line boundary exactly like
;;   TextEdit's, left/right wrap at line boundaries, up/down move to the
;;   same column clamped to the target line's length (no "sticky column"
;;   memory across multiple vertical moves -- TextEdit's own visual-row
;;   sticky-column logic is overkill for a REPL input buffer that's never
;;   soft-wrapped by us).
;;
;; ---- Redraw strategy (interactive mode only) ----------------------------
;;
;; Every key event triggers ONE full redraw of just the input region (not
;; a per-character diff like the `tui` shard's Screen -- overkill for a
;; REPL's typical few-line input, see this file's own task brief) via
;; term-move-cursor!/term-clear-to-eol!/term-write!, all RELATIVE moves
;; (term-move-cursor! only moves relative to wherever the cursor already
;; is -- there's no absolute-position primitive in (creme term)). To do a
;; full redraw with only relative moves, redraw! (below) threads a small
;; "where did the last redraw leave the real terminal cursor" tuple
;; (prompt-length . row . col . line-count) from call to call: each
;; redraw first walks the cursor back from that remembered position to
;; the TRUE top-left of the input region (row 0, terminal column 0),
;; re-clears+rewrites every line (row 0 also gets the current prompt
;; re-printed, so a prompt that changes shape -- fresh vs. "...N>"
;; continuation -- always reflects the CURRENT paren-balance depth, live,
;; as the user types), clears any now-stale trailing lines left over from
;; a longer previous buffer, and finally walks the cursor forward to the
;; logical (row . col) the caller actually wants it at. Column position on
;; row 0 always accounts for the prompt's own on-screen width (`term-col`
;; below) since the prompt and line 0's buffer text share that terminal
;; row. This never touches anything above the input region, so previous
;; prompts/results stay untouched in normal scrollback (the whole reason
;; this doesn't reuse (creme tui)'s alt-screen Screen/Runtime). Known
;; limitation, inherent to a relative-move-only redraw: if the terminal
;; itself scrolls mid-edit (buffer taller than the remaining screen), the
;; remembered "walk back N rows" math no longer lines up with what's
;; physically on screen -- acceptable for a REPL's realistic input sizes,
;; not attempted to be solved here.
;;
;; Live paren-depth feedback (per the task brief's "some visual indicator
;; beyond highlight colors" ask): the PROMPT itself is that indicator --
;; "> " when the buffer is a complete, submittable form, or "...N> "
;; (N = current open-bracket depth from
;; paren-balance) while still open -- rather than a separate status line,
;; since the prompt is redrawn live on every keystroke anyway (see above)
;; and this needs no extra screen real estate.
;;
;; ---- Ctrl-C / Ctrl-D semantics -------------------------------------------
;;
;;   Ctrl-C: aborts whatever's currently being typed (buffer discarded)
;;           without exiting the REPL -- common-shell convention. The
;;           aborted text is left visible in scrollback (cursor is walked
;;           to the end of the old buffer and a real newline is emitted
;;           before starting fresh), same as a shell showing "^C" and
;;           moving on rather than silently erasing what you typed.
;;   Ctrl-D: if the buffer is empty, exits the REPL cleanly (restores the
;;           terminal via the dynamic-wind below, then returns from
;;           run-repl). If the buffer has partial content, Ctrl-D instead
;;           behaves exactly like Ctrl-C (abort, don't exit) -- matching
;;           Python's REPL convention that Ctrl-D only exits on a truly
;;           empty line, not "make everything you typed vanish AND quit."
;;
;; ---- Cleanup guarantee ----------------------------------------------------
;;
;; Raw mode is entered/exited via `dynamic-wind`, whose "after" thunk runs
;; no matter how the dynamic extent of the interactive loop is left --
;; normal return (Ctrl-D-on-empty-buffer) or an exception unwinding through
;; it -- so the terminal is never left in no-echo/no-canon mode even if
;; something inside the loop misbehaves. A `guard` around the loop body
;; ALSO catches anything escaping (defense in depth -- every per-key and
;; per-form-eval error path already has its own narrower `guard`, so this
;; outer one should never actually fire) and prints it rather than letting
;; it propagate past the dynamic-wind as a raw, possibly-terminal-mangling
;; crash.
;;
;; ---- Evaluation -----------------------------------------------------------
;;
;; A submitted buffer is re-read one top-level form at a time (`read` over
;; an open-input-string of the whole buffer) and each is `eval`'d in
;; `(interaction-environment)` (so `(define x 5)` on one submission and
;; `(display x)` on the next resolve to the same global, like any REPL).
;; Each form's eval+print is wrapped in its OWN `guard` (not one guard
;; around the whole submission) so one bad form's error doesn't stop the
;; rest of the same submission's forms from still being tried, and never
;; crashes the surrounding loop -- mirrors (creme spec)'s own
;; spec-condition-message pattern for turning an arbitrary raised
;; condition into a human-readable string (error-object-message when it's
;; a real error-object, a generic fallback otherwise).
;; ===========================================================================

(define-library (creme repl)
  ;; process-key is exported alongside run-repl purely for testability --
  ;; see spec/creme/repl_spec.scm -- so a spec can drive the real key-
  ;; handling path with a hand-built key alist instead of a real terminal.
  (export run-repl process-key)
  (import (scheme base) (scheme cxr) (scheme char) (scheme read) (scheme write) (scheme eval) (scheme repl)
          (creme highlight) (creme scheme-lexer) (creme term) (creme introspection) (creme string))
  (begin

    (define (colorize code text)
      (string-append "\x1b;[" code "m" text "\x1b;[0m"))

    (define (repl-condition-message e)
      (cond
        ((error-object? e)
         (string-append (error-object-message e)
                         (if (null? (error-object-irritants e))
                             ""
                             (string-append " " (call-with-write-string (error-object-irritants e))))))
        (else "non-error value raised")))

    (define (call-with-write-string v)
      (let ((port (open-output-string)))
        (write v port)
        (get-output-string port)))

    ;; ---- small list/string helpers (buffer is always tiny, so plain
    ;; O(n) rebuilds are simplest and fast enough) ----

    (define (list-set lst i v)
      (if (= i 0) (cons v (cdr lst)) (cons (car lst) (list-set (cdr lst) (- i 1) v))))

    (define (list-insert-at lst i v)
      (if (= i 0) (cons v lst) (cons (car lst) (list-insert-at (cdr lst) (- i 1) v))))

    (define (list-remove-at lst i)
      (if (= i 0) (cdr lst) (cons (car lst) (list-remove-at (cdr lst) (- i 1)))))

    (define (string-insert s i ch)
      (string-append (substring s 0 i) (string ch) (substring s i (string-length s))))

    (define (string-remove-at s i)
      (string-append (substring s 0 i) (substring s (+ i 1) (string-length s))))

    (define (join-lines lines)
      (if (null? lines)
          ""
          (let loop ((rest (cdr lines)) (acc (car lines)))
            (if (null? rest) acc (loop (cdr rest) (string-append acc "\n" (car rest)))))))

    ;; Counterpart to join-lines, for recalling a history entry back into
    ;; the buffer's list-of-logical-lines shape. (creme string)'s own
    ;; string-split (already imported here for string-prefix?/string-join)
    ;; does exactly this -- (string-split s "\n") -- so this is a thin,
    ;; named wrapper rather than a hand-rolled scan.
    (define (split-lines text) (string-split text "\n"))

    (define (list-take lst n)
      (if (= n 0) '() (cons (car lst) (list-take (cdr lst) (- n 1)))))

    ;; ---- auto-indent ---------------------------------------------------------
    ;;
    ;; When Enter starts a continuation line, indent it to align with the
    ;; SECOND element (the first argument) of the innermost still-open
    ;; list -- the common Lisp convention, e.g.:
    ;;   (define (mul x)
    ;;           (* x x))
    ;; ("(mul x)" is (define ...)'s 2nd element, so the body aligns under
    ;; its own column, 8). Falls back to right after the open paren itself
    ;; when that list doesn't have a 2nd element yet (e.g. buffer ends
    ;; right after "(define" with nothing else typed), and to column 0
    ;; when nothing is open at all. Since indentation is recomputed fresh
    ;; from the ACTUAL current nesting depth every time Enter is pressed
    ;; (not tracked incrementally), typing a closing paren before Enter
    ;; naturally "jumps back" to the enclosing level's own column, with no
    ;; separate bookkeeping needed.
    ;;
    ;; col-after-whitespace: a whitespace token's text may itself contain
    ;; newline(s) (scheme-tokenize treats a run of spaces/tabs/newlines as
    ;; one token) -- if so, column resets to 0 at the last newline and
    ;; counts only what follows it; otherwise it's just `col` plus the
    ;; token's own length.
    (define (col-after-whitespace col text)
      (let ((len (string-length text)))
        (let scan ((i (- len 1)))
          (cond
            ((< i 0) (+ col len))
            ((char=? (string-ref text i) #\newline) (- len i 1))
            (else (scan (- i 1)))))))

    ;; A stack entry is (paren-col align-col open-len elems): the open
    ;; paren's own column, the column of its 2nd element once known (else
    ;; #f), the open token's text length (1 for "(", longer for "#(" etc.),
    ;; and how many elements have been seen inside it so far.
    (define (bump-top stack col)
      (if (null? stack)
          stack
          (let* ((top (car stack)) (paren-col (car top)) (align-col (cadr top))
                 (open-len (caddr top)) (elems (cadddr top))
                 (new-elems (+ elems 1))
                 (new-align (if (and (not align-col) (= new-elems 2)) col align-col)))
            (cons (list paren-col new-align open-len new-elems) (cdr stack)))))

    ;; `prompt-len` is the on-screen column row 0's own buffer content
    ;; actually starts at (row 0 shares its terminal row with the live
    ;; prompt text -- see term-col below and redraw!'s own header
    ;; comment) -- e.g. typing "(define (mul x)" right after a "...1> "
    ;; prompt means the outer "(" sits at SCREEN column 6, not buffer
    ;; column 0, so "(mul x)"'s 2nd-element alignment column must be
    ;; measured from there too, or a continuation line (which has NO
    ;; prompt of its own, unlike row 0) would visually land under the
    ;; wrong character -- this is exactly why col starts at `prompt-len`
    ;; here instead of 0, matching term-col's own row-0-vs-other-rows
    ;; distinction.
    (define (indent-for-lines lines prompt-len)
      (let loop ((toks (scheme-tokenize (join-lines lines))) (col prompt-len) (stack '()))
        (if (null? toks)
            (if (null? stack)
                0
                (let* ((top (car stack)) (paren-col (car top)) (align-col (cadr top)) (open-len (caddr top)))
                  (if align-col align-col (+ paren-col open-len))))
            (let* ((tok (car toks)) (kind (car tok)) (text (cdr tok)) (tlen (string-length text)))
              (case kind
                ((whitespace) (loop (cdr toks) (col-after-whitespace col text) stack))
                ((open) (loop (cdr toks) (+ col tlen) (cons (list col #f tlen 0) (bump-top stack col))))
                ((close) (loop (cdr toks) (+ col tlen) (if (null? stack) stack (cdr stack))))
                (else (loop (cdr toks) (+ col tlen) (bump-top stack col))))))))

    ;; ---- tab completion -----------------------------------------------------
    ;;
    ;; Candidates are every currently-bound top-level name ((bound-names),
    ;; live -- grows as the user `define`s things) plus the same reader-
    ;; visible keyword list (creme highlight) uses for syntax highlighting
    ;; -- that list is a private, unexported definition there, so per this
    ;; project's own established convention (see (creme scheme-lexer)'s own
    ;; header comment on why it duplicates a few reader constants rather
    ;; than reach into (creme compiler reader)'s internals) it's simplest
    ;; to just duplicate the same literal list here rather than change
    ;; (creme highlight)'s exports for this.
    (define repl-keywords
      (list "define" "lambda" "λ" "if" "cond" "when" "unless"
            "let" "let*" "letrec" "letrec*" "let-values" "let*-values"
            "let-syntax" "letrec-syntax" "define-syntax" "syntax-rules"
            "begin" "and" "or" "quote" "quasiquote" "unquote" "unquote-splicing"
            "set!" "define-values" "define-record-type" "case" "case-lambda"
            "do" "guard" "parameterize" "cond-expand"
            "delay" "delay-force" "make-promise"
            "require" "defmacro"))

    ;; Simple O(n^2) member-based dedup -- the candidate list (bound names
    ;; plus keywords) is always small (well under a thousand names), so
    ;; there's no need for anything fancier.
    (define (dedup lst)
      (let loop ((rest lst) (acc '()))
        (cond
          ((null? rest) (reverse acc))
          ((member (car rest) acc) (loop (cdr rest) acc))
          (else (loop (cdr rest) (cons (car rest) acc))))))

    (define (completion-candidates)
      (dedup (append (bound-names) repl-keywords)))

    ;; Returns (cons prefix-text prefix-start-col) when the cursor sits
    ;; immediately after a plain identifier atom on the given row -- e.g.
    ;; typing "(disp|" (cursor at |) returns ("disp" . 1). Returns #f when
    ;; there's nothing sensible to complete (cursor is at whitespace, right
    ;; after a paren with no symbol yet, inside a string/comment, etc.).
    (define (current-word-prefix lines row col)
      (let* ((line (list-ref lines row))
             (toks (scheme-tokenize (substring line 0 col))))
        (if (null? toks)
            #f
            (let* ((last-tok (car (reverse toks))) (kind (car last-tok)) (text (cdr last-tok)))
              (if (eq? kind 'symbol)
                  (cons text (- col (string-length text)))
                  #f)))))

    (define (repl-filter pred lst)
      (cond
        ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (repl-filter pred (cdr lst))))
        (else (repl-filter pred (cdr lst)))))

    (define (matches-for prefix)
      (repl-filter (lambda (c) (string-prefix? c prefix)) (completion-candidates)))

    ;; ---- completion menu ----------------------------------------------------
    ;;
    ;; When Tab finds 2+ matches with no further longest-common-prefix growth
    ;; possible, an interactive menu opens instead of just printing a static
    ;; candidate list. A menu record is either #f (closed) or holds:
    ;;   candidates    -- the match list computed ONCE, when the menu opened,
    ;;                    capped to `menu-max-candidates`; fixed for the
    ;;                    menu's whole lifetime -- Tab only advances
    ;;                    selected-index, it never recomputes matches.
    ;;   selected-index -- index into `candidates` of the currently
    ;;                    highlighted/previewed one.
    ;;   prefix-row/prefix-col -- where the ORIGINAL typed prefix started in
    ;;                    `lines`; together with the (unchanged, while a menu
    ;;                    is open) current cursor column this delimits the
    ;;                    exact span later replaced by the selected candidate,
    ;;                    either for a live preview (redraw!, rendering-only)
    ;;                    or for real on accept (process-key's "enter" case).
    ;; The real `lines`/`col` are NEVER written to while a menu is open --
    ;; only the redraw path splices the selected candidate in for display.
    (define-record-type menu
      (make-menu candidates selected-index prefix-row prefix-col)
      menu?
      (candidates menu-candidates)
      (selected-index menu-selected-index)
      (prefix-row menu-prefix-row)
      (prefix-col menu-prefix-col))

    (define menu-max-candidates 15)

    ;; Splices the currently-selected candidate into a COPY of `lines` for
    ;; rendering only, replacing the span from the menu's recorded
    ;; prefix-row/prefix-col through `end-col` (the current, unmoved cursor
    ;; column on that same row -- i.e. where the original typed prefix
    ;; ended). Never touches the real buffer.
    (define (splice-candidate-lines lines menu end-col)
      (let* ((prow (menu-prefix-row menu)) (pcol (menu-prefix-col menu))
             (candidate (list-ref (menu-candidates menu) (menu-selected-index menu)))
             (line (list-ref lines prow))
             (rest-of-line (substring line end-col (string-length line)))
             (new-line (string-append (substring line 0 pcol) candidate rest-of-line)))
        (list-set lines prow new-line)))

    ;; One (display-text . visible-length) pair per candidate -- visible-length
    ;; excludes the raw ANSI reverse-video wrapping so redraw!'s own column
    ;; bookkeeping (which walks the cursor by VISIBLE columns) stays correct
    ;; for the highlighted, currently-selected row too.
    (define (menu-rows menu)
      (if (not menu)
          '()
          (let ((cands (menu-candidates menu)) (sel (menu-selected-index menu)))
            (let loop ((rest cands) (i 0) (acc '()))
              (if (null? rest)
                  (reverse acc)
                  (loop (cdr rest) (+ i 1)
                        (cons (cons (if (= i sel) (colorize "7" (car rest)) (car rest))
                                    (string-length (car rest)))
                              acc)))))))

    ;; Standard fold: start with the first string, repeatedly shorten it to
    ;; match each subsequent string's shared leading run.
    (define (longest-common-prefix strs)
      (if (null? strs)
          ""
          (let loop ((best (car strs)) (rest (cdr strs)))
            (if (null? rest)
                best
                (let* ((s (car rest))
                       (max-len (min (string-length best) (string-length s))))
                  (let scan ((i 0))
                    (if (or (= i max-len) (not (char=? (string-ref best i) (string-ref s i))))
                        (loop (substring best 0 i) (cdr rest))
                        (scan (+ i 1)))))))))

    ;; ---- prompt -----------------------------------------------------------

    ;; `multiline?` keeps the prompt at a STABLE width once a session has
    ;; already grown past one line: without this, the very keystroke that
    ;; closes the last open bracket flips the prompt from e.g. "...1> "
    ;; (6 chars) back down to the short "> " (2 chars) -- since row 0
    ;; shares its terminal row with the prompt (see term-col/indent-for-
    ;; lines above), that shrink physically shifts row 0's own buffer text
    ;; 4 columns to the LEFT on screen, instantly breaking the alignment
    ;; every continuation row below it already baked in as literal spaces
    ;; while the prompt was still wide. Showing "...0> " instead of "> "
    ;; for a complete-but-already-multiline buffer costs nothing (same
    ;; width the whole session) and keeps every already-drawn row's
    ;; indentation valid until submission. A genuinely single-line buffer
    ;; still gets the short "> " once complete, matching today's behavior
    ;; there since there's no other row's alignment to protect.
    (define (build-prompt-from-text text multiline?)
      (let* ((pb (paren-balance text)) (status (cdr pb)) (depth (car pb)))
        (if (and (eq? status 'complete) (not multiline?))
            "> "
            (string-append "..." (number->string depth) "> "))))

    (define (build-prompt lines)
      (build-prompt-from-text (join-lines lines) (> (length lines) 1)))

    ;; ---- shared evaluation --------------------------------------------------

    (define (eval-print-forms! text)
      (let ((in (open-input-string text)))
        (let loop ()
          (let ((form (read in)))
            (if (not (eof-object? form))
                (begin
                  (guard (e (#t (display (colorize "31" (string-append "error: " (repl-condition-message e))))
                                (newline)))
                    ;; This implementation has no distinct "unspecified"/void
                    ;; value -- e.g. display's own return value -- (scheme
                    ;; base)'s write.cr) IS the empty list, so an eval'd form
                    ;; like (display ...) would otherwise echo a spurious
                    ;; "()" right after whatever it already printed itself.
                    ;; Suppress printing only for that exact case (matching
                    ;; how most REPLs don't auto-print a "no useful value"
                    ;; result) -- the minor cost is that a form that
                    ;; genuinely evaluates to '() (e.g. (list)) also prints
                    ;; nothing, same tradeoff this project's own value model
                    ;; already makes everywhere else.
                    (let ((result (eval form (interaction-environment))))
                      (if (not (null? result))
                          (begin (write result) (newline)
                                 (eval (list 'define '$ (list 'quote result)) (interaction-environment))))))
                  (loop)))))))

    ;; ---- non-interactive fallback (piped input) ------------------------------

    (define (run-repl-noninteractive)
      (let loop ((buffer ""))
        (display (build-prompt-from-text buffer #f))
        (let ((line (read-line)))
          (if (eof-object? line)
              (newline)
              (let* ((new-buffer (if (string=? buffer "") line (string-append buffer "\n" line)))
                     (pb (paren-balance new-buffer)))
                (if (eq? (cdr pb) 'complete)
                    (begin (eval-print-forms! new-buffer) (loop ""))
                    (loop new-buffer)))))))

    ;; ---- interactive line editor --------------------------------------------

    ;; Terminal column occupied by logical (row, col): row 0 shares its
    ;; terminal row with the prompt text, every other row starts at
    ;; terminal column 0.
    (define (term-col prompt-len row col) (if (= row 0) (+ prompt-len col) col))

    (define (key-kind key) (cdr (assq 'kind key)))
    (define (key-char key) (cdr (assq 'char key)))

    ;; Redraws the whole input region -- PLUS, when a completion `menu` is
    ;; open, a live preview of the selected candidate spliced into the input
    ;; (rendering-only, via splice-candidate-lines -- the real `lines` are
    ;; never touched) followed immediately by the menu's own candidate list
    ;; (one per row, current selection reverse-videoed, see menu-rows) --
    ;; and leaves the real cursor at logical (target-row . target-col)
    ;; WITHIN THE INPUT, never on the menu block itself. `prev` is the
    ;; 4-tuple this same procedure returned last time (or (0 0 0 0) for the
    ;; very first call, when nothing has been drawn yet and the real cursor
    ;; already sits at the true row-0/col-0 origin) -- see this file's own
    ;; header comment for the overall strategy. The 4th element of the
    ;; returned tuple is now the TOTAL row count actually drawn (input rows
    ;; plus any menu rows), so a later redraw (menu just closed, buffer
    ;; shrunk, etc.) still correctly detects and clears whatever's now
    ;; stale below the new, possibly-shorter content.
    (define (redraw! prompt lines target-row target-col menu prev-prompt-len prev-row prev-col prev-count)
      (let* ((render-lines (if menu (splice-candidate-lines lines menu target-col) lines))
             (rows (menu-rows menu))
             (n (length render-lines))
             (m (length rows))
             (total (+ n m))
             (max-n (max total prev-count))
             (start-col (term-col prev-prompt-len prev-row prev-col)))
        (term-move-cursor! (- prev-row) (- start-col))
        (let loop ((i 0))
          (term-clear-to-eol!)
          (let ((prompt-part (if (= i 0) (string-length prompt) 0)))
            (if (= i 0) (term-write! prompt))
            (let ((actual-col
                   (cond
                     ((< i n)
                      (let ((text (list-ref render-lines i)))
                        (term-write! (highlight-line text))
                        (+ prompt-part (string-length text))))
                     ((< i total)
                      (let ((pair (list-ref rows (- i n))))
                        (term-write! (car pair))
                        (+ prompt-part (cdr pair))))
                     (else prompt-part))))
              (if (< (+ i 1) max-n)
                  (begin (term-move-cursor! 1 (- actual-col)) (loop (+ i 1)))
                  (let ((target-col-actual (term-col (string-length prompt) target-row target-col)))
                    (term-move-cursor! (- target-row i) (- target-col-actual actual-col))
                    (list (string-length prompt) target-row target-col total))))))))

    ;; Target (row . col) for word-left (Ctrl-Left, Alt/Ctrl-Left): skip any
    ;; whitespace immediately before the cursor, then skip backward through
    ;; non-whitespace to the start of that run -- the same "stop at the
    ;; start of the previous word" convention readline/most terminal
    ;; editors use for Alt-B. Wraps to the end of the previous line at
    ;; column 0, mirroring plain Left's line-wrap. Ported from
    ;; lib/tui/src/tui/widgets/text_edit.cr's word_left_pos, adapted from
    ;; that widget's @text_lines/@text_row/@text_col fields to this file's
    ;; plain lines/row/col values.
    (define (word-left-pos lines row col)
      (if (= col 0)
          (if (= row 0)
              (cons row col)
              (cons (- row 1) (string-length (list-ref lines (- row 1)))))
          (let ((line (list-ref lines row)))
            (let loop ((col col))
              (if (and (> col 0) (char-whitespace? (string-ref line (- col 1))))
                  (loop (- col 1))
                  (let loop2 ((col col))
                    (if (and (> col 0) (not (char-whitespace? (string-ref line (- col 1)))))
                        (loop2 (- col 1))
                        (cons row col))))))))

    ;; Target (row . col) for word-right (Ctrl-Right, Alt/Ctrl-Right): skip
    ;; forward through the current word (non-whitespace), then skip forward
    ;; through trailing whitespace, landing at the start of the next word --
    ;; the Alt-F counterpart to word-left-pos. Wraps to the start of the
    ;; next line at end-of-line, mirroring plain Right's line-wrap. Ported
    ;; from lib/tui/src/tui/widgets/text_edit.cr's word_right_pos.
    (define (word-right-pos lines row col)
      (let* ((line (list-ref lines row)) (len (string-length line)))
        (if (>= col len)
            (if (>= row (- (length lines) 1))
                (cons row col)
                (cons (+ row 1) 0))
            (let loop ((col col))
              (if (and (< col len) (not (char-whitespace? (string-ref line col))))
                  (loop (+ col 1))
                  (let loop2 ((col col))
                    (if (and (< col len) (char-whitespace? (string-ref line col)))
                        (loop2 (+ col 1))
                        (cons row col))))))))

    ;; The "no completion menu open" key logic -- UNCHANGED from before the
    ;; completion menu existed, except the old "2+ matches, no further LCP
    ;; growth possible" case (which used to return (show-completions
    ;; matches) for interactive-loop to print as a static, scrolled-into-
    ;; history list) now OPENS a menu instead (see menu-max-candidates /
    ;; make-menu above), and every 'edit result gets a 5th slot -- the menu
    ;; to carry forward, #f in every branch except the one that opens one.
    ;; Called directly when no menu is open; called by process-key (below)
    ;; as a fallback for the "any key other than Tab/Enter cancels the
    ;; menu and resumes normal editing from the untouched buffer" case.
    ;;
    ;; Returns one of:
    ;;   (edit new-lines new-row new-col new-menu)
    ;;   (submit joined-text)
    ;;   (abort)
    ;;   (exit)
    (define (process-key-base key lines row col prompt-len)
      (let ((kind (key-kind key)))
        (cond
          ((string=? kind "char")
           (let* ((ch (key-char key)) (line (list-ref lines row)))
             (list 'edit (list-set lines row (string-insert line col ch)) row (+ col 1) #f)))
          ((string=? kind "backspace")
           (cond
             ((> col 0)
              (let ((line (list-ref lines row)))
                (list 'edit (list-set lines row (string-remove-at line (- col 1))) row (- col 1) #f)))
             ((> row 0)
              (let* ((prev-line (list-ref lines (- row 1))) (cur-line (list-ref lines row))
                     (new-col (string-length prev-line))
                     (new-lines (list-remove-at (list-set lines (- row 1) (string-append prev-line cur-line)) row)))
                (list 'edit new-lines (- row 1) new-col #f)))
             (else (list 'edit lines row col #f))))
          ((string=? kind "delete")
           (let* ((line (list-ref lines row)) (len (string-length line)))
             (cond
               ((< col len) (list 'edit (list-set lines row (string-remove-at line col)) row col #f))
               ((< row (- (length lines) 1))
                (let* ((next-line (list-ref lines (+ row 1)))
                       (new-lines (list-remove-at (list-set lines row (string-append line next-line)) (+ row 1))))
                  (list 'edit new-lines row col #f)))
               (else (list 'edit lines row col #f)))))
          ((string=? kind "left")
           (cond
             ((> col 0) (list 'edit lines row (- col 1) #f))
             ((> row 0) (list 'edit lines (- row 1) (string-length (list-ref lines (- row 1))) #f))
             (else (list 'edit lines row col #f))))
          ((string=? kind "right")
           (let ((len (string-length (list-ref lines row))))
             (cond
               ((< col len) (list 'edit lines row (+ col 1) #f))
               ((< row (- (length lines) 1)) (list 'edit lines (+ row 1) 0 #f))
               (else (list 'edit lines row col #f)))))
          ((string=? kind "up")
           (if (> row 0)
               (let ((new-row (- row 1)))
                 (list 'edit lines new-row (min col (string-length (list-ref lines new-row))) #f))
               (list 'history-prev)))
          ((string=? kind "down")
           (if (< row (- (length lines) 1))
               (let ((new-row (+ row 1)))
                 (list 'edit lines new-row (min col (string-length (list-ref lines new-row))) #f))
               (list 'history-next)))
          ((string=? kind "tab")
           (let ((ctx (current-word-prefix lines row col)))
             (if (not ctx)
                 (list 'edit lines row col #f)
                 (let* ((prefix (car ctx)) (start-col (cdr ctx))
                        (matches (matches-for prefix)))
                   (cond
                     ((null? matches) (list 'edit lines row col #f))
                     (else
                      (let ((lcp (longest-common-prefix matches)))
                        (if (> (string-length lcp) (string-length prefix))
                            ;; extend to the longest common prefix (covers both
                            ;; the single-match case, where lcp = the match
                            ;; itself, and multi-match cases with room to grow)
                            (let* ((line (list-ref lines row))
                                   (rest-of-line (substring line col (string-length line)))
                                   (new-line (string-append (substring line 0 start-col) lcp rest-of-line))
                                   (new-col (+ start-col (string-length lcp))))
                              (list 'edit (list-set lines row new-line) row new-col #f))
                            ;; no further growth possible
                            (if (= (length matches) 1)
                                (list 'edit lines row col #f) ; already fully typed, nothing to add
                                (list 'edit lines row col
                                      (make-menu (list-take matches (min menu-max-candidates (length matches)))
                                                 0 row start-col)))))))))))
          ((or (string=? kind "home") (string=? kind "ctrl-a")) (list 'edit lines row 0 #f))
          ((or (string=? kind "end") (string=? kind "ctrl-e"))
           (list 'edit lines row (string-length (list-ref lines row)) #f))
          ((string=? kind "word-left")
           (let ((p (word-left-pos lines row col))) (list 'edit lines (car p) (cdr p) #f)))
          ((string=? kind "word-right")
           (let ((p (word-right-pos lines row col))) (list 'edit lines (car p) (cdr p) #f)))
          ((string=? kind "enter")
           (let* ((joined (join-lines lines)) (pb (paren-balance joined)))
             (if (eq? (cdr pb) 'complete)
                 (list 'submit joined)
                 (let* ((line (list-ref lines row))
                        (before (substring line 0 col)) (after (substring line col (string-length line)))
                        (indent (indent-for-lines (append (list-take lines row) (list before)) prompt-len))
                        (indent-str (make-string indent #\space))
                        (new-lines (list-insert-at (list-set lines row before) (+ row 1) (string-append indent-str after))))
                   (list 'edit new-lines (+ row 1) indent #f)))))
          ((string=? kind "ctrl-c") (list 'abort))
          ((or (string=? kind "ctrl-d") (string=? kind "eof"))
           (if (and (= (length lines) 1) (string=? (car lines) ""))
               (list 'exit)
               (list 'abort)))
          (else (list 'edit lines row col #f))))) ; escape, unknown: no-op

    ;; Top-level entry point: when a completion menu is open, Tab/Enter get
    ;; special menu-only handling (cycle the selection / accept it into the
    ;; real buffer); every OTHER key kind cancels the menu -- dropping back
    ;; to #f -- and falls through to process-key-base's existing, unchanged
    ;; logic against the untouched lines/row/col (the real buffer was never
    ;; modified while the menu was only being previewed, so "cancel" really
    ;; is just discarding the menu state and handling the key normally).
    ;; When no menu is open, this delegates straight through.
    ;;
    ;; Returns the same shapes as process-key-base.
    (define (process-key key lines row col prompt-len menu)
      (if (not menu)
          (process-key-base key lines row col prompt-len)
          (let ((kind (key-kind key)))
            (cond
              ((string=? kind "tab")
               (let* ((n (length (menu-candidates menu)))
                      (new-idx (modulo (+ (menu-selected-index menu) 1) n)))
                 (list 'edit lines row col
                       (make-menu (menu-candidates menu) new-idx (menu-prefix-row menu) (menu-prefix-col menu)))))
              ((string=? kind "enter")
               ;; Accept: splice the selected candidate permanently into
               ;; `lines` at the recorded prefix span, close the menu, and
               ;; land the cursor right after the inserted text -- a plain
               ;; edit, deliberately NOT re-checked for paren-balance/submit
               ;; here even if the buffer is now complete: accepting a
               ;; completion and submitting the form are two separate
               ;; keystrokes, so a LATER Enter is what submits.
               (let* ((candidate (list-ref (menu-candidates menu) (menu-selected-index menu)))
                      (prow (menu-prefix-row menu)) (pcol (menu-prefix-col menu))
                      (line (list-ref lines prow))
                      (rest-of-line (substring line col (string-length line)))
                      (new-line (string-append (substring line 0 pcol) candidate rest-of-line))
                      (new-col (+ pcol (string-length candidate))))
                 (list 'edit (list-set lines prow new-line) prow new-col #f)))
              (else
               ;; Cancel: drop the menu, then handle this key exactly as if
               ;; no menu had ever been open.
               (let ((result (process-key-base key lines row col prompt-len)))
                 (if (eq? (car result) 'edit)
                     (list 'edit (list-ref result 1) (list-ref result 2) (list-ref result 3) #f)
                     result)))))))

    ;; Walks the real cursor from the just-drawn logical (row . col) to the
    ;; end of the buffer and emits one real newline, so scrollback keeps
    ;; whatever was on screen and whatever comes next (an eval result, or
    ;; a fresh prompt) starts on its own clean line. Shared by both the
    ;; 'abort and 'submit branches of interactive-loop below.
    ;;
    ;; `prev-total` is the just-preceding redraw!'s own total row count
    ;; (input rows + any menu rows). Since a menu is always closed (#f) by
    ;; the time an abort/submit-triggering key is actually processed (any
    ;; other key cancels an open menu first, per process-key above), the
    ;; only remaining subtlety is COSMETIC: the redraw drawn immediately
    ;; before THIS keypress was read may still have shown a now-abandoned
    ;; menu block on screen (menu was open, then this same keypress closed
    ;; it). So after walking to the end of the real buffer, this also walks
    ;; down through and clears any such leftover rows -- using prev-total
    ;; rather than just (length lines) -- before moving back up to emit the
    ;; final newline, or a stale menu row would get left behind, uncleared,
    ;; in the terminal's normal scrollback.
    (define (advance-past-buffer! lines row col prompt-len prev-total)
      (let* ((n (length lines)) (last-row (- n 1)) (last-line (list-ref lines last-row))
             (last-col (string-length last-line))
             (target-col-actual (term-col prompt-len last-row last-col))
             (cur-col-actual (term-col prompt-len row col))
             (extra (- prev-total n)))
        (term-move-cursor! (- last-row row) (- target-col-actual cur-col-actual))
        (if (> extra 0)
            (begin
              (term-move-cursor! 1 (- target-col-actual))
              (let loop ((k 1))
                (term-clear-to-eol!)
                (if (< k extra) (begin (term-move-cursor! 1 0) (loop (+ k 1)))))
              (term-move-cursor! (- extra) target-col-actual)))
        (term-write! "\n")))

    ;; Loads a history entry's text into the buffer (recalled text split
    ;; back into logical lines, cursor at the very end -- last line, last
    ;; column, the standard readline convention) and continues the loop.
    ;; Unlike 'abort/'submit (which emit a real terminal newline via
    ;; advance-past-buffer! and so can legitimately reset `prev` to
    ;; (0 0 0 0) -- the physical cursor really is back at the input
    ;; region's true origin), history recall replaces the CURRENT input
    ;; line in place -- no newline, same terminal row -- so `prev` must
    ;; stay `new-prev` (wherever the just-preceding redraw actually left
    ;; the physical cursor) or the next redraw!'s relative "walk back to
    ;; true origin" math desyncs from reality and corrupts the display.
    (define (loop-with-recalled loop text new-prev history history-index draft)
      (let* ((new-lines (split-lines text))
             (last-row (- (length new-lines) 1))
             (last-col (string-length (list-ref new-lines last-row))))
        (loop new-lines last-row last-col #f new-prev history history-index draft)))

    (define (interactive-loop)
      (let loop ((lines (list "")) (row 0) (col 0) (menu #f) (prev (list 0 0 0 0))
                 (history '()) (history-index #f) (draft #f))
        (let* ((prompt (build-prompt lines))
               (new-prev (apply redraw! prompt lines row col menu prev))
               (key (term-read-key))
               (result (process-key key lines row col (string-length prompt) menu))
               (tag (car result)))
          (cond
            ((eq? tag 'edit)
             (loop (list-ref result 1) (list-ref result 2) (list-ref result 3) (list-ref result 4) new-prev
                   history history-index draft))
            ((eq? tag 'exit) #t)
            ((eq? tag 'abort)
             (advance-past-buffer! lines row col (list-ref new-prev 0) (list-ref new-prev 3))
             (loop (list "") 0 0 #f (list 0 0 0 0) history #f #f))
            ((eq? tag 'submit)
             (advance-past-buffer! lines row col (list-ref new-prev 0) (list-ref new-prev 3))
             (eval-print-forms! (cadr result))
             (let* ((text (cadr result))
                    (new-history (if (and (pair? history) (string=? (car history) text))
                                      history
                                      (cons text history))))
               (loop (list "") 0 0 #f (list 0 0 0 0) new-history #f #f)))
            ((eq? tag 'history-prev)
             (if (null? history)
                 (loop lines row col menu new-prev history history-index draft)
                 (let* ((new-draft (if history-index draft (list lines row col)))
                        (new-index (if history-index (min (+ history-index 1) (- (length history) 1)) 0)))
                   (loop-with-recalled loop (list-ref history new-index) new-prev history new-index new-draft))))
            ((eq? tag 'history-next)
             (cond
               ((not history-index)
                (loop lines row col menu new-prev history history-index draft))
               ((> history-index 0)
                (let ((new-index (- history-index 1)))
                  (loop-with-recalled loop (list-ref history new-index) new-prev history new-index draft)))
               (else
                (loop (car draft) (cadr draft) (caddr draft) #f new-prev history #f #f))))))))

    (define (run-repl-interactive)
      (dynamic-wind
        term-raw-mode-enter!
        (lambda ()
          (guard (e (#t (display (colorize "31" (string-append "repl internal error: " (repl-condition-message e))))
                        (newline)))
            (interactive-loop)))
        term-raw-mode-exit!))

    ;; ---- entry point ----------------------------------------------------------

    ;; The vm/compiler/os/arch/version identity from (runtime) is shown
    ;; ONCE, in this startup banner -- not repeated on every prompt line
    ;; (just a plain "> "/"...N> ", see build-prompt-from-text above).
    (define (run-repl)
      (let* ((rt (runtime))
             (vm (cdr (assq 'vm rt))) (compiler (cdr (assq 'compiler rt)))
             (os (cdr (assq 'os rt))) (arch (cdr (assq 'arch rt))) (version (cdr (assq 'version rt))))
        (display (string-append "creme " version " (" vm "/" compiler ", " os "/" arch ") -- Ctrl-D to exit"))
        (newline)
        (eval '(define $ #f) (interaction-environment))
        (if (stdin-tty?)
            (run-repl-interactive)
            (run-repl-noninteractive))))))
