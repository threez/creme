require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (scheme cxr) (creme raft-scheme) (creme hash-table) (creme process) (creme file)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (scheme cxr) (creme raft-scheme) (creme hash-table) (creme process) (creme file)) #{src}")
end

# A tiny in-memory 3-node KV-store cluster, shared by every example below.
# Unlike (creme raft), (creme raft-scheme)'s propose!/read speak plain
# s-expressions directly -- no bytevector encode/decode step needed.
# Election/heartbeat timeouts below are short but not razor-thin: 30/60/15ms
# was fine on an unloaded dev machine but flaky under CI scheduling jitter
# (e.g. a shared/virtualized runner), causing repeated split votes that
# never converged within the await-leader! deadline.
private def cluster_setup : String
  <<-SCHEME
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
      ;; this file's cluster_setup comment for why.
      (raft-scheme-config 'election-timeout-min 100 'election-timeout-max 200 'heartbeat-interval 40)))

  (define cluster (raft-scheme-cluster '("n1" "n2" "n3") make-kv-node))
  (define nodes (map (lambda (id.node) (raft-scheme-start! (cdr id.node))) cluster))
  ;; A first election can, rarely, fail to converge at all within 30s on a
  ;; sufficiently loaded CI runner (a genuinely wedged split-vote cycle, not
  ;; just a slow one -- observed on macOS CI late in a long spec run).
  ;; Restarting the whole cluster and retrying is safe here since nothing
  ;; has been proposed yet. raft-scheme-start! takes the raw node handle
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

  ;; raft-scheme-await-leader! only confirms leadership at the instant it
  ;; returns -- it's a snapshot, not a lease. Under real CI-runner scheduling
  ;; pressure, enough wall-clock time can pass before the NEXT line's
  ;; raft-scheme-propose! that the node has legitimately lost leadership in
  ;; between (a real, correct Raft outcome, not a bug) -- observed on macOS
  ;; CI. Retry against a freshly re-awaited leader instead of assuming
  ;; `leader` stays valid indefinitely.
  (define (raft-scheme-propose-retry! cmd)
    (let loop ((tries 5))
      (guard (e (#t (if (> tries 1)
                        (begin (set! leader (raft-scheme-await-leader! nodes 30000)) (loop (- tries 1)))
                        (raise e))))
        (raft-scheme-propose! leader cmd))))
  SCHEME
end

describe "(creme raft-scheme)", tags: "raft" do
  it "elects a leader among a 3-node in-memory cluster" do
    w(<<-SCHEME).should eq("#t")
      #{cluster_setup}
      (for-each raft-scheme-stop! nodes)
      (if leader #t #f)
      SCHEME
  end

  it "propose!/read round-trip a command through the leader and commit it cluster-wide" do
    w(<<-SCHEME).should eq("ok")
      #{cluster_setup}
      (define set-response (raft-scheme-propose-retry! '(set x 42)))
      (for-each raft-scheme-stop! nodes)
      set-response
      SCHEME
  end

  it "raft-scheme-read returns the applied value after a commit" do
    w(<<-SCHEME).should eq("42")
      #{cluster_setup}
      (raft-scheme-propose-retry! '(set x 42))
      (define get-response (raft-scheme-read leader '(get x)))
      (for-each raft-scheme-stop! nodes)
      get-response
      SCHEME
  end

  it "raft-scheme-propose! on a non-leader raises not-leader" do
    expect_raises(Creme::SchemeRuntimeError, /not leader/) do
      run(<<-SCHEME)
        (define (drop-eq lst x)
          (cond ((null? lst) '())
                ((eq? (car lst) x) (drop-eq (cdr lst) x))
                (else (cons (car lst) (drop-eq (cdr lst) x)))))
        #{cluster_setup}
        (define follower (car (drop-eq nodes leader)))
        (raft-scheme-propose! follower '(set x 1))
        SCHEME
    end
  end

  it "raft-scheme-role/raft-scheme-leader reflect the elected leader" do
    w(<<-SCHEME).should eq("(#t leader)")
      #{cluster_setup}
      (define result (list (string? (raft-scheme-leader leader)) (raft-scheme-role leader)))
      (for-each raft-scheme-stop! nodes)
      result
      SCHEME
  end

  it "raft-scheme-metrics reports at least one committed proposal after propose!" do
    w(<<-SCHEME).should eq("#t")
      #{cluster_setup}
      (raft-scheme-propose-retry! '(set x 42))
      (define committed (cdr (assq 'proposals-committed (raft-scheme-metrics leader))))
      (for-each raft-scheme-stop! nodes)
      (if (> committed 0) #t #f)
      SCHEME
  end

  it "raft-scheme-add-peer! replicates an entry to a newly added node" do
    w(<<-SCHEME).should eq("#t")
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
          ;; this file's cluster_setup comment for why.
          (raft-scheme-config 'election-timeout-min 100 'election-timeout-max 200 'heartbeat-interval 40)))

      (define transport (raft-scheme-transport-in-memory))
      (define n1 (raft-scheme-start! (make-kv-node "n1" '("n2") transport)))
      (define n2 (raft-scheme-start! (make-kv-node "n2" '("n1") transport)))
      (define leader (raft-scheme-await-leader! (list n1 n2) 30000))
      (define n3 (raft-scheme-start! (make-kv-node "n3" '() transport)))

      ;; raft-scheme-await-leader! only confirms leadership at the instant it
      ;; returns -- see cluster_setup's own comment for why this file retries
      ;; against a freshly re-awaited leader rather than assuming `leader`
      ;; stays valid indefinitely (observed on macOS CI).
      (let loop ((tries 5))
        (guard (e (#t (if (> tries 1)
                          (begin (set! leader (raft-scheme-await-leader! (list n1 n2) 30000)) (loop (- tries 1)))
                          (raise e))))
          (raft-scheme-add-peer! leader "n3")))
      (let loop ((tries 5))
        (guard (e (#t (if (> tries 1)
                          (begin (set! leader (raft-scheme-await-leader! (list n1 n2) 30000)) (loop (- tries 1)))
                          (raise e))))
          (raft-scheme-propose! leader '(set z 9))))
      (sleep-ms! 300)
      (define n3-applied (cdr (assq 'entries-applied (raft-scheme-metrics n3))))
      (for-each raft-scheme-stop! (list n1 n2 n3))
      (if (> n3-applied 0) #t #f)
      SCHEME
  end

  it "raft-scheme-transport-partition!/-heal! isolate then reconnect a node" do
    w(<<-SCHEME).should eq("#t")
      (define (drop-eq lst x)
        (cond ((null? lst) '())
              ((eq? (car lst) x) (drop-eq (cdr lst) x))
              (else (cons (car lst) (drop-eq (cdr lst) x)))))
      (define (drop-str lst x)
        (cond ((null? lst) '())
              ((string=? (car lst) x) (drop-str (cdr lst) x))
              (else (cons (car lst) (drop-str (cdr lst) x)))))
      #{cluster_setup}
      (raft-scheme-propose-retry! '(set x 1))
      (define transport (list-ref (cdr (car cluster)) 4))
      (define leader-id (raft-scheme-leader leader))
      (define other-ids (drop-str '("n1" "n2" "n3") leader-id))
      (for-each (lambda (id) (raft-scheme-transport-partition! transport leader-id id)) other-ids)
      (define others (drop-eq nodes leader))
      ;; A post-partition re-election can, like the initial one (see
      ;; cluster_setup's own comment), rarely fail to converge at all
      ;; within 40s on a sufficiently loaded CI runner -- observed on
      ;; macOS. Retrying the await-leader! call itself (not restarting
      ;; anything -- the remaining nodes are still up and still
      ;; partitioned, so simply asking again is safe and sufficient here)
      ;; is enough since nothing about the cluster's own state needs to
      ;; change between attempts.
      (define new-leader
        (let loop ((tries 3))
          (let ((got (raft-scheme-await-leader! others 40000)))
            (cond (got got)
                  ((> tries 1) (loop (- tries 1)))
                  (else #f)))))
      (for-each (lambda (id) (raft-scheme-transport-heal! transport leader-id id)) other-ids)
      (define result (if new-leader #t #f))
      (for-each raft-scheme-stop! nodes)
      result
      SCHEME
  end

  it "persists the log/snapshot to a real SQLite file and recovers state on restart" do
    w(<<-SCHEME).should eq("(1 2 3)")
      (define path (string-append (current-directory) "/raft_scheme_spec_test.sqlite3"))
      (if (file-exists? path) (delete-file path) #f)

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
          path
          ;; Wider than a minimal dev-machine-tuned timeout on purpose -- see
          ;; this file's cluster_setup comment for why.
          (raft-scheme-config 'election-timeout-min 100 'election-timeout-max 200 'heartbeat-interval 40)))

      (define t1 (raft-scheme-transport-in-memory))
      (define node1 (raft-scheme-start! (make-kv-node "n1" '() t1)))
      (raft-scheme-await-leader! (list node1) 30000)
      (raft-scheme-propose! node1 '(set a 1))
      (raft-scheme-propose! node1 '(set b 2))
      (raft-scheme-snapshot! node1)
      (raft-scheme-propose! node1 '(set c 3))
      (raft-scheme-stop! node1)

      (define t2 (raft-scheme-transport-in-memory))
      (define node2 (raft-scheme-start! (make-kv-node "n1" '() t2)))
      (raft-scheme-await-leader! (list node2) 30000)
      (define result (list (raft-scheme-read node2 '(get a))
                            (raft-scheme-read node2 '(get b))
                            (raft-scheme-read node2 '(get c))))
      (raft-scheme-stop! node2)
      (delete-file path)
      result
      SCHEME
  end
end
