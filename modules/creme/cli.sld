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
;;   (positional id help)                  -> a required positional argument
;;   (positional id help required?)        -> optional when required? is #f
;;   (command id names help spec ...)      -> a subcommand grouping its own
;;                                             flags/positionals; `names` selects
;;                                             it, `id` (a symbol) is dispatched on
;;   (make-cli description specs)          -> a cli spec, program auto-inferred
;;   (parse-cli cli args)                  -> parses an explicit args list
;;   (cli description specs)               -> make-cli + parse-cli against
;;                                             the live process's own args
;;   (cli-usage cli)                        -> the generated usage string
;;   (cli-flag? opts id) / (cli-get opts id) -> read a parsed value by id
;;   (cli-command opts)                    -> the selected subcommand's id, or #f
;;
;; `specs` is a mixed list of `flag`, `positional`, and `command` declarations.
;; Flags are matched by name anywhere in the args; the remaining (non-`-`-prefixed)
;; args fill the positionals in declaration order. A missing REQUIRED positional,
;; or an extra arg past the last declared positional, raises — same as a bad flag.
;;
;; When a cli declares `command`s, parse-cli treats the FIRST arg as a subcommand
;; selector: it parses the rest against that command's own flags/positionals and
;; `cli-command` reports which was chosen. A leading arg matching no command (or
;; no args) yields `cli-command` => #f and consumes nothing — the caller takes its
;; own default action from the raw args. This is the way to relate flags to one
;; another and describe a multi-mode CLI in a single parse-cli call, e.g.:
;;
;;   (define spec
;;     (make-cli "my tool"
;;       (list (command 'build "build" "Build it"
;;                      (flag "release" "--release" "optimized")
;;                      (positional "target" "what to build"))
;;             (command 'clean "clean" "Remove build output"))))
;;   (case (cli-command (parse-cli spec (cdr (command-line))))
;;     ((build) ...) ((clean) ...) (else ...default...))
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
  (export flag positional command
          make-cli parse-cli cli cli-usage cli-command-lines cli-flag? cli-get cli-command)
  (import (scheme base) (scheme cxr) (scheme write) (scheme process-context)
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

    (define-record-type <cli-positional>
      (make-positional-raw id help required)
      positional-spec?
      (id positional-id)
      (help positional-help)
      (required positional-required))

    ;; (positional id help [required?]) — a positional argument; id doubles as
    ;; its key (cli-get) and its <name> in the usage line. Required by default.
    (define positional
      (case-lambda
        ((id help) (make-positional-raw id help #t))
        ((id help required?) (make-positional-raw id help required?))))

    (define-record-type <cli-command>
      (make-command-raw id names help flags positionals)
      command-spec?
      (id command-id)
      (names command-names)
      (help command-help)
      (flags command-flags)
      (positionals command-positionals))

    ;; (command id names help spec ...) — a subcommand selected when the FIRST
    ;; argument equals any of `names` (a string or list of strings). `id` (a
    ;; symbol) is what cli-command reports for dispatch; `spec ...` are this
    ;; command's own flags and positionals, parsed against the args after the
    ;; selecting token. Group related flags this way rather than spreading them
    ;; across several parse-cli calls.
    (define (command id names help . specs)
      (let loop ((specs specs) (flags '()) (poss '()))
        (cond
          ((null? specs)
           (make-command-raw id (if (pair? names) names (list names)) help
                             (reverse flags) (reverse poss)))
          ((flag-spec? (car specs)) (loop (cdr specs) (cons (car specs) flags) poss))
          ((positional-spec? (car specs)) (loop (cdr specs) flags (cons (car specs) poss)))
          (else (error "cli: bad command spec" (car specs))))))

    (define-record-type <cli>
      (make-cli-raw program description flags positionals commands)
      cli?
      (program cli-program)
      (description cli-description)
      (flags cli-flags)
      (positionals cli-positionals)
      (commands cli-commands))

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

    ;; Splits a mixed spec list into its flag, positional, and command
    ;; declarations, preserving declaration order within each (positionals are
    ;; filled in that order). Avoids depending on a `filter`/`partition` import.
    (define (partition-specs specs)
      (let loop ((specs specs) (flags '()) (poss '()) (cmds '()))
        (cond
          ((null? specs) (list (reverse flags) (reverse poss) (reverse cmds)))
          ((flag-spec? (car specs)) (loop (cdr specs) (cons (car specs) flags) poss cmds))
          ((positional-spec? (car specs)) (loop (cdr specs) flags (cons (car specs) poss) cmds))
          ((command-spec? (car specs)) (loop (cdr specs) flags poss (cons (car specs) cmds)))
          (else (error "cli: not a flag/positional/command spec" (car specs))))))

    (define (build-cli program description specs)
      (let ((parts (partition-specs specs)))
        (make-cli-raw program description (car parts) (cadr parts) (caddr parts))))

    ;; (make-cli description specs) infers the program name from (command-line);
    ;; (make-cli program description specs) sets it explicitly -- use the latter
    ;; for a standalone binary whose command-line's second element is an argument,
    ;; not a script path (so usage reads "<program> <command>", not the arg).
    (define make-cli
      (case-lambda
        ((description specs) (build-cli (inferred-program) description specs))
        ((program description specs) (build-cli program description specs))))

    (define (find-flag-in flags name)
      (let loop ((fs flags))
        (cond ((null? fs) #f)
              ((member name (flag-names (car fs))) (car fs))
              (else (loop (cdr fs))))))

    (define (find-command cli tok)
      (let loop ((cs (cli-commands cli)))
        (cond ((null? cs) #f)
              ((member tok (command-names (car cs))) (car cs))
              (else (loop (cdr cs))))))

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

    (define (looks-like-flag? name)
      (and (> (string-length name) 1) (char=? (string-ref name 0) #\-)))

    ;; Core parse: `args` against an explicit flag+positional set. `usage` is a
    ;; thunk producing the help text shown for -h/--help. Flags are matched by
    ;; name anywhere; the remaining non-flag args fill `positionals` in order. A
    ;; leftover arg past the last positional, an unknown flag, or a missing
    ;; required positional raises. Returns a string-keyed alist.
    (define (parse-specs flags positionals usage args)
      (let loop ((args args)
                 (pos-specs positionals)
                 (result (append
                          (map (lambda (f) (cons (flag-id f) (flag-default f))) flags)
                          (map (lambda (p) (cons (positional-id p) #f)) positionals))))
        (if (null? args)
            (begin
              (for-each
               (lambda (p)
                 (if (and (positional-required p)
                          (not (cdr (assoc (positional-id p) result string=?))))
                     (error "cli: missing required argument" (positional-id p))))
               positionals)
              result)
            (let* ((split (split-eq (car args)))
                   (name (car split))
                   (inline-value (cdr split))
                   (f (find-flag-in flags name)))
              (cond
                ((or (string=? name "-h") (string=? name "--help"))
                 (display (usage)) (newline) (exit 0))
                (f
                 (if (eq? (flag-type f) 'boolean)
                     (loop (cdr args) pos-specs (set-value result (flag-id f) #t))
                     (let* ((rest (cdr args))
                            (raw (or inline-value
                                     (if (null? rest)
                                         (error "cli: missing value for" name)
                                         (car rest))))
                            (rest2 (if (or inline-value (null? rest)) rest (cdr rest))))
                       (loop rest2 pos-specs (set-value result (flag-id f) (coerce raw (flag-type f) name))))))
                ((looks-like-flag? name) (error "cli: unknown flag" name))
                ((pair? pos-specs)
                 (loop (cdr args) (cdr pos-specs)
                       (set-value result (positional-id (car pos-specs)) (car args))))
                (else (error "cli: unexpected argument" (car args))))))))

    ;; (parse-cli cli args) -> a string-keyed alist.
    ;;   * Flat cli (only flags/positionals): the parsed values directly.
    ;;   * cli WITH commands: the FIRST arg selects a command; the result carries
    ;;     ("*command*" . id) plus that command's own parsed flags/positionals.
    ;;     A leading arg matching no command — or no args at all — yields
    ;;     ("*command*" . #f) and consumes nothing, leaving the caller to take
    ;;     its default action from the raw args (see cli-command).
    (define (parse-cli cli args)
      (if (null? (cli-commands cli))
          (parse-specs (cli-flags cli) (cli-positionals cli)
                       (lambda () (cli-usage cli)) args)
          (if (null? args)
              (list (cons "*command*" #f))
              (let ((c (find-command cli (car args))))
                (if c
                    (cons (cons "*command*" (command-id c))
                          (parse-specs (command-flags c) (command-positionals c)
                                       (lambda () (command-usage cli c)) (cdr args)))
                    (list (cons "*command*" #f)))))))

    ;; The selected command's id (a symbol), or #f when the cli has no commands
    ;; or the leading arg matched none.
    (define (cli-command opts)
      (let ((e (assoc "*command*" opts string=?))) (and e (cdr e))))

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
                      ;; Show a "(default: ...)" note only for a typed flag whose
                      ;; default is a real, non-type-default value. A #f default on
                      ;; a typed flag means "unset" -- no note (and never coerce #f
                      ;; through number->string).
                      (if (and (not (eq? (flag-type f) 'boolean))
                               (flag-default f)
                               (not (equal? (flag-default f) (default-for-type (flag-type f)))))
                          (string-append " (default: " (to-display-string (flag-default f)) ")")
                          "")
                      "\n"))

    (define (to-display-string v)
      (cond ((string? v) v)
            ((number? v) (number->string v))
            (else (if v "true" "false"))))

    ;; (cli-usage cli) -> the generated usage string (program + description,
    ;; a "Usage: ..." line, then one line per declared flag plus -h/--help).
    (define (positional-usage-line p)
      (string-append "  " (string-pad-right (positional-id p) 22 " ")
                     (positional-help p)
                     (if (positional-required p) "" " (optional)") "\n"))

    (define (positionals-suffix positionals)
      (apply string-append
             (map (lambda (p) (string-append " <" (positional-id p) ">")) positionals)))

    ;; The "Arguments:" + "Options:" body shared by a flat cli's usage and a
    ;; single command's usage.
    (define (specs-usage positionals flags)
      (string-append
       (if (null? positionals)
           ""
           (string-append
            "Arguments:\n"
            (apply string-append (map positional-usage-line positionals))
            "\n"))
       "Options:\n"
       (apply string-append (map flag-usage-line flags))
       "  " (string-pad-right "-h, --help" 22 " ") "Show this help message\n"))

    (define (command-usage-line c)
      (string-append "  " (string-pad-right (string-join (command-names c) ", ") 22 " ")
                     (command-help c) "\n"))

    ;; The formatted one-line-per-command listing (each command's names + help),
    ;; with no surrounding header -- for a host that embeds the command list in
    ;; its own richer help text (cli-usage does the standard full framing).
    (define (cli-command-lines cli)
      (apply string-append (map command-usage-line (cli-commands cli))))

    ;; Usage for a single subcommand (its own flags/positionals). `prog` is the
    ;; "<program> <command>" invocation, collapsed to just the command name when
    ;; the inferred program IS the command token (e.g. a VM whose command-line's
    ;; second element is the subcommand itself, not a script path).
    (define (command-usage cli c)
      (let* ((cname (car (command-names c)))
             (prog (if (string=? (cli-program cli) cname)
                       cname
                       (string-append (cli-program cli) " " cname))))
        (string-append
         prog " - " (command-help c) "\n\n"
         "Usage: " prog " [options]"
         (positionals-suffix (command-positionals c)) "\n\n"
         (specs-usage (command-positionals c) (command-flags c)))))

    ;; (cli-usage cli) -> the generated usage string: a command listing when the
    ;; cli has subcommands, otherwise the flat program + flags/positionals usage.
    (define (cli-usage cli)
      (if (pair? (cli-commands cli))
          (string-append
           (cli-program cli) " - " (cli-description cli) "\n\n"
           "Usage: " (cli-program cli) " <command> [options]\n\n"
           "Commands:\n"
           (apply string-append (map command-usage-line (cli-commands cli)))
           "  " (string-pad-right "-h, --help" 22 " ") "Show this help message\n")
          (string-append
           (cli-program cli) " - " (cli-description cli) "\n\n"
           "Usage: " (cli-program cli) " [options]"
           (positionals-suffix (cli-positionals cli)) "\n\n"
           (specs-usage (cli-positionals cli) (cli-flags cli)))))

    ;; A boolean flag's value (or any flag's truthiness) by id; #f if the id
    ;; isn't present (e.g. it belongs to a command that wasn't selected).
    (define (cli-flag? opts id)
      (let ((e (assoc id opts string=?))) (and e (cdr e))))

    ;; Any flag's/positional's parsed value by id; #f if the id isn't present.
    (define (cli-get opts id)
      (let ((e (assoc id opts string=?))) (and e (cdr e))))))
