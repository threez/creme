(import (scheme base) (scheme write) (scheme eval) (scheme read) (scheme process-context) (creme tui) (creme scheme-lexer))

(define (range-list a b) (if (>= a b) '() (cons a (range-list (+ a 1) b))))

(define lessons
  (list
    (list "Define" "Bind a name to a value with define."
          "(define x (+ 2 3))")
    (list "Lists" "Build a list with the list procedure."
          "(list 1 2 3)")
    (list "Higher-order: map" "Apply a function to every element of a list."
          "(map (lambda (n) (* n n)) (list 1 2 3 4))")
    (list "Recursion" "A function that calls itself."
          "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 5)")
    (list "Strings" "Glue strings together with string-append."
          "(string-append \"hello, \" \"scheme\")")))

(define lesson-index 0)
(define log-lines (list "Welcome! Ctrl-X evaluates the input. Tab switches panes. n/p browse lessons, l loads one. Esc quits."))
(define vstack #f)
(define bottom-pane #f)

(define (lesson-title l) (car l))
(define (lesson-desc l) (car (cdr l)))
(define (lesson-code l) (car (cdr (cdr l))))
(define (current-lesson) (list-ref lessons lesson-index))

(define (log-append! line)
  (set! log-lines (append log-lines (creme line))))

;; Portable replacement for the old (creme extra) eval-string helper:
;; parses `src` one form at a time, evaluates each with current-output-
;; port parameterized to a string port (so the evaluated code's own
;; display/write can't reach the real terminal mid-render), and returns
;; "=> printed-result" on success or "!! message" if evaluation raised.
(define (eval-source-line src)
  (guard (e (#t (string-append "!! " (if (error-object? e) (error-object-message e) "evaluation failed"))))
    (define captured (open-output-string))
    (define result
      (parameterize ((current-output-port captured))
        (define in (open-input-string src))
        (define (last-result prev)
          (define form (read in))
          (if (eof-object? form)
              prev
              (last-result (eval form))))
        (last-result (if #f #f))))
    (define printed (get-output-string captured))
    (define result-text (open-output-string))
    (write result result-text)
    (string-append "=> "
      (if (string=? printed "") "" (string-append printed " "))
      (get-output-string result-text))))

;; ---- Syntax highlighting for the input pane ----
;;
;; TextEdit's highlighter contract (tui-text-edit-set-highlighter! in
;; src/scheme/modules/creme/tui.cr) wants `line-string -> list of
;; (text . style-or-#f)` pairs, where `style` is a real tui-style OBJECT
;; (see tui_cells_from_scheme/tui_style_from_alist there) — a different
;; shape than (creme highlight)'s highlight-line, which instead returns a
;; single pre-rendered ANSI-colored STRING. So highlight-line itself can't
;; be used directly here; instead we call (creme scheme-lexer)'s
;; scheme-tokenize ourselves (the same tokenizer highlight-line is built
;; on) to get real per-token (kind . text) pairs, then map each kind to a
;; tui-style object using the SAME color-family mapping highlight-line's
;; own token-color uses internally (modules/creme/highlight.sld) --
;; translating its ANSI SGR codes (1;34 bold-blue, 32 green, 36 cyan, 35
;; magenta, 2 dim, 33 yellow) into equivalent tui-style calls. Since we
;; only change each token's STYLE and never its TEXT or boundaries, the
;; "concatenated text equals the input line exactly" contract holds for
;; free -- it's the same invariant scheme-tokenize/highlight-line already
;; guarantee.

(define scheme-keywords
  (list "define" "lambda" "λ" "if" "cond" "when" "unless"
        "let" "let*" "letrec" "letrec*" "let-values" "let*-values"
        "let-syntax" "letrec-syntax" "define-syntax" "syntax-rules"
        "begin" "and" "or" "quote" "quasiquote" "unquote" "unquote-splicing"
        "set!" "define-values" "define-record-type" "case" "case-lambda"
        "do" "guard" "parameterize" "cond-expand"
        "delay" "delay-force" "make-promise"
        "require" "defmacro"))

(define (scheme-tui-keyword? text) (if (member text scheme-keywords) #t #f))

(define scheme-tui-keyword-style (tui-style (list (cons "bold" #t) (cons "fg" (tui-color-named 'blue)))))
(define scheme-tui-string-style (tui-style (list (cons "fg" (tui-color-named 'green)))))
(define scheme-tui-char-style (tui-style (list (cons "fg" (tui-color-named 'cyan)))))
(define scheme-tui-number-style (tui-style (list (cons "fg" (tui-color-named 'magenta)))))
(define scheme-tui-boolean-style (tui-style (list (cons "fg" (tui-color-named 'cyan)))))
(define scheme-tui-dim-style (tui-style (list (cons "dim" #t))))
(define scheme-tui-quote-style (tui-style (list (cons "fg" (tui-color-named 'yellow)))))

;; Same kind -> color-family mapping as (creme highlight)'s own
;; token-color, just expressed as tui-style objects instead of ANSI SGR
;; codes. #f (no style) for plain/uncolored kinds (symbol non-keywords,
;; whitespace, unknown) -- same convention the old inline highlighter's
;; own token-style used for "no color".
(define (scheme-tui-token-style kind text)
  (case kind
    ((symbol) (if (scheme-tui-keyword? text) scheme-tui-keyword-style #f))
    ((string unterminated-string) scheme-tui-string-style)
    ((char) scheme-tui-char-style)
    ((number) scheme-tui-number-style)
    ((boolean) scheme-tui-boolean-style)
    ((open close) scheme-tui-dim-style)
    ((line-comment block-comment unterminated-block-comment datum-comment) scheme-tui-dim-style)
    ((quote-mark) scheme-tui-quote-style)
    (else #f))) ; whitespace, unknown: no style

;; The adapter itself: tokenize `line` with the real lexer and map each
;; (kind . text) token to (text . style-or-#f), preserving token
;; boundaries exactly (so concatenation still equals `line`).
(define (scheme-tui-highlight-line line)
  (map (lambda (tok)
         (let ((kind (car tok)) (text (cdr tok)))
           (cons text (scheme-tui-token-style kind text))))
       (scheme-tokenize line)))

;; Rebuilds the input pane around fresh text, keeping `bottom-pane` and
;; the vstack's own hosted widget pointed at the same TextEdit object —
;; tui-text-edit-value always needs to read whatever is currently loaded.
(define (load-input! text)
  (set! bottom-pane (tui-text-edit text))
  (tui-text-edit-set-highlighter! bottom-pane scheme-tui-highlight-line)
  (tui-vstack-set-bottom! vstack bottom-pane))

(define top-title-fn
  (lambda () (string-append "Try Scheme - " (lesson-title (current-lesson)))))

(define top-content-size-fn
  (lambda () (+ 4 (length log-lines))))

(define top-render-fn
  (lambda (buf)
    (define lesson (current-lesson))
    (tui-buffer-set! buf 0 0 (lesson-title lesson))
    (tui-buffer-set! buf 1 0 (lesson-desc lesson))
    (tui-buffer-set! buf 2 0 (string-append "code: " (lesson-code lesson)))
    (tui-buffer-set! buf 3 0 "----------------------------------------")
    (for-each
      (lambda (i) (tui-buffer-set! buf (+ 4 i) 0 (list-ref log-lines i)))
      (range-list 0 (length log-lines)))))

(define top-handle-key-fn
  (lambda (ev)
    (define key (cdr (assoc "key" ev)))
    (if (string=? key "char")
        (let ((c (cdr (assoc "char" ev))))
          (cond
            ((eq? c #\n)
             (set! lesson-index (modulo (+ lesson-index 1) (length lessons)))
             #t)
            ((eq? c #\p)
             (set! lesson-index (modulo (- lesson-index 1) (length lessons)))
             #t)
            ((eq? c #\l)
             (load-input! (lesson-code (current-lesson)))
             #t)
            (else #f)))
        #f)))

(define top-status-hint-fn
  (lambda () " n:next lesson  p:previous lesson  l:load into input  Ctrl-X:eval input  Esc:quit"))

(define top-pane
  (tui-make-scrollable top-title-fn top-content-size-fn top-render-fn top-handle-key-fn top-status-hint-fn))

(define screen (tui-screen))
(set! bottom-pane (tui-text-edit (lesson-code (current-lesson))))
(tui-text-edit-set-highlighter! bottom-pane scheme-tui-highlight-line)
(set! vstack (tui-vstack screen top-pane bottom-pane 8))

(tui-run screen vstack
  (lambda (ev)
    (define key (cdr (assoc "key" ev)))
    (cond
      ((string=? key "esc") (exit))
      ((string=? key "ctrl_x")
       (log-append! (string-append "> " (tui-text-edit-value bottom-pane)))
       (log-append! (eval-source-line (tui-text-edit-value bottom-pane)))
       (load-input! "")
       #t)
      (else (tui-handle-key! vstack ev)))))
