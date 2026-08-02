;; ===========================================================================
;; (creme escm): a minimal ERB-style template compiler for embedded Scheme
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme xml)/(creme matrix) use) since every export here is expressible
;; in plain R7RS over (scheme eval)'s eval/environment and (creme
;; scanner)'s port-scanning primitives, with no opaque foreign object or
;; third-party Crystal library of its own involved.
;;
;; Three template constructs, same `<% %>`/`<%= %>` syntax as Ruby's ERB
;; (hence the style, not the name -- this embeds Scheme, not Ruby, so
;; every export here is `escm-`-prefixed, never `erb-`):
;;   <% ... %>    a silent Scheme code block (one or more top-level
;;                forms, evaluated in sequence for effect only)
;;   <%= ... %>   a single Scheme expression, `display`ed into the
;;                output -- UNESCAPED, matching real ERB's own default
;;                (not Rails' separate auto-escaping wrapper); a
;;                template embedding untrusted data as HTML should
;;                escape it itself via (creme html)'s html-escape or
;;                (creme cgi)'s cgi-escape-html before interpolating
;;   everything else is passed through as literal text, verbatim
;;
;;   (escm-compile template)         -> parses template once into an
;;                                     opaque compiled-template value:
;;                                     scans it into alternating text/
;;                                     code/expr segments (via (creme
;;                                     scanner)), and for each code/expr
;;                                     segment, `read`s its Scheme source
;;                                     text into real data AT COMPILE
;;                                     TIME (so a template with a syntax
;;                                     error in its embedded Scheme fails
;;                                     at escm-compile, not buried inside
;;                                     a later render) -- a <% %> block's
;;                                     text may hold more than one
;;                                     top-level form (each read and
;;                                     evaluated as its own statement);
;;                                     a <%= %> block must hold exactly
;;                                     one expression
;;   (escm-render compiled locals)   -> renders a compiled template
;;                                     against locals, an alist of
;;                                     (symbol . value) pairs, returning
;;                                     the rendered string. Rather than
;;                                     statically analyzing which local
;;                                     names a template body actually
;;                                     references (unnecessary
;;                                     complexity for this library's
;;                                     scope), each render installs every
;;                                     locals entry as a top-level
;;                                     `define` in a FRESH (scheme eval)
;;                                     environment (so one compiled
;;                                     template can be safely rendered
;;                                     repeatedly, or concurrently,
;;                                     without one render's locals
;;                                     leaking into another's), then
;;                                     evaluates each segment's
;;                                     already-parsed forms in that
;;                                     environment, `display`-capturing
;;                                     text/expr output via
;;                                     `parameterize`d current-output-port
;;                                     into a string port -- the same
;;                                     "capture printed output while
;;                                     evaluating" idiom this project's
;;                                     own README already documents
;;                                     (examples/24-tui-try-scheme.scm's
;;                                     eval-source-line), reused rather
;;                                     than reinvented
;;   (escm-render-string template locals)  -> (escm-render (escm-compile
;;                                     template) locals) in one call, for
;;                                     a one-shot render that doesn't
;;                                     need the compiled value again
;;
;; Native `bin/creme` only -- `icecreme/icecreme`'s `(scheme eval)` `environment`
;; procedure isn't fully wired for plain script execution (it errors
;; with "unbound variable: import-set-resolved-bindings", a self-hosted-
;; compiler-only helper per icecreme/README.md), so escm-render doesn't work
;; unmodified there; not addressed here since fixing it is an icecreme/(scheme
;; eval) change, out of this library's own scope.
;;
;; Limitations: no `<%-`/`-%>` whitespace-trimming directives; no
;; partial/include mechanism (a template can't pull in another template
;; by name); locals are re-installed via `eval` on every escm-render call
;; rather than compiled once into a closure over fixed argument
;; positions -- an explicit, stated perf/complexity tradeoff (a template
;; rendered thousands of times in a hot loop pays eval's own overhead
;; every time), not an oversight.
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme escm)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme escm)
  (export escm-compile escm-render escm-render-string)
  (import (scheme base) (scheme write) (scheme read) (scheme eval) (creme scanner))
  (begin
    (define-record-type <escm-template>
      (make-escm-template segments)
      escm-template?
      (segments escm-template-segments))

    ;; Scans up to (not including) the closing "%>", consuming it; a "%"
    ;; not immediately followed by ">" is ordinary content and kept.
    (define (escm-priv-scan-until-close port)
      (let ((out (open-output-string)))
        (let loop ()
          (let* ((r (scan-until-char port (lambda (c) (char=? c #\%))))
                 (text (car r))
                 (term (cdr r)))
            (write-string text out)
            (if (not term)
                (error "escm-compile: unterminated <% ... %>")
                (let ((c2 (peek-char port)))
                  (if (and (char? c2) (char=? c2 #\>))
                      (begin (read-char port) (get-output-string out))
                      (begin (write-char #\% out) (loop)))))))))

    ;; Scans the whole template into a list of (text "...") / (code
    ;; "...") / (expr "...") segments, each still holding raw text at
    ;; this stage (parsed into real data by escm-priv-finalize-segment).
    (define (escm-priv-scan-all port)
      (let loop ((acc '()))
        (let* ((r (scan-until-char port (lambda (c) (char=? c #\<))))
               (text (car r))
               (term (cdr r))
               (acc2 (if (> (string-length text) 0) (cons (list 'text text) acc) acc)))
          (cond
           ((not term) (reverse acc2))
           (else
            (let ((c2 (peek-char port)))
              (if (and (char? c2) (char=? c2 #\%))
                  (begin
                    (read-char port)
                    (let ((is-expr? (and (char? (peek-char port)) (char=? (peek-char port) #\=))))
                      (if is-expr? (read-char port))
                      (let ((body (escm-priv-scan-until-close port)))
                        (loop (cons (list (if is-expr? 'expr 'code) body) acc2)))))
                  (loop (cons (list 'text "<") acc2)))))))))

    (define (escm-priv-read-all s)
      (let ((in (open-input-string s)))
        (let loop ((acc '()))
          (let ((d (read in)))
            (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))

    (define (escm-priv-finalize-segment seg)
      (let ((tag (car seg)) (content (cadr seg)))
        (cond
         ((eq? tag 'text) seg)
         ((eq? tag 'code) (list 'code (escm-priv-read-all content)))
         (else
          (let ((forms (escm-priv-read-all content)))
            (if (null? forms) (error "escm-compile: empty <%= %>"))
            (list 'expr (car forms)))))))

    (define (escm-compile template)
      (make-escm-template (map escm-priv-finalize-segment (escm-priv-scan-all (open-input-string template)))))

    (define (escm-render compiled locals)
      (let ((env (environment '(scheme base) '(scheme write))))
        (for-each (lambda (kv) (eval (list 'define (car kv) (list 'quote (cdr kv))) env)) locals)
        (let ((out (open-output-string)))
          (parameterize ((current-output-port out))
            (for-each
             (lambda (seg)
               (let ((tag (car seg)) (content (cadr seg)))
                 (cond
                  ((eq? tag 'text) (display content))
                  ((eq? tag 'code) (for-each (lambda (form) (eval form env)) content))
                  (else (display (eval content env))))))
             (escm-template-segments compiled)))
          (get-output-string out))))

    (define (escm-render-string template locals) (escm-render (escm-compile template) locals))))
