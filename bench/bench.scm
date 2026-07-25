; Shells out to all 6 comparison variants the same way and prints a combined
; cross-language table:
;
;   - bin/creme, this same interpreter, running bench/creme.scm
;     (build once: shards build --release --no-debug)
;   - bench/bench.cr, a native, unmodified-code Crystal reference floor
;     (build once: crystal build --release bench/bench.cr -o bin/bench_cr)
;   - bench/bench.go, the same 7 workloads under native Go, a second
;     compiled-code floor (build once: go build -o bin/bench_go bench/bench.go)
;   - bench/bench.rb, the same 7 workloads under Ruby (MRI)
;   - bench/racket.scm, the same 7 workloads under Racket's #lang r7rs
;   - bench/guile.scm, the same 7 workloads under GNU Guile (run with --r7rs)
;   - bench/bench.js, the same 7 workloads under Node.js (V8)
;   - cvm/cvm, the standalone C11 prototype VM in cvm/ (see cvm/README.md —
;     a narrow experiment scoped to exactly bench/creme.scm, not a general
;     Scheme runtime), compiling and running bench/creme.scm itself through
;     its own self-hosted (creme compiler compiler) -- a genuinely
;     independent compile of the same source, not the bytecode creme's own
;     column runs (build once: make -C cvm; this script regenerates
;     cvm/compiler-run.cvmc, the precompiled self-hosted-compiler image
;     cvm's compiler mode depends on, on every run -- see
;     ensure-cvm-compiler-image! below, cheap enough (~0.15s) not to bother
;     with a staleness check spanning every .sld the compiler bundles)
;
; Each variant is optional: if its command isn't found (or exits non-zero),
; that column falls back to "n/a" instead of raising, so this script — and
; `make bench`, and the "runs end to end" integration spec that exercises it —
; stay green on a machine that doesn't have ruby/racket installed or hasn't
; built bin/creme/bin/bench_cr yet.
;
; This is a single-run comparison, not a best-of-N — rerun `make bench` a
; few times by hand and eyeball the spread if you want to filter out noise.
;
; Pass --html to also write the same report as bench/bench.html (skipped by
; default — most runs just want the terminal table, and building/writing
; the HTML is wasted work otherwise). Run with -h/--help for the full flag
; list (see (creme cli), modules/creme/cli.sld).
;
; (creme bench) (used below only for its table/HTML report helpers) also
; imports (creme prof) for its profiling helpers, so this script — like
; anything else importing (creme bench) — isn't importable on musl/Alpine
; builds (see src/scheme/modules/creme/prof_native.cr's header comment).

(import (scheme base) (scheme write) (scheme cxr) (creme process) (creme regex)
        (creme string) (creme numfmt) (creme bench) (creme cli))

(define opts
  (cli "Cross-language benchmark comparison"
       (list (flag "html" "--html" "Also write bench/bench.html"))))

; ---- run the 5 comparison variants -----------------------------------------

(define (run-variant cmd args)
  (guard (e (#t #f))
    (let* ((result (process-run cmd args))
           (out (car result))
           (success (cadddr result)))
      (if success out #f))))

(define creme-output (run-variant "bin/creme" (list "bench/creme.scm")))
(define crystal-output (run-variant "bin/bench_cr" '()))
(define go-output (run-variant "bin/bench_go" '()))
(define ruby-output (run-variant "ruby" (list "bench/bench.rb")))
(define racket-output (run-variant "racket" (list "bench/racket.scm")))
(define guile-output (run-variant "guile" (list "--r7rs" "bench/guile.scm")))
(define node-output (run-variant "node" (list "bench/bench.js")))

; Regenerates cvm/compiler-run.cvmc (the precompiled self-hosted-compiler
; image cvm's own compiler mode depends on to run a plain .scm file
; directly, see cvm/compiler-run.scm) unconditionally every run rather than
; tracking a staleness check across every .sld it bundles (reader.sld,
; bytecode.sld, compiler.sld, ...) -- ~0.15s, cheap enough not to bother.
; Best-effort like every other variant here: if bin/creme or cvm/cvm aren't
; built yet, this (and then cvm-output below) just falls back to n/a.
(run-variant "bin/creme" (list "--emit-cvm" "cvm/compiler-run.scm" "cvm/compiler-run.cvmc"))
(define cvm-output (run-variant "cvm/cvm" (list "bench/creme.scm")))

; ---- parse "<label> = <result>  (<elapsed>s)" / "total = <elapsed>s" -------

(define (parse-elapsed-alist text)
  (if (not text)
      '()
      ; Elapsed times are usually fixed-point ("0.00023s"), but a fast enough
      ; workload/variant (e.g. a builder-based string-build-test under
      ; native Crystal) can print in scientific notation ("3.19e-05s") —
      ; match both so a sub-fixed-point result doesn't silently become n/a.
      (let* ((per-line-rx (regexp "([^=\n]+) = [^\n]*\\(([0-9.]+(?:e-?[0-9]+)?)s\\)"))
             (total-rx (regexp "total = ([0-9.]+(?:e-?[0-9]+)?)s"))
             (per-line (map (lambda (m) (cons (string-trim (cadr m)) (string->number (caddr m))))
                             (regexp-extract per-line-rx text)))
             (totals (regexp-extract total-rx text))
             (total (if (null? totals) '() (list (cons "total" (string->number (cadr (car totals))))))))
        (append per-line total))))

(define crystal-times (parse-elapsed-alist crystal-output))
(define go-times (parse-elapsed-alist go-output))
(define racket-times (parse-elapsed-alist racket-output))
(define ruby-times (parse-elapsed-alist ruby-output))
(define guile-times (parse-elapsed-alist guile-output))
(define node-times (parse-elapsed-alist node-output))
(define creme-times (parse-elapsed-alist creme-output))
(define cvm-times (parse-elapsed-alist cvm-output))

; ---- build the two tables ---------------------------------------------------
;
; Table 1 ("measurements") is the raw per-workload elapsed seconds, one
; column per variant, nothing derived.
;
; Table 2 ("comparison matrix") turns EVERY variant into both a row and a
; column, cell[row][col] = row's total time / column's total time — reading
; along a row answers "how many times slower is this variant than each of
; the others", for every pair at once, not just the handful of ratios
; anchored to creme/crystal a single flat table could fit before. Built from
; each variant's aggregate "total" line (not per-workload) so the matrix
; stays one NxN table instead of 7 of them.

(define (lookup label alist)
  (let ((pair (assoc label alist string=?)))
    (if pair (cdr pair) #f)))

(define workloads
  (list "fib(27)" "sum-to(2000000)" "build-list(200000) length+reverse"
        "vector-sum-test(500000)" "string-build-test(4000) length"
        "tak(18,12,6)" "nqueens(9)" "total"))

(define variant-names (list "crystal" "go" "racket" "ruby" "guile" "node" "creme" "cvm"))

(define variant-times
  (list (cons "crystal" crystal-times) (cons "go" go-times) (cons "racket" racket-times)
        (cons "ruby" ruby-times) (cons "guile" guile-times) (cons "node" node-times)
        (cons "creme" creme-times) (cons "cvm" cvm-times)))

(define (times-of variant) (lookup variant variant-times))
(define (total-of variant) (lookup "total" (times-of variant)))

; ---- table 1: measurements ---------------------------------------------------

(define measurement-headers (cons "workload" variant-names))
(define measurement-aligns (cons 'left (map (lambda (v) 'right) variant-names)))

(define measurement-rows
  (map (lambda (label)
         (cons label (map (lambda (v) (numfmt-fixed (lookup label (times-of v)) 5)) variant-names)))
       workloads))

; ---- table 2: comparison matrix (row / column, on total time) --------------

(define matrix-headers (cons "" variant-names))
(define matrix-aligns (cons 'left (map (lambda (v) 'right) variant-names)))

(define matrix-rows
  (map (lambda (row-name)
         (cons row-name
               (map (lambda (col-name)
                      (if (string=? row-name col-name)
                          "-"
                          (numfmt-ratio (total-of row-name) (total-of col-name))))
                    variant-names)))
       variant-names))

; ---- print both tables -------------------------------------------------------

(display "measurements (seconds)\n")
(display (bench-table->string measurement-headers measurement-rows measurement-aligns 1))
(newline)
(display "comparison matrix (row's total time / column's total time — e.g. the \"creme\" row's \"crystal\" column is how many times slower creme is than crystal)\n")
(display (bench-table->string matrix-headers matrix-rows matrix-aligns 0))
(newline)

; ---- optionally also write bench/bench.html --------------------------------

(if (cli-flag? opts "html")
    (begin
      (write-html-report "bench/bench.html" "creme bench"
                          (string-append
                           "<h2>measurements (seconds)</h2>\n"
                           (bench-table->html measurement-headers measurement-rows measurement-aligns 1)
                           "<h2>comparison matrix</h2>\n"
                           "<p>row's total time / column's total time</p>\n"
                           (bench-table->html matrix-headers matrix-rows matrix-aligns 0)))
      (display "wrote bench/bench.html")
      (newline)))
