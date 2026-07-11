(require 'tui)

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
          "(string-append \"hello, \" \"lisp\")")))

(define lesson-index 0)
(define log-lines (list "Welcome! Ctrl-X evaluates the input. Tab switches panes. n/p browse lessons, l loads one. Esc quits."))
(define vstack #f)
(define bottom-pane #f)

(define (lesson-title l) (car l))
(define (lesson-desc l) (car (cdr l)))
(define (lesson-code l) (car (cdr (cdr l))))
(define (current-lesson) (list-ref lessons lesson-index))

(define (log-append! line)
  (set! log-lines (append log-lines (list line))))

(define (eval-result-line result)
  (let ((tag (car (car result)))
        (payload (cdr (car result))))
    (if (string=? tag "ok")
        (string-append "=> " payload)
        (string-append "!! " payload))))

;; ---- Syntax highlighting for the input pane ----

(define lisp-keywords
  (list "define" "lambda" "λ" "if" "cond" "when" "unless" "let" "let*" "letrec"
        "begin" "and" "or" "quote" "quasiquote" "unquote" "unquote-splicing"
        "set!" "require" "defmacro" "defclass" "defgeneric" "defmethod"))

(define lisp-constants (list "#t" "#f" "()"))

(define keyword-style (tui:style (list (cons "bold" #t) (cons "fg" (tui:color-named 'blue)))))
(define string-style (tui:style (list (cons "fg" (tui:color-named 'green)))))
(define number-style (tui:style (list (cons "fg" (tui:color-named 'magenta)))))
(define paren-style (tui:style (list (cons "fg" (tui:color-named 'gray)))))
(define constant-style (tui:style (list (cons "fg" (tui:color-named 'cyan)))))

(define (member? x lst) (if (member x lst) #t #f))

(define (char-space? c) (or (eq? c #\space) (eq? c #\tab)))
(define (char-open? c) (eq? c #\())
(define (char-close? c) (eq? c #\)))
(define (char-quote? c) (eq? c #\"))
(define (char-digit? c) (and (>= (char->integer c) 48) (<= (char->integer c) 57)))
(define (atom-char? c) (not (or (char-space? c) (char-open? c) (char-close? c) (char-quote? c))))

(define (scan-while line i len pred)
  (if (or (>= i len) (not (pred (string-ref line i))))
      i
      (scan-while line (+ i 1) len pred)))

(define (scan-string-end line i len)
  (cond
    ((>= i len) i)
    ((char-quote? (string-ref line i)) (+ i 1))
    (else (scan-string-end line (+ i 1) len))))

(define (all-digits? tok i len)
  (or (>= i len)
      (and (char-digit? (string-ref tok i)) (all-digits? tok (+ i 1) len))))

(define (token-number? tok)
  (and (> (string-length tok) 0) (all-digits? tok 0 (string-length tok))))

(define (token-style tok)
  (cond
    ((member? tok lisp-keywords) keyword-style)
    ((member? tok lisp-constants) constant-style)
    ((token-number? tok) number-style)
    (else #f)))

;; Scans `line` into a list of (text . style-or-#f) pairs covering every
;; character exactly once, in order — the contract tui:text-edit-set-
;; highlighter! requires (see its doc comment in src/lisp/modules/tui.cr).
(define (lisp-highlight-line line)
  (reverse (highlight-scan line 0 (string-length line) '())))

(define (highlight-scan line i len acc)
  (if (>= i len)
      acc
      (let ((c (string-ref line i)))
        (cond
          ((char-space? c)
           (let ((j (scan-while line i len char-space?)))
             (highlight-scan line j len (cons (cons (substring line i j) #f) acc))))
          ((or (char-open? c) (char-close? c))
           (highlight-scan line (+ i 1) len (cons (cons (substring line i (+ i 1)) paren-style) acc)))
          ((char-quote? c)
           (let ((j (scan-string-end line (+ i 1) len)))
             (highlight-scan line j len (cons (cons (substring line i j) string-style) acc))))
          (else
           (let* ((j (scan-while line i len atom-char?))
                  (tok (substring line i j)))
             (highlight-scan line j len (cons (cons tok (token-style tok)) acc))))))))

;; Rebuilds the input pane around fresh text, keeping `bottom-pane` and
;; the vstack's own hosted widget pointed at the same TextEdit object —
;; tui:text-edit-value always needs to read whatever is currently loaded.
(define (load-input! text)
  (set! bottom-pane (tui:text-edit text))
  (tui:text-edit-set-highlighter! bottom-pane lisp-highlight-line)
  (tui:vstack-set-bottom! vstack bottom-pane))

(define top-title-fn
  (lambda () (string-append "Try Lisp - " (lesson-title (current-lesson)))))

(define top-content-size-fn
  (lambda () (+ 4 (length log-lines))))

(define top-render-fn
  (lambda (buf)
    (define lesson (current-lesson))
    (tui:buffer-set! buf 0 0 (lesson-title lesson))
    (tui:buffer-set! buf 1 0 (lesson-desc lesson))
    (tui:buffer-set! buf 2 0 (string-append "code: " (lesson-code lesson)))
    (tui:buffer-set! buf 3 0 "----------------------------------------")
    (for-each
      (lambda (i) (tui:buffer-set! buf (+ 4 i) 0 (list-ref log-lines i)))
      (range 0 (length log-lines)))))

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
  (tui:make-scrollable top-title-fn top-content-size-fn top-render-fn top-handle-key-fn top-status-hint-fn))

(define screen (tui:screen))
(set! bottom-pane (tui:text-edit (lesson-code (current-lesson))))
(tui:text-edit-set-highlighter! bottom-pane lisp-highlight-line)
(set! vstack (tui:vstack screen top-pane bottom-pane 8))

(tui:run screen vstack
  (lambda (ev)
    (define key (cdr (assoc "key" ev)))
    (cond
      ((string=? key "esc") (exit))
      ((string=? key "ctrl_x")
       (log-append! (string-append "> " (tui:text-edit-value bottom-pane)))
       (log-append! (eval-result-line (eval-string (tui:text-edit-value bottom-pane))))
       (load-input! "")
       #t)
      (else (tui:handle-key! vstack ev)))))
