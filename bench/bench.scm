; Shells out to all 5 comparison variants the same way and prints a combined
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

; ---- print the table --------------------------------------------------------

(define (lookup label alist)
  (let ((pair (assoc label alist string=?)))
    (if pair (cdr pair) #f)))

(define workloads
  (list "fib(27)" "sum-to(2000000)" "build-list(200000) length+reverse"
        "vector-sum-test(500000)" "string-build-test(4000) length"
        "tak(18,12,6)" "nqueens(9)" "total"))

(define headers
  (list "workload" "crystal" "go" "racket" "ruby" "guile" "node" "creme"
        "creme/crystal" "creme/go" "creme/racket" "creme/ruby" "creme/guile" "creme/node"))

(define aligns
  (list 'left 'right 'right 'right 'right 'right 'right 'right
        'right 'right 'right 'right 'right 'right))

(define data-rows
  (map (lambda (label)
         (let ((c (lookup label crystal-times))
               (go (lookup label go-times))
               (r (lookup label racket-times))
               (rb (lookup label ruby-times))
               (g (lookup label guile-times))
               (n (lookup label node-times))
               (cr (lookup label creme-times)))
           (list label
                 (numfmt-fixed c 5) (numfmt-fixed go 5) (numfmt-fixed r 5)
                 (numfmt-fixed rb 5) (numfmt-fixed g 5) (numfmt-fixed n 5) (numfmt-fixed cr 5)
                 (numfmt-ratio cr c) (numfmt-ratio cr go) (numfmt-ratio cr r)
                 (numfmt-ratio cr rb) (numfmt-ratio cr g) (numfmt-ratio cr n))))
       workloads))

(display (bench-table->string headers data-rows aligns 1))
(newline)

; ---- optionally also write bench/bench.html --------------------------------

(if (cli-flag? opts "html")
    (begin
      (write-html-report "bench/bench.html" "creme bench"
                          (bench-table->html headers data-rows aligns 1))
      (display "wrote bench/bench.html")
      (newline)))
