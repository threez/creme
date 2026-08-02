;; ===========================================================================
;; (creme bench): timing/profiling a thunk, and terminal/HTML report plumbing
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme sxql)/(creme extra) use) rather than compiled into the interpreter
;; binary, since every export here is expressible in plain R7RS with no
;; opaque foreign object, stateful handle, or third-party Crystal library
;; involved — see modules/creme/extra.sld's own header comment for the same
;; rationale. Imports (creme prof) for its profiling helpers, so — unlike
;; every other file-based (creme ...) library — this one is NOT available on
;; musl/Alpine builds (see src/creme/modules/creme/prof_native.cr's header
;; comment): any script that (import (creme bench)) at all, even one that
;; never calls a profiling export, pulls in (creme prof)'s prof-native half
;; transitively.
;;
;; ---- timing ---------------------------------------------------------------
;;   (benchmark name thunk)                  -> times one call, as data
;;   (repeat-count seconds target-seconds)   -> how many reps hit target-seconds
;;   (run-repeated thunk n)                  -> calls thunk n times
;;   (calibrate name thunk target-seconds)   -> benchmark + repeat-count combined
;;
;; ---- terminal/HTML report plumbing -----------------------------------------
;;   (bench-table->string headers rows aligns [footer-count])
;;   (bench-table->html headers rows aligns [footer-count])
;;   report-css                              -> shared report CSS string
;;   (bench-document->html title body-html)  -> a full HTML document string
;;   (write-html-report path title body-html)
;;
;; ---- profiling --------------------------------------------------------
;;   (profile-workload name thunk target-seconds step-interval)
;;     -> calibrates, then profiles a repeated run of thunk with BOTH of
;;        (creme prof)'s samplers nested in one execution (see
;;        profile-workload's own doc comment for why), returning a result
;;        alist.
;;   (profile-top-rows report n) / (profile-scheme-top-rows report n)
;;     -> profile-top/profile-scheme-top entries turned into table rows.
;;   (profile-report->string workload-result) -> the two-table (hot Scheme
;;     functions, hot Crystal frames) terminal report for one workload.
;;   (profile-report->html workload-result) -> the same two tables as one
;;     HTML fragment.
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme bench)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme bench)
  (export benchmark repeat-count run-repeated calibrate
          bench-table->string bench-table->html
          report-css bench-document->html write-html-report
          profile-workload profile-top-rows profile-scheme-top-rows
          profile-report->string profile-report->html
          short-name truncate-str relativize location-str)
  (import (scheme base) (scheme write) (scheme inexact) (scheme time)
          (creme table) (creme html) (creme file) (creme prof)
          (creme numfmt) (creme string))
  (begin
    ;; ---- timing -------------------------------------------------------------

    ;; (benchmark name thunk) -> (("name" . name) ("result" . result)
    ;; ("seconds" . elapsed)) — times one call of thunk via current-second,
    ;; the same primitive bench/workloads.scm's own timed-run uses, just
    ;; returned as data instead of immediately printed.
    (define (benchmark name thunk)
      (let* ((start (current-second))
             (result (thunk))
             (elapsed (- (current-second) start)))
        (list (cons "name" name) (cons "result" result) (cons "seconds" elapsed))))

    ;; How many times to repeat a `seconds`-long call to run for roughly
    ;; `target-seconds` total — at least 1, even if a single call already
    ;; exceeds target-seconds.
    (define (repeat-count seconds target-seconds)
      (max 1 (exact (truncate (/ target-seconds seconds)))))

    ;; Calls thunk n times in a row, discarding each result — the driving
    ;; loop for a calibrated repeated run (e.g. under a profiler).
    (define (run-repeated thunk n)
      (let loop ((i 0))
        (if (< i n)
            (begin (thunk) (loop (+ i 1))))))

    ;; (calibrate name thunk target-seconds) -> a benchmark result alist
    ;; plus a ("repeat" . n) entry: times one call, then computes how many
    ;; repeats of that same call would take roughly target-seconds — the
    ;; setup step any repeated/profiled run needs before it can run thunk
    ;; a fixed number of times.
    (define (calibrate name thunk target-seconds)
      (let* ((result (benchmark name thunk))
             (seconds (cdr (assoc "seconds" result string=?))))
        (append result (list (cons "repeat" (repeat-count seconds target-seconds))))))

    ;; ---- terminal/HTML report plumbing -----------------------------------------

    ;; (bench-table->string headers rows aligns [footer-count]) -> a bordered
    ;; terminal table string, headers as the (single) header row and an
    ;; optional trailing footer-count rows separated like the header.
    (define bench-table->string
      (case-lambda
        ((headers rows aligns) (bench-table->string headers rows aligns 0))
        ((headers rows aligns footer-count)
         (table->string (cons headers rows) aligns
                         (table-style bordered-style 'header 1 'footer footer-count)))))

    ;; Same shape as bench-table->string, but renders a real <table> (via
    ;; (creme html)'s html-style) and returns the fragment string.
    (define bench-table->html
      (case-lambda
        ((headers rows aligns) (bench-table->html headers rows aligns 0))
        ((headers rows aligns footer-count)
         (table->string (cons headers rows) aligns
                         (table-style html-style 'header 1 'footer footer-count)))))

    ;; Shared look for any report written via bench-document->html /
    ;; write-html-report.
    (define report-css "
  body { font-family: -apple-system, sans-serif; margin: 2rem; }
  table { border-collapse: collapse; margin-bottom: 1.5rem; }
  th, td { border: 1px solid #ccc; padding: 0.3rem 0.6rem; }
  th { background: #eee; text-align: left; }
  td { font-family: ui-monospace, monospace; text-align: right; }
  td:first-child { font-family: inherit; text-align: left; }
  tfoot td { font-weight: bold; }
  h2 { margin-top: 2rem; }
")

    ;; (bench-document->html title body-html) -> a full HTML document string
    ;; wrapping the already-rendered body-html fragment with report-css.
    ;; html-document->string's `body` is a NODE spliced directly into its own
    ;; quasiquoted document tree (`(body ,body)`), not a port-writer thunk —
    ;; `(raw body-html)` embeds body-html's already-rendered markup verbatim,
    ;; matching html-render's own `(raw ...)` grammar case (see
    ;; modules/creme/html.sld). A bare lambda here used to reach html-render
    ;; as if it were a child node and fail with "invalid node".
    (define (bench-document->html title body-html)
      (html-document->string title report-css (list 'raw body-html)))

    ;; (write-html-report path title body-html) -> writes a full HTML
    ;; document (see bench-document->html) to path.
    (define (write-html-report path title body-html)
      (file-write path (bench-document->html title body-html)))

    ;; ---- profiling --------------------------------------------------------

    (define (field entry key) (cdr (assoc key entry string=?)))

    (define (index-min a b)
      (cond ((and a b) (if (< a b) a b))
            (a a)
            (else b)))

    ;; Crystal's mangled symbol for a generic method/container instantiated
    ;; over the big SchemeValue union includes the ENTIRE union inline — as
    ;; a generic type argument ("name<(A | B | ...), ...>"), a return type
    ;; ("name:(A | B | ...)"), or baked into a container type ("Array(A | B
    ;; | ...)@..." ) — unreadable either way. Trim at the first "<" or ":("
    ;; when present, then hard-truncate anything still long (catches the
    ;; Array(...)/Proc(...) case, which has no "<"/":(" marker to cut at).
    (define (short-name name)
      (let* ((cut (index-min (string-index-of name "<") (string-index-of name ":(")))
             (trimmed (if cut (substring name 0 cut) name)))
        (if (> (string-length trimmed) 60)
            (string-append (substring trimmed 0 60) "…")
            trimmed)))

    ;; Reconstructed Scheme source text (e.g. "(+ (fib (- n 1)) (fib (- n
    ;; 2)))") is legible as-is, unlike Crystal's mangled names, but a call
    ;; site with large nested arguments can still run long — just a flat
    ;; length cap, no need for short-name's "<"/":(" splitting (that's
    ;; specific to Crystal generic syntax).
    (define (truncate-str s n)
      (if (> (string-length s) n)
          (string-append (substring s 0 n) "…")
          s))

    ;; (creme prof)'s reported file paths mix conventions by construction:
    ;; the top-level script's own forms report whatever path it was invoked
    ;; with (relative, when run as `./bin/creme some-script.scm`), while an
    ;; (include)d file's forms always report a fully resolved absolute path
    ;; (see src/creme/eval/import.cr's read_include_file) — an intentional
    ;; difference elsewhere in the interpreter (matters for backtrace/error-
    ;; reporting invariants), not something a profiling report's
    ;; presentation should surface. Strip the current working directory
    ;; prefix so every location a report shows reads relative, consistently.
    (define cwd (current-directory))
    (define cwd-prefix (string-append cwd "/"))
    (define (relativize path)
      (if (string-prefix? path cwd-prefix)
          (substring path (string-length cwd-prefix) (string-length path))
          path))

    ;; "file:line", relativized, or "" when unavailable.
    (define (location-str entry)
      (let ((file (field entry "file"))
            (line (field entry "line")))
        (if file (string-append (relativize file) ":" (number->string line)) "")))

    ;; Turns (profile-top report n)'s alist-per-frame list into table->string
    ;; rows, numbering each from 1.
    (define (profile-top-rows report n)
      (let loop ((i 1) (es (profile-top report n)) (acc '()))
        (if (null? es)
            (reverse acc)
            (let ((entry (car es)))
              (loop (+ i 1) (cdr es)
                    (cons (list (number->string i)
                                (numfmt-fixed (field entry "percent") 1)
                                (number->string (field entry "count"))
                                (short-name (field entry "name"))
                                (location-str entry))
                          acc))))))

    ;; Same shape as profile-top-rows, but for profile-scheme-top's entries
    ;; — "name" is reconstructed Scheme source (see Interpreter#
    ;; expression_label), not a Crystal frame, so it's truncate-str'd rather
    ;; than short-name'd. "instruction" is the KIND of thing it is in the
    ;; language's own syntax (see Interpreter#instruction_label), e.g.
    ;; "if"/"let*"/"call"/"+".
    (define (profile-scheme-top-rows report n)
      (let loop ((i 1) (es (profile-scheme-top report n)) (acc '()))
        (if (null? es)
            (reverse acc)
            (let ((entry (car es)))
              (loop (+ i 1) (cdr es)
                    (cons (list (number->string i)
                                (numfmt-fixed (field entry "percent") 1)
                                (number->string (field entry "count"))
                                (field entry "instruction")
                                (truncate-str (field entry "name") 55)
                                (location-str entry))
                          acc))))))

    ;; (profile-workload name thunk target-seconds step-interval) -> a
    ;; calibrate result (see calibrate above) plus "scheme-report"/
    ;; "crystal-report"/"scheme-total"/"crystal-total" entries. Both of
    ;; (creme prof)'s samplers run over the SAME single repeated execution,
    ;; not two separate runs: the Crystal-level SIGPROF timer and the
    ;; interpreter's step-counted cooperative sampler are independent
    ;; mechanisms (one wall-clock-driven, one trampoline-step-driven) that
    ;; don't interfere, so profile-scheme is simply nested inside profile's
    ;; thunk — this halves the wall time versus profiling twice, and means
    ;; the two reports describe literally the same run.
    (define (profile-workload name thunk target-seconds step-interval)
      (let* ((calibrated (calibrate name thunk target-seconds))
             (repeat (cdr (assoc "repeat" calibrated string=?)))
             (scheme-report #f)
             (crystal-report
              (profile (lambda ()
                         (set! scheme-report
                               (profile-scheme (lambda () (run-repeated thunk repeat)) step-interval))))))
        (append calibrated
                (list (cons "scheme-report" scheme-report)
                      (cons "crystal-report" crystal-report)
                      (cons "scheme-total" (profile-scheme-total-samples scheme-report))
                      (cons "crystal-total" (profile-total-samples crystal-report))))))

    (define profile-scheme-headers (list "#" "%" "count" "instruction" "expression" "location"))
    (define profile-scheme-aligns (list 'right 'right 'right 'left 'left 'left))
    (define profile-crystal-headers (list "#" "%" "count" "frame" "location"))
    (define profile-crystal-aligns (list 'right 'right 'right 'left 'left))

    ;; The full two-table (hot Scheme functions, hot Crystal frames)
    ;; terminal report for one profile-workload result.
    (define (profile-report->string workload-result)
      (let ((name (cdr (assoc "name" workload-result string=?)))
            (repeat (cdr (assoc "repeat" workload-result string=?)))
            (scheme-report (cdr (assoc "scheme-report" workload-result string=?)))
            (crystal-report (cdr (assoc "crystal-report" workload-result string=?)))
            (scheme-total (cdr (assoc "scheme-total" workload-result string=?)))
            (crystal-total (cdr (assoc "crystal-total" workload-result string=?))))
        (string-append
         name "  (x" (number->string repeat) ")\n"
         "hot Scheme functions (" (number->string scheme-total) " samples)\n"
         (bench-table->string profile-scheme-headers
                               (profile-scheme-top-rows scheme-report 10)
                               profile-scheme-aligns)
         "\n"
         "hot Crystal frames (" (number->string crystal-total) " samples)\n"
         (bench-table->string profile-crystal-headers
                               (profile-top-rows crystal-report 15)
                               profile-crystal-aligns)
         "\n")))

    ;; The same two tables as profile-report->string, as one HTML fragment
    ;; (a heading plus each table).
    (define (profile-report->html workload-result)
      (let ((name (cdr (assoc "name" workload-result string=?)))
            (repeat (cdr (assoc "repeat" workload-result string=?)))
            (scheme-report (cdr (assoc "scheme-report" workload-result string=?)))
            (crystal-report (cdr (assoc "crystal-report" workload-result string=?))))
        (string-append
         "<h2>" (html-escape name) " (x" (number->string repeat) ")</h2>\n"
         "<h3>hot Scheme functions</h3>\n"
         (bench-table->html profile-scheme-headers
                             (profile-scheme-top-rows scheme-report 10)
                             profile-scheme-aligns)
         "\n<h3>hot Crystal frames</h3>\n"
         (bench-table->html profile-crystal-headers
                             (profile-top-rows crystal-report 15)
                             profile-crystal-aligns))))))
