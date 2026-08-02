;; ===========================================================================
;; Proves the `(creme raft)` cond-expand DISPATCH ITSELF resolves correctly
;; under real icecreme -- as opposed to spec/creme/raft_scheme_spec.scm (prior
;; phase), which proves the pure-Scheme ENGINE works by including
;; raft-scheme/core.scm directly, bypassing (creme raft)/cond-expand
;; entirely. This file instead imports `(creme raft)`/`(creme raft-machine)`
;; the ORDINARY way, same as any native script (and the same way
;; examples/37-raft-kv-store.scm does) -- if icecreme's self-hosted compiler
;; didn't correctly resolve modules/creme/raft.sld as a real file-based
;; library (reading it, evaluating its own cond-expand, and transitively
;; registering whatever native families its `else` branch needs -- actor/
;; sql/process/hash-table/random -- even though THIS file's own top-level
;; `(import ...)` never mentions any of them directly), this file would fail
;; with "unbound variable" the moment raft-node/raft-propose!/etc were
;; called. See modules/creme/raft.sld's own header comment for the
;; `(library (creme builtin raft))` discriminator this relies on.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/raft_dispatch_spec.scm
;;   ./bin/creme --self-hosted spec/creme/raft_dispatch_spec.scm
;;   ./icecreme/icecreme spec/creme/raft_dispatch_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme read) (scheme cxr)
        (creme raft) (creme raft-machine) (creme hash-table) (creme spec))

(describe "(creme raft) transparent dispatch"
  (it "raft-node/raft-propose!/raft-read work when imported the ordinary way (not via direct include)"
    (raft-transport-in-memory-reset!)
    (define (make-kv-node id peers)
      (define store (make-hash-table))
      (raft-node id peers
        (raft-state-machine
          (raft-commands
            ((set key value) (hash-table-set! store key value) 'ok)
            ((get key) (hash-table-ref store key (lambda () 'missing))))
          raft-noop-snapshot
          raft-noop-restore)
        (raft-transport-in-memory id)
        (raft-log-in-memory)
        (raft-config '((election-timeout-min . 30) (election-timeout-max . 60) (heartbeat-interval . 15)))))
    (define nodes (raft-cluster '("n1" "n2" "n3") make-kv-node))
    (for-each raft-start! nodes)
    (define leader (raft-await-leader! nodes 3000))
    (should-be-true? (if leader #t #f))
    (define set-response (raft-bytevector->sexp (raft-propose! leader (raft-sexp->bytevector '(set widget-count 7)))))
    (define get-response (raft-bytevector->sexp (raft-read leader (raft-sexp->bytevector '(get widget-count)))))
    (for-each raft-stop! nodes)
    (should-equal? set-response 'ok)
    (should-equal? get-response 7)))

(spec-summary!)
