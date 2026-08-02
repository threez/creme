require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme cxr) (creme raft-scheme) (creme hash-table) (creme process) (creme file)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (scheme cxr) (creme raft-scheme) (creme hash-table) (creme process) (creme file)) #{src}")
end

# A tiny in-memory 3-node KV-store cluster, shared by every example below.
# Unlike (creme raft), (creme raft-scheme)'s propose!/read speak plain
# s-expressions directly -- no bytevector encode/decode step needed.
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
      (raft-scheme-config 'election-timeout-min 30 'election-timeout-max 60 'heartbeat-interval 15)))

  (define cluster (raft-scheme-cluster '("n1" "n2" "n3") make-kv-node))
  (define nodes (map (lambda (id.node) (raft-scheme-start! (cdr id.node))) cluster))
  (define leader (raft-scheme-await-leader! nodes 3000))
  SCHEME
end

describe "(creme raft-scheme)" do
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
      (define set-response (raft-scheme-propose! leader '(set x 42)))
      (for-each raft-scheme-stop! nodes)
      set-response
      SCHEME
  end

  it "raft-scheme-read returns the applied value after a commit" do
    w(<<-SCHEME).should eq("42")
      #{cluster_setup}
      (raft-scheme-propose! leader '(set x 42))
      (define get-response (raft-scheme-read leader '(get x)))
      (for-each raft-scheme-stop! nodes)
      get-response
      SCHEME
  end

  it "raft-scheme-propose! on a non-leader raises not-leader" do
    expect_raises(Scheme::SchemeRuntimeError, /not leader/) do
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
      (raft-scheme-propose! leader '(set x 42))
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
          (raft-scheme-config 'election-timeout-min 30 'election-timeout-max 60 'heartbeat-interval 15)))

      (define transport (raft-scheme-transport-in-memory))
      (define n1 (raft-scheme-start! (make-kv-node "n1" '("n2") transport)))
      (define n2 (raft-scheme-start! (make-kv-node "n2" '("n1") transport)))
      (define leader (raft-scheme-await-leader! (list n1 n2) 3000))
      (define n3 (raft-scheme-start! (make-kv-node "n3" '() transport)))
      (raft-scheme-add-peer! leader "n3")
      (raft-scheme-propose! leader '(set z 9))
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
      (raft-scheme-propose! leader '(set x 1))
      (define transport (list-ref (cdr (car cluster)) 4))
      (define leader-id (raft-scheme-leader leader))
      (define other-ids (drop-str '("n1" "n2" "n3") leader-id))
      (for-each (lambda (id) (raft-scheme-transport-partition! transport leader-id id)) other-ids)
      (define others (drop-eq nodes leader))
      (define new-leader (raft-scheme-await-leader! others 5000))
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
          (raft-scheme-config 'election-timeout-min 30 'election-timeout-max 60 'heartbeat-interval 15)))

      (define t1 (raft-scheme-transport-in-memory))
      (define node1 (raft-scheme-start! (make-kv-node "n1" '() t1)))
      (raft-scheme-await-leader! (list node1) 3000)
      (raft-scheme-propose! node1 '(set a 1))
      (raft-scheme-propose! node1 '(set b 2))
      (raft-scheme-snapshot! node1)
      (raft-scheme-propose! node1 '(set c 3))
      (raft-scheme-stop! node1)

      (define t2 (raft-scheme-transport-in-memory))
      (define node2 (raft-scheme-start! (make-kv-node "n1" '() t2)))
      (raft-scheme-await-leader! (list node2) 3000)
      (define result (list (raft-scheme-read node2 '(get a))
                            (raft-scheme-read node2 '(get b))
                            (raft-scheme-read node2 '(get c))))
      (raft-scheme-stop! node2)
      (delete-file path)
      result
      SCHEME
  end
end
