;; Benchmarks the scheme.cr demo-todo app (competition/scheme/demo-todo/app.scm)
;; against its Sinatra+ERB+Sequel+SQLite, Kemal+Granite+ECR, Racket web-server,
;; Go Fiber+GORM+html-template, Node Express+Drizzle+Eta, and C facil.io+
;; mustache+SQLite3 twins using wrk -- plus cvm, the standalone C11
;; prototype VM (../../cvm/), running that SAME app.scm source (compiled to
;; .cvmc bytecode via `creme --emit-cvm`) instead of a hand-ported twin.
;; A scheme.cr port of bench.sh -- same
;; sequence, same wrk invocations, same cleanup patterns, just orchestrated
;; from creme instead of bash. Prints one line per step as it runs, then a
;; results table at the end (see print-results-table! below) instead of
;; dumping each wrk report's raw text. Run from the repo root:
;;   ./bin/creme competition/bench.scm
;; Pass -h/--help for the full flag list (ports, wrk duration/threads/conns).

(import (scheme base) (scheme write) (scheme cxr) (scheme process-context)
        (creme process) (creme http) (creme file) (creme cli) (creme wrk)
        (creme shell) (creme table) (creme numfmt) (creme sort) (creme string))

(define opts
  (cli "Benchmarks the scheme.cr/Ruby/Crystal/Racket/Go demo-todo twins with wrk"
       (list (flag "scheme-port" "--scheme-port" "scheme.cr server port" 'integer 4571)
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

;; Every server this script starts is tracked here by pid (as returned by
;; process-spawn) so cleanup! can kill exactly the processes THIS run
;; started -- no more pkill pattern-matching against a whole process tree,
;; which used to also (over-eagerly) catch anything left over from an
;; unrelated previous run.
(define running-pids '())

(define (track! pid) (set! running-pids (cons pid running-pids)) pid)

;; Drops a pid from running-pids without signaling it -- for a pid that has
;; already exited on its own (see the --profile server shutdown below),
;; so cleanup! doesn't later try to kill an already-reaped pid.
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

(define results-style (table-style bordered-style 'header 1))

(define (throughput-row->cells row)
  (list (car row)
        (numfmt-fixed (stats-req (cadr row)) 2)
        (numfmt-fixed (stats-req (caddr row)) 2)))

(define (print-results-table!)
  (newline)
  (step! "Results")
  (display (table->string
            (cons (list "App" "HTML Req/s" "JSON Req/s")
                  (map throughput-row->cells (reverse results)))
            (list 'left 'right 'right)
            results-style))
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

(define (print-latency-table!)
  (newline)
  (step! "Latency (ms) -- wrk has no native p95, p90 is reported instead")
  (display (table->string
            (cons (list "App" "Content-Type" "Avg" "p90" "p99")
                  (latency-rows))
            (list 'left 'left 'right 'right 'right)
            results-style))
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

(define (print-ranking! title key-fn)
  (newline)
  (step! title)
  (display (table->string
            (cons (list "#" "App" "Req/s" "vs next")
                  (ranked-rows key-fn))
            (list 'right 'left 'right 'right)
            results-style))
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
;; "<script-path> (x1)" heading is per-request log noise from the wrk
;; runs, so this prints from that heading onward (found by searching for
;; the same script path passed to --profile below) instead of the whole
;; (potentially huge) log file.
(define (print-scheme-profile!)
  (let* ((log (file-read "/tmp/bench-scheme.log"))
         (idx (string-index-of log scheme-script)))
    (newline)
    (step! "scheme.cr / bin/creme -- profile (--profile)")
    (display (if idx (substring log idx (string-length log)) log))
    (newline)))

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
      ;; Wakes app.scm's (read-line), rather than killing it outright, so it
      ;; can print/flush its profile report and exit on its own -- see
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
(process-run "mkdir" (list "-p" "competition/crystal/demo-todo/bin"))
;; Same freshness check as bench.sh's `[ ! -x bin/app ] || [ src/app.cr -nt bin/app ]`,
;; done as one shell test since (creme file) has no mtime accessor of its own.
(if (not (cdr (assoc "success" (shell-run "sh"
                            (list "-c" (string-append
                                        "[ -x competition/crystal/demo-todo/bin/app ] && "
                                        "[ ! competition/crystal/demo-todo/src/app.cr -nt "
                                        "competition/crystal/demo-todo/bin/app ]"))))))
    (shell-checked! "sh" (list "-c" "cd competition/crystal/demo-todo && shards build --release") "shards build"))
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
;; Same freshness check as the Crystal section above, one shell test since
;; (creme file) has no mtime accessor of its own: rebuild only if bin/app is
;; missing or older than main.go.
(if (not (cdr (assoc "success" (shell-run "sh"
                            (list "-c" (string-append
                                        "[ -x competition/go/demo-todo/bin/app ] && "
                                        "[ ! competition/go/demo-todo/main.go -nt "
                                        "competition/go/demo-todo/bin/app ]"))))))
    (shell-checked! "sh" (list "-c" "cd competition/go/demo-todo && go build -o bin/app .") "go build"))
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
;; Node has no compiled binary to go stale -- just install if node_modules is
;; missing, unlike the Crystal/Go mtime-based freshness checks above.
(if (not (cdr (assoc "success" (shell-run "sh"
                            (list "-c" "[ -d competition/node/demo-todo/node_modules ]")))))
    (shell-checked! "sh" (list "-c" "cd competition/node/demo-todo && npm install") "npm install"))
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
;; Same freshness check as the Crystal/Go sections above, one shell test since
;; (creme file) has no mtime accessor of its own: rebuild only if bin/app is
;; missing or older than main.c. `make` itself handles fetching the vendored
;; facil.io source (competition/c/demo-todo/vendor/facil.io) on first build.
(if (not (cdr (assoc "success" (shell-run "sh"
                            (list "-c" (string-append
                                        "[ -x competition/c/demo-todo/bin/app ] && "
                                        "[ ! competition/c/demo-todo/main.c -nt "
                                        "competition/c/demo-todo/bin/app ]"))))))
    (shell-checked! "sh" (list "-c" "cd competition/c/demo-todo && make") "make"))
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
;; cvm/ (../../cvm/), a from-scratch C11 VM built for exactly this: see
;; cvm/README.md.

(step! (string-append "cvm / creme (C11 prototype VM) -- starting on port " cvm-port))
;; cvm/Makefile's own mtime rules already no-op instantly when nothing
;; changed (unlike shards/go's own build tools, which pay real startup cost
;; even to discover there's nothing to do -- see the Crystal/Go sections'
;; own freshness-check comments above), so it's called unconditionally
;; rather than replicated as a shell test here.
(shell-checked! "sh" (list "-c" "cd cvm && make") "cvm make")
;; Re-emit app.scm's bytecode only if it's missing or older than app.scm --
;; ALSO older than cvm/cvm itself or cvm_serializer.cr, unlike the other
;; twins' plain source-vs-binary freshness check: a cached .cvmc's on-disk
;; FORMAT (not just its content) can change independently of app.scm --
;; e.g. the CVM1->CVM2 bump adding per-instruction source lines -- and a
;; stale-but-still-newer-than-app.scm .cvmc from before such a bump fails
;; to load with a cryptic "not a CVM2 bytecode file" instead of silently
;; regenerating (see cvm/loader.c's own magic check).
(if (not (cdr (assoc "success" (shell-run "sh"
                            (list "-c" (string-append
                                        "[ -f competition/scheme/demo-todo/app.cvmc ] && "
                                        "[ ! competition/scheme/demo-todo/app.scm -nt "
                                        "competition/scheme/demo-todo/app.cvmc ] && "
                                        "[ ! cvm/cvm -nt competition/scheme/demo-todo/app.cvmc ] && "
                                        "[ ! src/scheme/compile/cvm_serializer.cr -nt "
                                        "competition/scheme/demo-todo/app.cvmc ]"))))))
    (shell-checked! "sh" (list "-c" "./bin/creme --emit-cvm competition/scheme/demo-todo/app.scm competition/scheme/demo-todo/app.cvmc") "creme --emit-cvm"))
(track! (process-spawn "./cvm/cvm" (list "competition/scheme/demo-todo/app.cvmc")
                       'env (list (cons "PORT" cvm-port))
                       'stdout "/tmp/bench-cvm.log" 'stderr "/tmp/bench-cvm.log"))
(wait-for-port! cvm-port)
(bench-app! "cvm / creme (C11 prototype VM)" cvm-port)
(cleanup!)

(print-results-table!)
(print-latency-table!)
(print-rankings!)
