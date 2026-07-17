(import (scheme base) (scheme write) (creme raft) (creme raft-machine) (creme hash-table))

;; A tiny replicated key/value store: a 3-node in-memory Raft cluster (see
;; (creme raft)) built with (creme raft-machine)'s declarative sugar —
;; raft-commands handles the bytevector encode/decode, command dispatch, and
;; the empty-bytevector no-op guard raft-read's linearizability barrier
;; needs; raft-cluster wires up each node's peer list automatically, and
;; namespaces every id under the hood so this cluster can't collide with
;; any other in-memory cluster in the same process — no
;; raft-transport-in-memory-reset! needed.

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

(raft-transport-in-memory-reset!)

(define nodes (raft-cluster '("n1" "n2" "n3") make-kv-node))

(for-each raft-start! nodes)

(define leader (raft-await-leader! nodes 3000))

(if (not leader)
    (error "kv-store: no leader elected within timeout")
    (begin
      (display "leader elected: ") (display (raft-leader leader)) (newline)

      (display "set widget-count 7 -> ")
      (display (raft-bytevector->sexp (raft-propose! leader (raft-sexp->bytevector '(set widget-count 7)))))
      (newline)

      (display "get widget-count -> ")
      (display (raft-bytevector->sexp (raft-read leader (raft-sexp->bytevector '(get widget-count)))))
      (newline)

      (display "metrics: ") (display (raft-metrics leader)) (newline)))

(for-each raft-stop! nodes)
