require "../../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (scheme read) (scheme cxr) (creme raft) (creme hash-table)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (scheme read) (scheme cxr) (creme raft) (creme hash-table)) #{src}")
end

# A tiny in-memory 3-node KV-store cluster, shared by every example below.
# Commands/responses are s-expressions encoded to bytevectors via write/read
# + string->utf8/utf8->string; the state machine keeps its data in a
# (creme hash-table). Election/heartbeat timeouts are short (but not as
# short as they used to be -- 30/60/15ms was fine on an unloaded dev
# machine but flaky under CI scheduling jitter, e.g. on a shared/
# virtualized runner, causing repeated split votes that never converged
# within the await-leader! deadline) to keep specs reasonably fast while
# leaving real headroom.
private def cluster_setup : String
  <<-SCHEME
  (raft-transport-in-memory-reset!)

  (define (encode v)
    (let ((p (open-output-string)))
      (write v p)
      (string->utf8 (get-output-string p))))
  (define (decode bv) (read (open-input-string (utf8->string bv))))

  (define (make-kv-node id peers)
    (define store (make-hash-table))
    (raft-node id peers
      (raft-state-machine
        (lambda (cmd)
          (if (= (bytevector-length cmd) 0)
              (encode 'noop)
              (let ((form (decode cmd)))
                (case (car form)
                  ((set) (hash-table-set! store (cadr form) (caddr form)) (encode 'ok))
                  ((get) (encode (hash-table-ref store (cadr form) (lambda () 'missing))))
                  (else (encode 'unknown))))))
        (lambda () (encode 'no-snapshot))
        (lambda (bv) #t))
      (raft-transport-in-memory id)
      (raft-log-in-memory)
      (raft-config '((election-timeout-min . 100) (election-timeout-max . 200) (heartbeat-interval . 40)))))

  (define n1 (make-kv-node "n1" (list "n2" "n3")))
  (define n2 (make-kv-node "n2" (list "n1" "n3")))
  (define n3 (make-kv-node "n3" (list "n1" "n2")))
  (define nodes (list n1 n2 n3))
  (for-each raft-start! nodes)
  ;; A first election can, rarely, fail to converge at all within 30s on a
  ;; sufficiently loaded CI runner (a genuinely wedged split-vote cycle, not
  ;; just a slow one -- observed on macOS CI late in a long spec run).
  ;; Restarting the whole cluster and retrying is safe here since nothing
  ;; has been proposed yet.
  (define leader
    (let loop ((tries 3))
      (let ((got (raft-await-leader! nodes 30000)))
        (cond (got got)
              ((> tries 1)
               (for-each raft-stop! nodes)
               (for-each raft-start! nodes)
               (loop (- tries 1)))
              (else #f)))))

  ;; raft-await-leader! only confirms leadership at the instant it returns
  ;; (polls node.role.leader? every 10ms) -- it's a snapshot, not a lease.
  ;; Under real CI-runner scheduling pressure, enough wall-clock time can
  ;; pass before the NEXT line's raft-propose! that the node has legitimately
  ;; lost leadership in between (a real, correct Raft outcome, not a bug) --
  ;; observed on macOS CI. Retry against a freshly re-awaited leader instead
  ;; of assuming `leader` stays valid indefinitely.
  (define (raft-propose-retry! cmd)
    (let loop ((tries 5))
      (guard (e (#t (if (> tries 1)
                        (begin (set! leader (raft-await-leader! nodes 30000)) (loop (- tries 1)))
                        (raise e))))
        (raft-propose! leader cmd))))
  SCHEME
end

describe "raft module", tags: "raft" do
  it "elects a leader among a 3-node in-memory cluster" do
    w(<<-SCHEME).should eq("#t")
      #{cluster_setup}
      (for-each raft-stop! nodes)
      (if leader #t #f)
      SCHEME
  end

  it "propose!/read round-trip a command through the leader and commit it cluster-wide" do
    w(<<-SCHEME).should eq("ok")
      #{cluster_setup}
      (define set-response (decode (raft-propose-retry! (encode '(set x 42)))))
      (for-each raft-stop! nodes)
      set-response
      SCHEME
  end

  it "raft-read returns the applied value after a commit" do
    w(<<-SCHEME).should eq("42")
      #{cluster_setup}
      (raft-propose-retry! (encode '(set x 42)))
      (define get-response (decode (raft-read leader (encode '(get x)))))
      (for-each raft-stop! nodes)
      get-response
      SCHEME
  end

  it "raft-propose! on a non-leader raises NotLeader" do
    expect_raises(Creme::SchemeRuntimeError, /raft-propose!/) do
      run(<<-SCHEME)
        #{cluster_setup}
        (define follower (if (eq? leader n1) n2 n1))
        (raft-propose! follower (encode '(set x 1)))
        SCHEME
    end
  end

  it "raft-role/raft-leader reflect the elected leader" do
    w(<<-SCHEME).should eq("(#t leader)")
      #{cluster_setup}
      (define result (list (string? (raft-leader leader)) (raft-role leader)))
      (for-each raft-stop! nodes)
      result
      SCHEME
  end

  it "raft-metrics reports at least one committed proposal after propose!" do
    w(<<-SCHEME).should eq("#t")
      #{cluster_setup}
      (raft-propose-retry! (encode '(set x 42)))
      (define committed (cdr (assq 'proposals-committed (raft-metrics leader))))
      (for-each raft-stop! nodes)
      (if (> committed 0) #t #f)
      SCHEME
  end

  it "raft-node?/raft-log?/raft-transport?/raft-config?/raft-state-machine? predicates" do
    w(<<-SCHEME).should eq("(#t #t #t #t #t #f)")
      (define log (raft-log-in-memory))
      (define transport (raft-transport-in-memory "solo"))
      (define config (raft-config '()))
      (define sm (raft-state-machine (lambda (c) c) (lambda () (string->utf8 "")) (lambda (bv) #t)))
      (define node (raft-node "solo" '() sm transport log config))
      (list (raft-node? node) (raft-log? log) (raft-transport? transport)
            (raft-config? config) (raft-state-machine? sm) (raft-node? log))
      SCHEME
  end
end
