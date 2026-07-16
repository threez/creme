; bench/prof.scm — Scheme-native equivalent of bench/profile.cr (removed):
; profiles each bench workload separately via (creme bench), printing two
; bordered tables per workload — hot Crystal frames (via prof.cr's SIGPROF
; sampler) and hot Scheme functions (via the interpreter's own cooperative
; sampler). Pass --html to also write the same report as bench/prof.html
; (skipped by default — most runs just want the terminal tables, and
; building/writing the HTML is wasted work otherwise).
;
; The actual timing/profiling/rendering logic lives in (creme bench) — this
; script is just workload registration plus wiring the results into a
; terminal report and, optionally, an HTML one, mirroring the terminal-and-
; HTML duality bench/bench.scm already has for its own cross-language
; comparison.
;
; Run: ./bin/creme bench/prof.scm [--html]  (not --release, so frame
; file/line resolve — prof.cr strips debug info requirements under
; --release, per its own docs). Run with -h/--help for the full flag list
; (see (creme cli), modules/creme/cli.sld). (creme bench) imports (creme
; prof) — modules/creme/prof.sld's own frontend combining (creme prof-native)
; and (creme prof-vm) — and prof-native isn't available on musl/Alpine builds
; (see src/scheme/modules/creme/prof_native.cr's header comment) — this
; script (and any other importer of (creme bench), including
; bench/bench.scm) will fail to import there.
;
; Not wired into `make bench` or CI — a one-off investigative tool.

(import (scheme base) (scheme write) (scheme inexact) (scheme time)
        (creme bench) (creme cli))

(define opts
  (cli "Profile the bench workloads"
       (list (flag "html" "--html" "Also write bench/prof.html"))))

(include "workloads.scm")

(define workloads
  (list (cons "fib" (lambda () (fib 27)))
        (cons "sum-to" (lambda () (sum-to 2000000 0)))
        (cons "build-list" (lambda () (length (reverse (build-list 200000)))))
        (cons "vector-sum-test" (lambda () (vector-sum-test 500000)))
        (cons "string-build-test" (lambda () (string-build-test 4000)))))

(define target-seconds 1.5)
(define step-interval 200)
(define want-html? (cli-flag? opts "html"))

(define html-fragments
  (map (lambda (workload)
         (let ((result (profile-workload (car workload) (cdr workload) target-seconds step-interval)))
           (display (profile-report->string result))
           (newline)
           (if want-html? (profile-report->html result) "")))
       workloads))

(if want-html?
    (begin
      (write-html-report
       "bench/prof.html" "creme prof"
       (string-append
        "<p>Profiled at a target of " (number->string target-seconds)
        "s per workload, step-interval " (number->string step-interval) ".</p>"
        (apply string-append html-fragments)))
      (display "wrote bench/prof.html")
      (newline)))
