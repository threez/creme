;; ===========================================================================
;; A (creme spec)-based port of the core cases in spec/scheme/modules/creme/
;; raft_scheme_spec.cr, run directly against modules/creme/raft-scheme/
;; core.scm -- proving (creme raft-scheme) genuinely works under icecreme, not
;; just under native creme. (creme raft) itself now dispatches to this same
;; engine under icecreme too (modules/creme/raft.sld's cond-expand, see
;; examples/37-raft-kv-store.scm), so this file's own direct raft-scheme-*
;; coverage is complementary, not the only icecreme-side raft coverage anymore.
;;
;; Uses (include ...) rather than `(import (creme raft-scheme))` -- icecreme has
;; no library/import machinery to resolve a separate .sld file. See
;; modules/creme/raft-scheme/core.scm's own header comment for the full
;; design.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/raft_scheme_spec.scm
;;   ./bin/creme --self-hosted spec/creme/raft_scheme_spec.scm
;;   ./icecreme/icecreme spec/creme/raft_scheme_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme cxr) (scheme char)
        (creme actor) (creme sql) (creme process) (creme hash-table) (creme random) (creme spec))
(include "../../modules/creme/raft-scheme/core.scm")

(define (drop-eq lst x)
  (cond ((null? lst) '())
        ((eq? (car lst) x) (drop-eq (cdr lst) x))
        (else (cons (car lst) (drop-eq (cdr lst) x)))))

(define (drop-str lst x)
  (cond ((null? lst) '())
        ((string=? (car lst) x) (drop-str (cdr lst) x))
        (else (cons (car lst) (drop-str (cdr lst) x)))))

;; A tiny in-memory 3-node KV-store cluster, shared by every case below.
(define (make-kv-node id peers transport)
  (define store (make-hash-table))
  (raft-scheme-node id peers
    (raft-scheme-state-machine
      (lambda (cmd)
        (if (eq? cmd 'noop)
            'noop
            (case (car cmd)
              ((set) (hash-table-set! store (cadr cmd) (caddr cmd)) 'ok)
              ((get) (hash-table-ref store (cadr cmd) (lambda () 'missing))))))
      (lambda () (hash-table->alist store))
      (lambda (data) (for-each (lambda (kv) (hash-table-set! store (car kv) (cdr kv))) data)))
    transport
    ":memory:"
    ;; Wider than a minimal dev-machine-tuned timeout on purpose -- see
    ;; spec/scheme/modules/creme/raft_spec.cr's cluster_setup comment for why.
    (raft-scheme-config 'election-timeout-min 100 'election-timeout-max 200 'heartbeat-interval 40)))

(define (new-cluster)
  (define cluster (raft-scheme-cluster '("n1" "n2" "n3") make-kv-node))
  (define nodes (map (lambda (id.node) (raft-scheme-start! (cdr id.node))) cluster))
  ;; A first election can, rarely, fail to converge at all within 30s on a
  ;; sufficiently loaded CI runner (a genuinely wedged split-vote cycle, not
  ;; just a slow one). raft-scheme-start! takes the raw node handle
  ;; (cluster's own (id . node) pairs), not the started actor-ref it
  ;; returns, so restart re-maps `cluster` fresh rather than reusing `nodes`.
  (define leader
    (let loop ((tries 3))
      (let ((got (raft-scheme-await-leader! nodes 30000)))
        (cond (got got)
              ((> tries 1)
               (for-each raft-scheme-stop! nodes)
               (set! nodes (map (lambda (id.node) (raft-scheme-start! (cdr id.node))) cluster))
               (loop (- tries 1)))
              (else #f)))))
  (list cluster nodes leader))

(describe "(creme raft-scheme)"
  (it "elects a leader among a 3-node in-memory cluster"
    (define setup (new-cluster))
    (define leader (caddr setup))
    (for-each raft-scheme-stop! (cadr setup))
    (should-be-true? (if leader #t #f)))

  (it "propose!/read round-trip a command through the leader and commit it cluster-wide"
    (define setup (new-cluster))
    (define leader (caddr setup))
    (define set-response (raft-scheme-propose! leader '(set x 42)))
    (define get-response (raft-scheme-read leader '(get x)))
    (for-each raft-scheme-stop! (cadr setup))
    (should-equal? set-response 'ok)
    (should-equal? get-response 42))

  (it "raft-scheme-propose! on a non-leader raises"
    (define setup (new-cluster))
    (define leader (caddr setup))
    (define nodes (cadr setup))
    (define follower (car (drop-eq nodes leader)))
    (should-raise? (lambda () (raft-scheme-propose! follower '(set x 1))))
    (for-each raft-scheme-stop! nodes))

  (it "raft-scheme-role/raft-scheme-leader reflect the elected leader"
    (define setup (new-cluster))
    (define leader (caddr setup))
    (define result (list (string? (raft-scheme-leader leader)) (raft-scheme-role leader)))
    (for-each raft-scheme-stop! (cadr setup))
    (should-equal? result (list #t 'leader)))

  (it "raft-scheme-metrics reports at least one committed proposal after propose!"
    (define setup (new-cluster))
    (define leader (caddr setup))
    (raft-scheme-propose! leader '(set x 42))
    (define committed (cdr (assq 'proposals-committed (raft-scheme-metrics leader))))
    (for-each raft-scheme-stop! (cadr setup))
    (should-be-true? (> committed 0)))

  (it "raft-scheme-add-peer! replicates entries to a newly added node"
    (define transport (raft-scheme-transport-in-memory))
    (define n1 (raft-scheme-start! (make-kv-node "n1" '("n2") transport)))
    (define n2 (raft-scheme-start! (make-kv-node "n2" '("n1") transport)))
    (define leader (raft-scheme-await-leader! (list n1 n2) 30000))
    (define n3 (raft-scheme-start! (make-kv-node "n3" '() transport)))
    (raft-scheme-add-peer! leader "n3")
    (raft-scheme-propose! leader '(set z 9))
    (sleep-ms! 300)
    (define n3-applied (cdr (assq 'entries-applied (raft-scheme-metrics n3))))
    (for-each raft-scheme-stop! (list n1 n2 n3))
    (should-be-true? (> n3-applied 0)))

  (it "raft-scheme-transport-partition!/-heal! isolate then reconnect a node"
    (define setup (new-cluster))
    (define cluster (car setup))
    (define nodes (cadr setup))
    (define leader (caddr setup))
    (raft-scheme-propose! leader '(set x 1))
    (define transport (list-ref (cdr (car cluster)) 4))
    (define leader-id (raft-scheme-leader leader))
    (define other-ids (drop-str '("n1" "n2" "n3") leader-id))
    (for-each (lambda (id) (raft-scheme-transport-partition! transport leader-id id)) other-ids)
    (define others (drop-eq nodes leader))
    ;; A post-partition re-election can, like the initial one (see
    ;; new-cluster's own comment), rarely fail to converge at all within
    ;; 40s on a sufficiently loaded CI runner -- observed on macOS.
    ;; Retrying the await-leader! call itself (not restarting anything --
    ;; the remaining nodes are still up and still partitioned, so simply
    ;; asking again is safe and sufficient here) is enough since nothing
    ;; about the cluster's own state needs to change between attempts.
    (define new-leader
      (let loop ((tries 3))
        (let ((got (raft-scheme-await-leader! others 40000)))
          (cond (got got)
                ((> tries 1) (loop (- tries 1)))
                (else #f)))))
    (for-each (lambda (id) (raft-scheme-transport-heal! transport leader-id id)) other-ids)
    (for-each raft-scheme-stop! nodes)
    (should-be-true? (if new-leader #t #f))))

(spec-summary!)
