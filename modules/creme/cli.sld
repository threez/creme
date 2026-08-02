;; ===========================================================================
;; (creme cli): declarative command-line flag parsing with auto -h/--help
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme sxql)/(creme extra) use) rather than compiled into the interpreter
;; binary, since every export here is expressible in plain R7RS with no
;; opaque foreign object, stateful handle, or third-party Crystal library
;; involved — see modules/creme/extra.sld's own header comment for the same
;; rationale.
;;
;; Describe each flag as data, then parse (scheme process-context)'s
;; command-line against them in one call:
;;
;;   (import (scheme write) (creme cli))
;;   (define opts
;;     (cli "Profile the bench workloads"
;;          (list (flag "html" "--html" "Also write bench/prof.html")
;;                (flag "step-interval" "--step-interval"
;;                      "Sampling step interval" 'integer 200))))
;;   (if (cli-flag? opts "html") ...)
;;   (display (cli-get opts "step-interval"))
;;
;; `-h`/`--help` need no declaration — they're always recognized, print a
;; usage message generated from the flags above, and (exit 0). An
;; unrecognized flag, or a value flag given a value that doesn't parse as
;; its declared type, raises an error (same as any other user-facing script
;; error in this codebase).
;;
;;   (flag id names help)                 -> a 'boolean flag, default #f
;;   (flag id names help type)             -> a typed flag, type-default value
;;   (flag id names help type default)     -> fully explicit
;;   (make-cli description flags)          -> a cli spec, program auto-inferred
;;   (parse-cli cli args)                  -> parses an explicit args list
;;   (cli description flags)               -> make-cli + parse-cli against
;;                                             the live process's own args
;;   (cli-usage cli)                        -> the generated usage string
;;   (cli-flag? opts id) / (cli-get opts id) -> read a parsed value by id
;;
;; `program` (used in the usage header) is inferred as the second element of
;; (command-line) — the script's own path, per how `creme <script>
;; [args...]` populates it (see src/main.cr/src/creme/modules/process.cr).
;; This assumes the standard "creme SCRIPT [args...]" invocation `cli`/
;; `make-cli` are meant for; a script piped in over stdin (no script-path
;; argument at all) has no such element to infer from.
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme cli)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme cli)
  (export flag make-cli parse-cli cli cli-usage cli-flag? cli-get)
  (import (scheme base) (scheme write) (scheme process-context)
          (creme string))
  (begin
    (define-record-type <cli-flag>
      (make-flag-raw id names type default help)
      flag-spec?
      (id flag-id)
      (names flag-names)
      (type flag-type)
      (default flag-default)
      (help flag-help))

    (define-record-type <cli>
      (make-cli-raw program description flags)
      cli?
      (program cli-program)
      (description cli-description)
      (flags cli-flags))

    (define (default-for-type type)
      (case type
        ((string) "")
        ((integer) 0)
        ((float) 0.0)
        (else #f)))

    ;; (flag id names help [type [default]]) — id/help are strings; names is
    ;; a string or list of strings; type (default 'boolean) is one of
    ;; 'boolean/'string/'integer/'float; default (if omitted) is #f for
    ;; 'boolean, or the type-appropriate default-for-type otherwise.
    (define flag
      (case-lambda
        ((id names help) (flag id names help 'boolean))
        ((id names help type) (flag id names help type (default-for-type type)))
        ((id names help type default)
         (make-flag-raw id (if (pair? names) names (list names)) type default help))))

    ;; The script's own path, per how "creme SCRIPT [args...]" populates
    ;; (command-line) — see this file's header comment. Falls back to
    ;; whatever's actually there when a host other than the real CLI ran
    ;; this script (e.g. embedding Creme.run_file directly, as the spec
    ;; suite's integration tests do, or a REPL) and (command-line) doesn't
    ;; have a second element to match that assumption: the program name
    ;; alone if there's exactly one element, or a placeholder if there's
    ;; none at all.
    (define (inferred-program)
      (let ((cl (command-line)))
        (cond ((and (pair? cl) (pair? (cdr cl))) (cadr cl))
              ((pair? cl) (car cl))
              (else "script"))))

    (define (make-cli description flags)
      (make-cli-raw (inferred-program) description flags))

    (define (find-flag cli name)
      (let loop ((fs (cli-flags cli)))
        (cond ((null? fs) #f)
              ((member name (flag-names (car fs))) (car fs))
              (else (loop (cdr fs))))))

    (define (coerce value type who)
      (case type
        ((integer float)
         (let ((n (string->number value)))
           (if n n (error (string-append "cli: " who ": expected a number, got") value))))
        (else value)))

    ;; Splits "--name=value" into ("--name" . "value"); anything without an
    ;; "=" splits into (arg . #f).
    (define (split-eq arg)
      (let ((i (string-index-of arg "=")))
        (if i
            (cons (substring arg 0 i) (substring arg (+ i 1) (string-length arg)))
            (cons arg #f))))

    ;; (parse-cli cli args) -> a string-keyed alist, one entry per declared
    ;; flag (its id -> the parsed value, or its default if never given).
    (define (parse-cli cli args)
      (let loop ((args args)
                 (result (map (lambda (f) (cons (flag-id f) (flag-default f))) (cli-flags cli))))
        (if (null? args)
            result
            (let* ((split (split-eq (car args)))
                   (name (car split))
                   (inline-value (cdr split)))
              (if (or (string=? name "-h") (string=? name "--help"))
                  (begin (display (cli-usage cli)) (newline) (exit 0))
                  (let ((f (find-flag cli name)))
                    (if (not f)
                        (error "cli: unknown flag" name)
                        (if (eq? (flag-type f) 'boolean)
                            (loop (cdr args) (set-value result (flag-id f) #t))
                            (let* ((rest (cdr args))
                                   (raw (or inline-value
                                            (if (null? rest)
                                                (error "cli: missing value for" name)
                                                (car rest))))
                                   (rest2 (if (or inline-value (null? rest)) rest (cdr rest))))
                              (loop rest2 (set-value result (flag-id f) (coerce raw (flag-type f) name))))))))))))

    (define (set-value alist id value)
      (map (lambda (entry) (if (string=? (car entry) id) (cons id value) entry)) alist))

    ;; Everything after the program name and the script's own path — safe
    ;; even when (command-line) doesn't have both (see inferred-program's
    ;; own doc comment for when that happens).
    (define (script-args)
      (let ((cl (command-line)))
        (if (and (pair? cl) (pair? (cdr cl))) (cddr cl) '())))

    ;; (cli description flags) -> make-cli + parse-cli against the live
    ;; process's own command-line (everything after the program name and
    ;; the script's own path).
    (define (cli description flags)
      (parse-cli (make-cli description flags) (script-args)))

    (define (flag-usage-line f)
      (string-append "  " (string-pad-right (string-join (flag-names f) ", ") 22 " ")
                      (flag-help f)
                      (if (and (not (eq? (flag-type f) 'boolean))
                               (not (equal? (flag-default f) (default-for-type (flag-type f)))))
                          (string-append " (default: " (to-display-string (flag-default f)) ")")
                          "")
                      "\n"))

    (define (to-display-string v)
      (if (string? v) v (number->string v)))

    ;; (cli-usage cli) -> the generated usage string (program + description,
    ;; a "Usage: ..." line, then one line per declared flag plus -h/--help).
    (define (cli-usage cli)
      (string-append
       (cli-program cli) " - " (cli-description cli) "\n\n"
       "Usage: " (cli-program cli) " [options]\n\n"
       "Options:\n"
       (apply string-append (map flag-usage-line (cli-flags cli)))
       "  " (string-pad-right "-h, --help" 22 " ") "Show this help message\n"))

    ;; A boolean flag's value (or any flag's truthiness) by id.
    (define (cli-flag? opts id) (cdr (assoc id opts string=?)))

    ;; Any flag's parsed value by id.
    (define (cli-get opts id) (cdr (assoc id opts string=?)))))
