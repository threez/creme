;; ===========================================================================
;; A (creme spec)-based sweep of examples/*.scm's own cvm compatibility --
;; see modules/creme/spec.sld's own header comment for the framework this
;; uses. Complements spec/scheme_examples_spec.cr's native "runs without
;; raising" coverage of the same corpus, but exercises the OTHER backend:
;; each example is run via `./bin/creme --cvm <path>` (native-compile via
;; --emit-cvm, then execute the resulting chunk on ./cvm/cvm -- see
;; cvm/README.md's "Building and running" section and src/main.cr's
;; run_via_cvm/handle_cvm), spawned fresh via (creme process)'s
;; process-run so this works regardless of which backend THIS spec file
;; itself happens to be running under (native, self-hosted, or cvm
;; compiler mode -- see spec/creme/main_spec.scm's own header comment for
;; those three run modes; process-run's own contract is identical on all
;; of them).
;;
;; cvm implements a strict SUBSET of the real VM's builtins/value model
;; (see cvm/README.md's "Compatibility with `creme`" section), so a couple
;; of examples are still `pending` below instead of `it` -- each with the
;; exact failure it currently hits. Re-run this file after any cvm builtin
;; addition; a pending case that now passes should be promoted to `it`.
;; Following (creme spec)'s own `pending` contract, these never actually
;; invoke cvm at all -- see modules/creme/spec.sld's own header comment on
;; why `pending` takes no body.
;;
;; As of 2026-08-01, only 24-tui-try-scheme.scm (drives an interactive
;; terminal UI -- there's no terminal to drive under a spawned, non-tty
;; subprocess) and 25-rfc8439-secure-message.scm (unbound variable:
;; rfc8439-random-key -- (creme rfc8439) has no cvm port) remain pending.
;; Every other example that used to be pending here got a real fix instead
;; of staying excluded:
;;   - 26-import-generated-library.scm: CVMEmitter now retries a failed
;;     import once, real-running every earlier form in the script first
;;     (src/scheme/compile/cvm_emitter.cr), so a script that generates its
;;     own library file at runtime before importing it now works.
;;   - 27-http-json-fetch.scm: cvm/http.c grew a real TLS client path
;;     (libssl, always-on certificate + hostname verification) -- https://
;;     just works now, see http.c's own header comment.
;;   - 34-actor-ping-pong.scm: cvm/actor.c's node-address now accepts a
;;     bare symbol (not just a string or actor-ref), and
;;     move_context_to_system no longer lets a moved-in actor's id collide
;;     with a freshly spawned one in its new system (the actual cause of
;;     this example's old hang -- a <down> notification could be
;;     misdelivered to the wrong same-id context).
;;   - 35-mux-router.scm: rewritten to spawn the router on a background
;;     (creme actor) thread with a fixed port and retry-connect the first
;;     request, matching spec/creme/http_spec.scm's own established
;;     pattern -- cvm's mux-listen! blocks its calling thread forever by
;;     design and never returns the port it bound to.
;;   - 37-raft-kv-store.scm: modules/creme/raft.sld's cond-expand used to
;;     be evaluated by the NATIVE process doing the --emit-cvm compile
;;     (which always has the FFI raft family registered), not by cvm (the
;;     actual target), so it wrongly picked the FFI branch even when
;;     targeting cvm; fixed generically via Interpreter#emitting_for_cvm.
;;     cvm/builtins.c also gained a real `read` datum parser (previously
;;     unbound under --emit-cvm mode entirely, only ever defined inside
;;     cvm's separate "compiler mode"), which (creme raft-machine)'s
;;     command encode/decode needs. examples/39-raft-scheme-kv-store.scm
;;     (a near-duplicate demo of the same underlying raft-scheme engine)
;;     was removed once this one genuinely covered both backends through
;;     the same public (creme raft) API.
;;
;; Run with:
;;   ./bin/creme spec/creme/examples_cvm_spec.scm
;;   ./bin/creme --self-hosted spec/creme/examples_cvm_spec.scm
;;   ./cvm/cvm spec/creme/examples_cvm_spec.scm
;; All three spawn the exact same `./bin/creme --cvm <path>` subprocess
;; per example, so all three report identical results.
;; ===========================================================================

(import (scheme base) (scheme cxr) (scheme write) (creme spec) (creme process))

(define (cvm-runs-cleanly? path)
  (cadddr (process-run "./bin/creme" (list "--cvm" path))))

(define (it-runs-under-cvm name path)
  (it name (should-be-true? (cvm-runs-cleanly? path))))

(describe "examples/*.scm under cvm (bin/creme --cvm)"
  (it-runs-under-cvm "01-bigdecimal-invoice-total.scm" "examples/01-bigdecimal-invoice-total.scm")
  (it-runs-under-cvm "02-math-quadratic-solver.scm" "examples/02-math-quadratic-solver.scm")
  (it-runs-under-cvm "03-random-password-generator.scm" "examples/03-random-password-generator.scm")
  (it-runs-under-cvm "04-digest-integrity-checker.scm" "examples/04-digest-integrity-checker.scm")
  (it-runs-under-cvm "05-regex-log-analyzer.scm" "examples/05-regex-log-analyzer.scm")
  (it-runs-under-cvm "06-json-config-loader.scm" "examples/06-json-config-loader.scm")
  (it-runs-under-cvm "07-time-process-stopwatch.scm" "examples/07-time-process-stopwatch.scm")
  (it-runs-under-cvm "08-env-json-report.scm" "examples/08-env-json-report.scm")
  (it-runs-under-cvm "09-string-template-engine.scm" "examples/09-string-template-engine.scm")
  (it-runs-under-cvm "10-random-dice-roller.scm" "examples/10-random-dice-roller.scm")
  (it-runs-under-cvm "11-word-frequency-counter.scm" "examples/11-word-frequency-counter.scm")
  (it-runs-under-cvm "12-vector-matrix-ops.scm" "examples/12-vector-matrix-ops.scm")
  (it-runs-under-cvm "13-json-data-transform.scm" "examples/13-json-data-transform.scm")
  (it-runs-under-cvm "14-process-build-pipeline.scm" "examples/14-process-build-pipeline.scm")
  (it-runs-under-cvm "15-digest-base64-roundtrip.scm" "examples/15-digest-base64-roundtrip.scm")
  (it-runs-under-cvm "16-bigdecimal-currency-converter.scm" "examples/16-bigdecimal-currency-converter.scm")
  (it-runs-under-cvm "17-random-lottery-drawer.scm" "examples/17-random-lottery-drawer.scm")
  (it-runs-under-cvm "18-regex-email-validator.scm" "examples/18-regex-email-validator.scm")
  (it-runs-under-cvm "19-env-feature-flags.scm" "examples/19-env-feature-flags.scm")
  (it-runs-under-cvm "20-time-json-event-log.scm" "examples/20-time-json-event-log.scm")
  (it-runs-under-cvm "21-sql-todo-tracker.scm" "examples/21-sql-todo-tracker.scm")
  (it-runs-under-cvm "22-sxql-report-builder.scm" "examples/22-sxql-report-builder.scm")
  (pending "24-tui-try-scheme.scm (drives an interactive terminal UI)")
  (pending "25-rfc8439-secure-message.scm (unbound variable: rfc8439-random-key)")
  (it-runs-under-cvm "26-import-generated-library.scm" "examples/26-import-generated-library.scm")
  (it-runs-under-cvm "27-http-json-fetch.scm" "examples/27-http-json-fetch.scm")
  (it-runs-under-cvm "28-r7rs-forms-task-runner.scm" "examples/28-r7rs-forms-task-runner.scm")
  (it-runs-under-cvm "29-rational-hashtable-gradebook.scm" "examples/29-rational-hashtable-gradebook.scm")
  (it-runs-under-cvm "30-bytevector-checksum.scm" "examples/30-bytevector-checksum.scm")
  (it-runs-under-cvm "31-exception-handling-pipeline.scm" "examples/31-exception-handling-pipeline.scm")
  (it-runs-under-cvm "32-dynamic-wind-resource-tracking.scm" "examples/32-dynamic-wind-resource-tracking.scm")
  (it-runs-under-cvm "33-complex-number-mandelbrot.scm" "examples/33-complex-number-mandelbrot.scm")
  (it-runs-under-cvm "34-actor-ping-pong.scm" "examples/34-actor-ping-pong.scm")
  (it-runs-under-cvm "35-mux-router.scm" "examples/35-mux-router.scm")
  (it-runs-under-cvm "36-html-builder.scm" "examples/36-html-builder.scm")
  (it-runs-under-cvm "37-raft-kv-store.scm" "examples/37-raft-kv-store.scm")
  (it-runs-under-cvm "38-memoized-fib.scm" "examples/38-memoized-fib.scm")
  (it-runs-under-cvm "39-ffi-libm-caller.scm" "examples/39-ffi-libm-caller.scm")
  (it-runs-under-cvm "40-ffi-struct-pointer-clock.scm" "examples/40-ffi-struct-pointer-clock.scm")
  (it-runs-under-cvm "41-ffi-record-file-handle.scm" "examples/41-ffi-record-file-handle.scm")
  (it-runs-under-cvm "demo.scm" "examples/demo.scm"))

(spec-summary!)
