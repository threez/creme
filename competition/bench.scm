; Build everything both suites below need with `make -C competition build`
; (or `gmake`, on a system whose default `make` isn't already GNU make --
; see competition/Makefile's own header comment) before running this --
; it owns bin/creme, cvm/cvm + its self-hosted-compiler image, both
; suites' native-code comparison floors, and every todo-app twin as real,
; prerequisite-tracked targets, replacing what used to be a mix of ad hoc
; shell freshness checks scattered through the todo-app suite below (see
; each of that suite's own "run-only" comments) and the "build once, by
; hand" comments the per-variant list right below used to carry -- the
; former checked only THAT a binary existed and was newer than its
; source, never HOW it had been built, which is exactly how competition/
; crystal/demo-todo/bin/app once sat unrebuilt for days after a manual,
; non-`--release` build.
;
; Two benchmark suites, one script, run in order:
;
;   1. "bench" -- pure in-process CPU micro-benchmarks (fib/sum-to/build-
;      list/vector-sum-test/hashtable-test/record-test/string-build-test/
;      tak/nqueens, see competition/bench/workloads.scm) across every
;      language runtime this project compares itself against, shelling out to:
;        - bin/creme, this same interpreter, running
;          competition/scheme/bench/creme.scm
;          (build once: shards build --release --no-debug)
;        - competition/crystal/bench/bench.cr, a native, unmodified-code
;          Crystal reference floor
;          (build once: crystal build --release --no-debug
;          competition/crystal/bench/bench.cr -o bin/bench_cr)
;        - competition/go/bench/bench.go, the same 9 workloads under native
;          Go, a second compiled-code floor
;          (build once: go build -o bin/bench_go competition/go/bench/bench.go)
;        - competition/ruby/bench/bench.rb, the same 9 workloads under Ruby (MRI)
;        - competition/racket/bench/racket.scm, the same 9 workloads under
;          Racket's #lang r7rs
;        - competition/guile/bench/guile.scm, the same 9 workloads under GNU
;          Guile (run with --r7rs; invoked as `guile3` on FreeBSD, `guile`
;          everywhere else — this project's own FreeBSD dev environment
;          installs it version-suffixed, with no bare `guile` on PATH; see
;          (runtime)'s own `os` field, used below to pick between them)
;        - competition/node/bench/bench.js, the same 9 workloads under
;          Node.js (V8)
;        - competition/lua/bench/bench.lua, the same 9 workloads under both
;          PUC-Rio Lua (invoked as `lua55` on FreeBSD, `lua` everywhere
;          else — same version-suffixed-binary reasoning as guile3 above)
;          and LuaJIT (one shared source file, run twice — see its own
;          header comment for why Lua's guaranteed proper tail calls let
;          sum-to stay genuinely recursive there, unlike the Ruby/Node
;          columns, and for why LuaJIT gets its own FFI-based high-
;          resolution timer; plain Lua's own os.clock() turns out to be
;          just as coarse, so it optionally builds against
;          competition/lua/bench/monotonic.so too — see monotonic.c's own
;          header comment for the one-time build command)
;        - cvm/cvm, the standalone C11 prototype VM in cvm/ (see
;          cvm/README.md — a narrow experiment scoped to exactly
;          competition/scheme/bench/creme.scm, not a general Scheme
;          runtime), compiling and running competition/scheme/bench/
;          creme.scm itself through its own self-hosted (creme compiler
;          compiler) -- a genuinely independent compile of the same
;          source, not the bytecode creme's own column runs (build once:
;          make -C cvm; this script regenerates cvm/compiler-run.cvmc, the
;          precompiled self-hosted-compiler image cvm's compiler mode
;          depends on, on every run -- see ensure-cvm-compiler-image!
;          below, cheap enough (~0.15s) not to bother with a staleness
;          check spanning every .sld the compiler bundles)
;
;   2. "todo-app" -- HTTP-benchmarks the scheme.cr demo-todo app
;      (competition/scheme/demo-todo/app.scm) against its Sinatra+ERB+
;      Sequel+SQLite, Kemal+Granite+ECR, Racket web-server, Go Fiber+GORM+
;      html-template, Node Express+Drizzle+Eta, and C facil.io+mustache+
;      SQLite3 twins using wrk -- plus cvm, compiling and running that SAME
;      app.scm source directly through its own self-hosted (creme compiler
;      compiler) instead of a hand-ported twin -- including its (creme dao)
;      dependency's define-dao, a defmacro exported from a pure-Scheme,
;      file-based library: the self-hosted compiler's own compile-defmacro!/
;      ensure-libraries-loaded! (modules/creme/compiler/compiler.sld)
;      recursively load and compile a file-based library's own body the
;      first time it's imported and register any defmacro/define-syntax it
;      exports into the same macro-table a textually-local one would use --
;      needed since cvm's own `import!`/`expand-if-macro` builtins are
;      permanent stubs (cvm's global table is unconditionally flat, with no
;      runtime Macro/SchemeSyntaxRules representation at all -- see
;      cvm/bootstrap.c's own header comment).
;
; Run with no flags to run both suites, bench first (much faster, and the
; order this file's own sections appear in below) then todo-app. Narrow to
; just one with --only bench / --only todo-app.
;
; Each variant in either suite is optional: if its command isn't found (or
; exits non-zero), that column/app falls back to "n/a" instead of raising,
; so this script — and `make bench`, and the "runs end to end" integration
; spec that exercises it — stay green on a machine that doesn't have
; ruby/racket/wrk/etc. installed or hasn't built bin/creme/bin/bench_cr yet.
;
; The bench suite is a single-run comparison, not a best-of-N — rerun with
; --only bench a few times by hand and eyeball the spread if you want to
; filter out noise. The todo-app suite already runs each app for a fixed
; wrk --duration (default 8s) per content type.
;
; Pass --html to also write a combined report as competition/bench.html
; (covering whichever suite(s) actually ran), skipped by default — most
; runs just want the terminal tables, and building/writing the HTML is
; wasted work otherwise. Run with -h/--help for the full flag list (see
; (creme cli), modules/creme/cli.sld).
;
; (creme bench) (used below for its table/HTML report helpers, by both
; suites) also imports (creme prof) for its profiling helpers, so this
; script — like anything else importing (creme bench) — isn't importable
; on musl/Alpine builds (see src/scheme/modules/creme/prof_native.cr's
; header comment).

(import (scheme base) (scheme write) (scheme cxr) (scheme process-context)
        (creme process) (creme regex) (creme string) (creme numfmt)
        (creme bench) (creme cli) (creme introspection) (creme http)
        (creme file) (creme wrk) (creme shell) (creme sort) (creme term)
        (only (creme extra) filter))

(define opts
  (cli "Cross-language CPU benchmark + demo-todo HTTP benchmark, in one run"
       (list (flag "html" "--html" "Also write competition/bench.html")
             (flag "only" "--only" "Run only this suite: bench, todo-app" 'string #f)
             (flag "scheme-port" "--scheme-port" "scheme.cr server port" 'integer 4571)
             (flag "ruby-port" "--ruby-port" "Ruby server port" 'integer 4570)
             (flag "crystal-port" "--crystal-port" "Crystal server port" 'integer 4572)
             (flag "racket-port" "--racket-port" "Racket server port" 'integer 4573)
             (flag "go-port" "--go-port" "Go server port" 'integer 4574)
             (flag "node-port" "--node-port" "Node server port" 'integer 4575)
             (flag "c-port" "--c-port" "C server port" 'integer 4576)
             (flag "cvm-port" "--cvm-port" "cvm (C11 prototype VM) server port" 'integer 4577)
             (flag "duration" "--duration" "wrk run duration" 'string "8s")
             (flag "threads" "--threads" "wrk thread count" 'integer 4)
             (flag "conns" "--conns" "wrk connection count" 'integer 32)
             (flag "profile" "--profile"
                   "Also run the scheme.cr server under --profile (creme prof) and print its report after benchmarking"))))

(define only (cli-get opts "only"))
(define want-html? (cli-flag? opts "html"))
(define (run-bench-suite?) (or (not only) (string=? only "bench")))
(define (run-todo-app-suite?) (or (not only) (string=? only "todo-app")))

; ---- shared: FreeBSD-vs-everywhere-else binary naming ----------------------

; This project's own FreeBSD dev environment installs Guile/Lua version-
; suffixed with no bare `guile`/`lua` on PATH — everywhere else (Linux,
; Darwin) the bare name is what's actually installed. (runtime)'s own `os`
; field (creme introspection, uname -s under the hood) picks the right one
; at run time instead of hardcoding either.
(define freebsd? (equal? (cdr (assq 'os (runtime))) "FreeBSD"))
(define (freebsd-binary base freebsd-name) (if freebsd? freebsd-name base))
(define guile-cmd (freebsd-binary "guile" "guile3"))
(define lua-cmd (freebsd-binary "lua" "lua55"))

;; ---- terminal color: a per-column green(best)->red(worst) 256-color -------
;; gradient for the bench-suite tables below. Terminal-only (never applied to
;; the --html path -- raw escape codes would show up as garbage inside a
;; <td>) and gated the same way modules/creme/spec.sld's own spec-use-color?
;; is (stdout-tty? from (creme term), NO_COLOR respected).
(define bench-use-color? (and (stdout-tty?) (not (get-environment-variable "NO_COLOR"))))

;; Wraps text in a 256-color (SGR "38;5;n") foreground code, zero-padded to
;; ALWAYS exactly 3 digits ("046", "196", ...) -- every wrapped cell in a
;; column then carries the exact same escape-sequence byte length, so
;; (creme table)'s column-widths/pad-cell (plain string-length, no ANSI
;; awareness) still pads correctly: it only ever compares LENGTH DIFFERENCES
;; between cells in the same column, and a uniform per-cell overhead cancels
;; out of that difference. A no-op (returns text unchanged) when
;; bench-use-color? is false, so plain/piped output is untouched.
(define (bench-colorize color-index text)
  (if bench-use-color?
      (string-append "\x1b;[38;5;" (string-pad (number->string color-index) 3 "0") "m" text "\x1b;[0m")
      text))

;; Color for a cell with no data at all ("n/a"/"-") -- still wrapped (not
;; left bare) so its escape overhead matches every other cell in its column;
;; see bench-colorize's own comment for why that uniformity matters.
(define neutral-gray 244)

;; t in [0,1], 0 => green/best (xterm 46), 1 => red/worst (xterm 196),
;; interpolated through the 6x6x6 color cube's green->yellow->red edge
;; (yellow = 226 at t=0.5) -- 11 discrete steps, the finest a plain 256-color
;; palette offers along that edge.
(define (gradient-color t)
  (let ((t (max 0 (min 1 t))))
    (if (< t 0.5)
        (+ 46 (* 36 (exact (round (* 5 (/ t 0.5))))))
        (+ 196 (* 6 (exact (round (* 5 (- 1 (/ (- t 0.5) 0.5))))))))))

(define (range n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))
(define (nth-column table n) (map (lambda (row) (list-ref row n)) table))

;; (per-column-minmax value-table ncols) -> a list of (min . max) pairs, one
;; per column index 0..ncols-1, over value-table's non-#f entries in that
;; column -- (#f . #f) if a column has no real data at all (e.g. Guile not
;; installed). `value-table` is a list of rows, each a list of ncols raw
;; numbers-or-#f. Used for the comparison matrix (fixing a denominator
;; column and comparing every other variant's ratio against it IS a fair,
;; meaningful comparison).
(define (per-column-minmax value-table ncols)
  (map (lambda (n)
         (let ((nums (filter (lambda (x) x) (nth-column value-table n))))
           (if (null? nums) (cons #f #f) (cons (apply min nums) (apply max nums)))))
       (range ncols)))

;; (row-minmax vals) -> one (min . max) pair over vals' non-#f entries
;; ((#f . #f) if none). Used for the measurements table: comparing every
;; variant's time against every other variant's time for the SAME workload
;; (a row) is the meaningful comparison -- comparing one variant's own times
;; across DIFFERENT workloads (a column) mixes workloads of wildly different
;; intrinsic scale/difficulty and isn't a useful comparison at all.
(define (row-minmax vals)
  (let ((nums (filter (lambda (x) x) vals)))
    (if (null? nums) (cons #f #f) (cons (apply min nums) (apply max nums)))))

;; (colorize-value value minmax text) -> text, colorized against its own
;; column's (min . max) (lower is better for every value this bench suite
;; colors -- plain seconds, and total/total ratios against a fixed
;; denominator column -- so no sign-flip is ever needed between the two
;; tables below). #f (no data) always renders as neutral-gray regardless of
;; minmax. A single-valued column (min = max) renders as pure green (t=0)
;; rather than dividing by zero.
(define (colorize-value value minmax text)
  (if (not bench-use-color?)
      text
      (bench-colorize
       (if (not value)
           neutral-gray
           (let ((lo (car minmax)) (hi (cdr minmax)))
             (gradient-color (if (= lo hi) 0 (/ (- value lo) (- hi lo))))))
       text)))

;; Header cells are never part of the gradient (they're column labels, not
;; data) but MUST still be wrapped in a fixed-length escape sequence when
;; bench-use-color? is on: (creme table)'s column-widths computes ONE width
;; per column across the WHOLE table -- header row included -- from plain
;; string-length. If body/footer cells in a column carry +15 invisible
;; bytes of ANSI overhead (see bench-colorize's own comment) but the header
;; cell in that same column doesn't, the header gets padded with that same
;; +15 worth of ordinary, VISIBLE spaces to reach the (ANSI-inflated) target
;; width -- exactly the header-misalignment bug this fixes. Any fixed color
;; works here since it's cosmetic; reusing neutral-gray keeps it unobtrusive.
(define (colorize-header text) (bench-colorize neutral-gray text))

;; ===========================================================================
;; Suite 1: bench -- pure in-process CPU micro-benchmarks
;; ===========================================================================

(define (run-bench-suite!)
  (let* ((creme-output (process-run-safe "bin/creme" (list "competition/scheme/bench/creme.scm")))
         (crystal-output (process-run-safe "bin/bench_cr" '()))
         (go-output (process-run-safe "bin/bench_go" '()))
         (ruby-output (process-run-safe "ruby" (list "competition/ruby/bench/bench.rb")))
         (racket-output (process-run-safe "racket" (list "competition/racket/bench/racket.scm")))
         (guile-output (process-run-safe guile-cmd (list "--r7rs" "competition/guile/bench/guile.scm")))
         (node-output (process-run-safe "node" (list "competition/node/bench/bench.js")))
         (lua-output (process-run-safe lua-cmd (list "competition/lua/bench/bench.lua")))
         (luajit-output (process-run-safe "luajit" (list "competition/lua/bench/bench.lua"))))

    ; Regenerates cvm/compiler-run.cvmc (the precompiled self-hosted-compiler
    ; image cvm's own compiler mode depends on to run a plain .scm file
    ; directly, see cvm/compiler-run.scm) unconditionally every run rather
    ; than tracking a staleness check across every .sld it bundles
    ; (reader.sld, bytecode.sld, compiler.sld, ...) -- ~0.15s, cheap enough
    ; not to bother. Best-effort like every other variant here: if bin/creme
    ; or cvm/cvm aren't built yet, this (and then cvm-output below) just
    ; falls back to n/a.
    (process-run-safe "bin/creme" (list "--emit-cvm" "cvm/compiler-run.scm" "cvm/compiler-run.cvmc"))
    (let ((cvm-output (process-run-safe "cvm/cvm" (list "competition/scheme/bench/creme.scm"))))

      ; ---- parse "<label> = <result>  (<elapsed>s)" / "total = <elapsed>s" ---

      (define (parse-elapsed-alist text)
        (if (not text)
            '()
            ; Elapsed times are usually fixed-point ("0.00023s"), but a fast
            ; enough workload/variant (e.g. a builder-based string-build-test
            ; under native Crystal) can print in scientific notation
            ; ("3.19e-05s") -- match both so a sub-fixed-point result doesn't
            ; silently become n/a.
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
      (define lua-times (parse-elapsed-alist lua-output))
      (define luajit-times (parse-elapsed-alist luajit-output))
      (define creme-times (parse-elapsed-alist creme-output))
      (define cvm-times (parse-elapsed-alist cvm-output))

      ; ---- build the two tables ---------------------------------------------
      ;
      ; Table 1 ("measurements") is the raw per-workload elapsed seconds, one
      ; column per variant, nothing derived.
      ;
      ; Table 2 ("comparison matrix") turns EVERY variant into both a row and
      ; a column, cell[row][col] = row's total time / column's total time —
      ; reading along a row answers "how many times slower is this variant
      ; than each of the others", for every pair at once. Built from each
      ; variant's aggregate "total" line (not per-workload) so the matrix
      ; stays one NxN table instead of one per workload.

      (define (lookup label alist)
        (let ((pair (assoc label alist string=?)))
          (if pair (cdr pair) #f)))

      (define workloads
        (list "fib(27)" "sum-to(2000000)" "build-list(200000) length+reverse"
              "vector-sum-test(500000)" "hashtable-test(200000)" "record-test(500000)"
              "string-build-test(4000) length"
              "tak(18,12,6)" "nqueens(9)" "total"))

      (define variant-times
        (list (cons "crystal" crystal-times) (cons "go" go-times) (cons "racket" racket-times)
              (cons "ruby" ruby-times) (cons "guile" guile-times) (cons "node" node-times)
              (cons "lua55" lua-times) (cons "luajit" luajit-times)
              (cons "creme" creme-times) (cons "cvm" cvm-times)))

      (define (times-of variant) (lookup variant variant-times))
      (define (total-of variant) (lookup "total" (times-of variant)))

      ;; #f (a variant whose command wasn't found/failed, e.g. Guile not
      ;; installed) sorts to the end rather than comparing as a number.
      (define (total-less? a b)
        (cond ((not a) #f)
              ((not b) #t)
              (else (< a b))))

      ;; Columns (and, for the comparison matrix, rows too, since both axes
      ;; share this one list) ordered fastest-total-first.
      (define variant-names (sort-by total-of total-less? (map car variant-times)))

      ; ---- table 1: measurements ---------------------------------------------
      ;
      ; Raw values are kept alongside the formatted strings so each cell can
      ; be colorized against a (min . max) -- see colorize-value's own
      ; comment. Colorized PER ROW: for a given workload (including
      ; "total"), every variant's time is compared against every other
      ; variant's time for that SAME workload -- the meaningful comparison
      ; ("which language is fastest at this"). Coloring per COLUMN instead
      ; (one variant's own times across different workloads) was tried and
      ; rejected: it compares workloads of wildly different intrinsic scale
      ; to each other, which isn't informative, and it made "total" (a SUM
      ; of every workload time in that column) trivially always the worst
      ; cell in its column regardless of how fast that variant actually is.

      (define measurement-headers (cons "workload" variant-names))
      (define measurement-headers-colored (cons "workload" (map colorize-header variant-names)))
      (define measurement-aligns (cons 'left (map (lambda (v) 'right) variant-names)))

      (define measurement-value-table
        (map (lambda (label) (map (lambda (v) (lookup label (times-of v))) variant-names))
             workloads))

      ; PLAIN -- unchanged shape, used for the --html path.
      (define measurement-rows
        (map (lambda (label vals) (cons label (map (lambda (v) (numfmt-fixed v 5)) vals)))
             workloads measurement-value-table))

      ; Terminal-only: same cells, colorized against their own row's (min . max).
      (define measurement-rows-colored
        (map (lambda (label vals)
               (let ((mm (row-minmax vals)))
                 (cons label (map (lambda (v) (colorize-value v mm (numfmt-fixed v 5))) vals))))
             workloads measurement-value-table))

      ; ---- table 2: comparison matrix (row / column, on total time) --------

      (define matrix-headers (cons "" variant-names))
      (define matrix-headers-colored (cons "" (map colorize-header variant-names)))
      (define matrix-aligns (cons 'left (map (lambda (v) 'right) variant-names)))

      (define (safe-ratio num denom) (if (or (not num) (not denom) (= denom 0)) #f (/ num denom)))

      (define matrix-value-table
        (map (lambda (row-name)
               (map (lambda (col-name)
                      (if (string=? row-name col-name) #f (safe-ratio (total-of row-name) (total-of col-name))))
                    variant-names))
             variant-names))

      (define matrix-col-minmax (per-column-minmax matrix-value-table (length variant-names)))

      (define (matrix-cell-text row-name col-name)
        (if (string=? row-name col-name) "-" (numfmt-ratio (total-of row-name) (total-of col-name))))

      ; PLAIN -- unchanged shape, used for the --html path.
      (define matrix-rows
        (map (lambda (row-name)
               (cons row-name (map (lambda (col-name) (matrix-cell-text row-name col-name)) variant-names)))
             variant-names))

      ; Terminal-only: same cells, colorized.
      (define matrix-rows-colored
        (map (lambda (row-name vals)
               (cons row-name
                     (map (lambda (col-name v mm) (colorize-value v mm (matrix-cell-text row-name col-name)))
                          variant-names vals matrix-col-minmax)))
             variant-names matrix-value-table))

      ; ---- print both tables -------------------------------------------------

      (display "bench (cross-language CPU workloads)\n")
      (display "measurements (seconds)\n")
      (display (bench-table->string measurement-headers-colored measurement-rows-colored measurement-aligns 1))
      (newline)
      (display "comparison matrix (row's total time / column's total time — e.g. the \"creme\" row's \"crystal\" column is how many times slower creme is than crystal)\n")
      (display (bench-table->string matrix-headers-colored matrix-rows-colored matrix-aligns))
      (newline)

      (if want-html?
          (string-append
           "<h2>bench: measurements (seconds)</h2>\n"
           (bench-table->html measurement-headers measurement-rows measurement-aligns)
           "<h2>bench: comparison matrix</h2>\n"
           "<p>row's total time / column's total time</p>\n"
           (bench-table->html matrix-headers matrix-rows matrix-aligns))
          ""))))

;; ===========================================================================
;; Suite 2: todo-app -- HTTP-benchmarks the demo-todo web-app twins with wrk
;; ===========================================================================

(define scheme-port (number->string (cli-get opts "scheme-port")))
(define ruby-port (number->string (cli-get opts "ruby-port")))
(define crystal-port (number->string (cli-get opts "crystal-port")))
(define racket-port (number->string (cli-get opts "racket-port")))
(define go-port (number->string (cli-get opts "go-port")))
(define node-port (number->string (cli-get opts "node-port")))
(define c-port (number->string (cli-get opts "c-port")))
(define cvm-port (number->string (cli-get opts "cvm-port")))
(define duration (cli-get opts "duration"))
(define threads (cli-get opts "threads"))
(define profile? (cli-flag? opts "profile"))
(define conns (cli-get opts "conns"))

;; ---- step logging -----------------------------------------------------------

;; Exactly one line of progress per app -- waiting-for-port/benchmarking/
;; stopping all happen silently in between.
(define (step! msg) (display msg) (newline))

;; ---- process helpers -------------------------------------------------------

;; Every server this suite starts is tracked here by pid (as returned by
;; process-spawn) so cleanup! can kill exactly the processes THIS run
;; started -- no more pkill pattern-matching against a whole process tree,
;; which used to also (over-eagerly) catch anything left over from an
;; unrelated previous run.
(define running-pids '())

(define (track! pid) (set! running-pids (cons pid running-pids)) pid)

;; Drops a pid from running-pids without signaling it -- for a pid that has
;; already exited on its own (see the --profile server shutdown below), so
;; cleanup! doesn't later try to kill an already-reaped pid.
(define (untrack! pid)
  (set! running-pids
        (let loop ((pids running-pids))
          (cond ((null? pids) '())
                ((= (car pids) pid) (loop (cdr pids)))
                (else (cons (car pids) (loop (cdr pids))))))))

(define (cleanup!)
  (for-each (lambda (pid) (process-kill! pid)) running-pids)
  (set! running-pids '()))

;; ---- waiting for a server to come up ---------------------------------------

(define (port-alive? port)
  (guard (e (#t #f))
    (http-get (string-append "http://127.0.0.1:" port "/") (list (cons "Accept" "text/html")))
    #t))

(define (wait-for-port! port)
  (guard (e (#t (display "Server on port ") (display port) (display " never came up") (newline) (exit 1)))
    (shell-wait-until! (lambda () (port-alive? port)))))

;; ---- running wrk, collecting results for the final table -------------------

;; One row per app, accumulated in run order: (app-label html-stats
;; json-stats), where each *-stats is (req-per-sec latency-avg-ms
;; latency-p90-ms latency-p99-ms) -- both content types' numbers as columns
;; on the same row, rather than a separate row per content type.
;; wrk-run/wrk-parse ((creme wrk), run with --latency) already hand back
;; these fields as real numbers, so no text-scraping is needed here. wrk has
;; no native p95 -- p90 is reported instead, not a made-up/interpolated p95.
(define results '())

(define (run-wrk! port accept)
  (let* ((url (string-append "http://127.0.0.1:" port "/"))
         (result (wrk-run url 'threads threads 'conns conns 'duration duration 'accept accept)))
    (list (cdr (assoc "requests-per-sec" result))
          (cdr (assoc "latency-avg-ms" result))
          (cdr (assoc "latency-p90-ms" result))
          (cdr (assoc "latency-p99-ms" result)))))

(define (bench-app! app-label port)
  (let* ((html (run-wrk! port "text/html"))
         (json (run-wrk! port "application/json")))
    (set! results (cons (list app-label html json) results))))

;; stats-req/stats-avg/stats-p90/stats-p99 -- accessors into one *-stats
;; list (req-per-sec latency-avg-ms latency-p90-ms latency-p99-ms).
(define stats-req car)
(define stats-avg cadr)
(define stats-p90 caddr)
(define stats-p99 cadddr)

;; ---- results table (throughput) ---------------------------------------------

(define (throughput-row->cells row)
  (list (car row)
        (numfmt-fixed (stats-req (cadr row)) 2)
        (numfmt-fixed (stats-req (caddr row)) 2)))

(define (results-table-headers) (list "App" "HTML Req/s" "JSON Req/s"))
(define (results-table-aligns) (list 'left 'right 'right))
(define (results-table-rows) (map throughput-row->cells (reverse results)))

(define (print-results-table!)
  (newline)
  (step! "Results")
  (display (bench-table->string (results-table-headers) (results-table-rows) (results-table-aligns)))
  (newline))

;; ---- latency table (avg/p90/p99 ms), one row per app+content-type ----------

(define (latency-rows)
  (apply append
         (map (lambda (row)
                (list (list (car row) "text/html"
                            (numfmt-fixed (stats-avg (cadr row)) 2)
                            (numfmt-fixed (stats-p90 (cadr row)) 2)
                            (numfmt-fixed (stats-p99 (cadr row)) 2))
                      (list (car row) "application/json"
                            (numfmt-fixed (stats-avg (caddr row)) 2)
                            (numfmt-fixed (stats-p90 (caddr row)) 2)
                            (numfmt-fixed (stats-p99 (caddr row)) 2))))
              (reverse results))))

(define (latency-table-headers) (list "App" "Content-Type" "Avg" "p90" "p99"))
(define (latency-table-aligns) (list 'left 'left 'right 'right 'right))

(define (print-latency-table!)
  (newline)
  (step! "Latency (ms) -- wrk has no native p95, p90 is reported instead")
  (display (bench-table->string (latency-table-headers) (latency-rows) (latency-table-aligns)))
  (newline))

;; ---- ranking, fastest first, each row vs. the next-fastest -----------------

;; One row per app, ranked fastest-first by key-fn (a *-stats accessor
;; composed with a content-type selector -- see call sites below), each row
;; showing how many times faster it is than the NEXT (slower) row -- e.g.
;; "1.9x" means this app is 1.9x this metric's throughput of the app ranked
;; just below it; the slowest app's own row is "n/a" (numfmt-ratio's own
;; convention for "no next row to compare against").
(define (ranked-rows key-fn)
  (let loop ((rows (sort-by key-fn > results)) (rank 1) (acc '()))
    (if (null? rows)
        (reverse acc)
        (let* ((row (car rows))
               (rest (cdr rows))
               (next-value (if (null? rest) #f (key-fn (car rest)))))
          (loop rest (+ rank 1)
                (cons (list (number->string rank) (car row)
                            (numfmt-fixed (key-fn row) 2)
                            (numfmt-ratio (key-fn row) next-value))
                      acc))))))

(define (ranking-headers) (list "#" "App" "Req/s" "vs next"))
(define (ranking-aligns) (list 'right 'left 'right 'right))

(define (print-ranking! title key-fn)
  (newline)
  (step! title)
  (display (bench-table->string (ranking-headers) (ranked-rows key-fn) (ranking-aligns)))
  (newline))

(define (print-rankings!)
  (print-ranking! "Ranked by HTML throughput" (lambda (row) (stats-req (cadr row))))
  (print-ranking! "Ranked by JSON throughput" (lambda (row) (stats-req (caddr row)))))

;; ---- --profile: the scheme.cr server's own profile report -----------------

(define scheme-script "competition/scheme/demo-todo/app.scm")

;; `./bin/creme --profile table` (src/main.cr) prints its (creme bench)
;; profile-report->string report to stdout right after the wrapped script
;; stops -- which, here, is /tmp/bench-scheme.log (same redirect used for
;; its ordinary request log). Everything before the report's own
;; "<script-path> (x1)" heading is per-request log noise from the wrk runs,
;; so this prints from that heading onward (found by searching for the same
;; script path passed to --profile below) instead of the whole (potentially
;; huge) log file.
(define (print-scheme-profile!)
  (let* ((log (file-read "/tmp/bench-scheme.log"))
         (idx (string-index-of log scheme-script)))
    (newline)
    (step! "scheme.cr / bin/creme -- profile (--profile)")
    (display (if idx (substring log idx (string-length log)) log))
    (newline)))

;; ---- functional smoke test, run once before any server starts -------------

;; competition/scheme/demo-todo/app_spec.scm spawns its own instance of the
;; SAME app.scm this suite benchmarks (on its own fixed port, independent of
;; any --*-port flag here) and exercises add/toggle/delete/JSON end-to-end
;; via (creme spec) -- see that file's own header comment for why: wait-
;; for-port! below only ever checks that a port answers, never that the app
;; behaves correctly, so a subtly broken app would otherwise still produce
;; a wrk req/s number, silently comparing garbage. Run once here, before any
;; wrk load-testing starts, rather than per-app-under-test below, since it's
;; the one Scheme source file (app.scm) every entry in this suite either
;; runs directly (scheme.cr, cvm) or was hand-ported from (every other
;; language's twin) -- a behavior bug in app.scm's own logic would already
;; be a bug in the comparison itself, worth catching before spending any
;; time on throughput numbers at all.
(define (verify-app-behavior!)
  (step! "demo-todo app.scm -- verifying behavior before benchmarking")
  (let ((result (process-run "./bin/creme" (list "competition/scheme/demo-todo/app_spec.scm"))))
    (if (not (cadddr result))
        (begin
          (display (car result))
          (display "demo-todo app.scm failed its functional smoke test -- see above, not benchmarking")
          (newline)
          (exit 1)))))

(define (run-todo-app-suite!)

  (verify-app-behavior!)

  ;; ---- scheme.cr / bin/creme --------------------------------------------------

  (step! (string-append "scheme.cr / bin/creme -- starting on port " scheme-port))
  (define scheme-pid
    (track! (process-spawn "./bin/creme"
                           (append (if profile? (list "--profile" "table") '())
                                   (list scheme-script))
                           'env (list (cons "PORT" scheme-port))
                           'stdout "/tmp/bench-scheme.log" 'stderr "/tmp/bench-scheme.log"
                           'stdin 'keep-open)))
  (wait-for-port! scheme-port)
  (bench-app! "scheme.cr / bin/creme" scheme-port)
  (if profile?
      (begin
        ;; Wakes app.scm's (read-line), rather than killing it outright, so
        ;; it can print/flush its profile report and exit on its own -- see
        ;; process-write-line!'s own doc comment ((creme process)).
        (process-write-line! scheme-pid "")
        (process-wait! scheme-pid)
        (untrack! scheme-pid)
        (print-scheme-profile!))
      (cleanup!))
  (sleep! 1)

  ;; ---- Ruby / Sinatra+ERB+Sequel+SQLite ---------------------------------------

  (step! (string-append "Ruby / Sinatra+ERB+Sequel+SQLite -- starting on port " ruby-port))
  (track! (process-spawn "bundle" (list "exec" "ruby" "app.rb")
                         'chdir "competition/ruby/demo-todo"
                         'env (list (cons "PORT" ruby-port))
                         'stdout "/tmp/bench-ruby.log" 'stderr "/tmp/bench-ruby.log"))
  (wait-for-port! ruby-port)
  (bench-app! "Ruby / Sinatra+ERB+Sequel+SQLite" ruby-port)
  (cleanup!)
  (sleep! 1)

  ;; ---- Crystal / Kemal+Granite+ECR+SQLite -------------------------------------

  (step! (string-append "Crystal / Kemal+Granite+ECR+SQLite -- starting on port " crystal-port))
  ;; Run-only: assumes competition/Makefile's own build target already
  ;; produced a fresh competition/crystal/demo-todo/bin/app (see that
  ;; file's own header comment -- a real, prerequisite-tracked `make`
  ;; target, not this section's own former ad hoc shell mtime check,
  ;; which only ever verified THAT bin/app existed and was newer than its
  ;; source, never HOW it had been built; that gap is exactly how a hand-
  ;; built, non-`--release` binary once sat here unrebuilt for days).
  (track! (process-spawn "./bin/app" '()
                         'chdir "competition/crystal/demo-todo"
                         'env (list (cons "PORT" crystal-port))
                         'stdout "/tmp/bench-crystal.log" 'stderr "/tmp/bench-crystal.log"))
  (wait-for-port! crystal-port)
  (bench-app! "Crystal / Kemal+Granite+ECR+SQLite" crystal-port)
  (cleanup!)
  (sleep! 1)

  ;; ---- Racket / web-server+db+SQLite ------------------------------------------

  (step! (string-append "Racket / web-server+db+SQLite -- starting on port " racket-port))
  (track! (process-spawn "racket" (list "app.rkt")
                         'chdir "competition/racket/demo-todo"
                         'env (list (cons "PORT" racket-port))
                         'stdout "/tmp/bench-racket.log" 'stderr "/tmp/bench-racket.log"))
  (wait-for-port! racket-port)
  (bench-app! "Racket / web-server+db+SQLite" racket-port)
  (cleanup!)
  (sleep! 1)

  ;; ---- Go / Fiber+GORM+html-template+SQLite -----------------------------------

  (step! (string-append "Go / Fiber+GORM+html-template+SQLite -- starting on port " go-port))
  ;; Run-only: assumes competition/Makefile already produced a fresh
  ;; competition/go/demo-todo/bin/app -- see the Crystal section's own
  ;; comment above for why this no longer checks freshness itself.
  (track! (process-spawn "./bin/app" '()
                         'chdir "competition/go/demo-todo"
                         'env (list (cons "PORT" go-port))
                         'stdout "/tmp/bench-go.log" 'stderr "/tmp/bench-go.log"))
  (wait-for-port! go-port)
  (bench-app! "Go / Fiber+GORM+html-template+SQLite" go-port)
  (cleanup!)
  (sleep! 1)

  ;; ---- Node / Express+Drizzle+Eta+SQLite ------------------------------------

  (step! (string-append "Node / Express+Drizzle+Eta+SQLite -- starting on port " node-port))
  ;; Run-only: assumes competition/Makefile already ran `npm install` for
  ;; competition/node/demo-todo/node_modules -- see the Crystal section's
  ;; own comment above for why this no longer checks itself.
  (track! (process-spawn "node" (list "app.js")
                         'chdir "competition/node/demo-todo"
                         'env (list (cons "PORT" node-port))
                         'stdout "/tmp/bench-node.log" 'stderr "/tmp/bench-node.log"))
  (wait-for-port! node-port)
  (bench-app! "Node / Express+Drizzle+Eta+SQLite" node-port)
  (cleanup!)
  (sleep! 1)

  ;; ---- C / facil.io+mustache+SQLite3 ------------------------------------------

  (step! (string-append "C / facil.io+mustache+SQLite3 -- starting on port " c-port))
  ;; Run-only: assumes competition/Makefile already produced a fresh
  ;; competition/c/demo-todo/bin/app (delegated to c/demo-todo/Makefile,
  ;; which vendors+builds facil.io) -- see the Crystal section's own
  ;; comment above for why this no longer checks freshness itself.
  (track! (process-spawn "./bin/app" '()
                         'chdir "competition/c/demo-todo"
                         'env (list (cons "PORT" c-port))
                         'stdout "/tmp/bench-c.log" 'stderr "/tmp/bench-c.log"))
  (wait-for-port! c-port)
  (bench-app! "C / facil.io+mustache+SQLite3" c-port)
  (cleanup!)
  (sleep! 1)

  ;; ---- cvm / standalone C11 prototype VM, running app.scm itself -------------
  ;;
  ;; Not a hand-ported twin like every other entry above -- this compiles and
  ;; runs the exact same competition/scheme/demo-todo/app.scm source (and its
  ;; full (creme surf)/(creme dao)/(creme html)/... library stack) through
  ;; cvm/ (../cvm/), a from-scratch C11 VM built for exactly this: see
  ;; cvm/README.md.

  (step! (string-append "cvm / creme (C11 prototype VM) -- starting on port " cvm-port))
  ;; Run-only: assumes competition/Makefile already built cvm/cvm and
  ;; regenerated cvm/compiler-run.cvmc (the precompiled self-hosted-
  ;; compiler image cvm's compiler mode needs -- see cvm/compiler-run.
  ;; scm's own header comment) -- see the Crystal section's own comment
  ;; above for why this no longer builds/checks either itself.
  (track! (process-spawn "./cvm/cvm" (list "competition/scheme/demo-todo/app.scm")
                         'env (list (cons "PORT" cvm-port))
                         'stdout "/tmp/bench-cvm.log" 'stderr "/tmp/bench-cvm.log"))
  (wait-for-port! cvm-port)
  (bench-app! "cvm / creme (C11 prototype VM)" cvm-port)
  (cleanup!)

  (print-results-table!)
  (print-latency-table!)
  (print-rankings!)

  (if want-html?
      (string-append
       "<h2>todo-app: results (req/s)</h2>\n"
       (bench-table->html (results-table-headers) (results-table-rows) (results-table-aligns))
       "<h2>todo-app: latency (ms)</h2>\n"
       (bench-table->html (latency-table-headers) (latency-rows) (latency-table-aligns))
       "<h2>todo-app: ranked by HTML throughput</h2>\n"
       (bench-table->html (ranking-headers) (ranked-rows (lambda (row) (stats-req (cadr row)))) (ranking-aligns))
       "<h2>todo-app: ranked by JSON throughput</h2>\n"
       (bench-table->html (ranking-headers) (ranked-rows (lambda (row) (stats-req (caddr row)))) (ranking-aligns)))
      ""))

;; ===========================================================================
;; Run whichever suite(s) --only selects, bench first, then write the
;; combined --html report if requested.
;; ===========================================================================

(define html-fragments
  (append
   (if (run-bench-suite?) (list (run-bench-suite!)) '())
   (if (run-todo-app-suite?) (list (run-todo-app-suite!)) '())))

(if want-html?
    (begin
      (write-html-report "competition/bench.html" "creme bench"
                          (apply string-append html-fragments))
      (display "wrote competition/bench.html")
      (newline)))
