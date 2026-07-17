require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (scheme read) (scheme cxr) (creme raft) (creme hash-table)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (scheme read) (scheme cxr) (creme raft) (creme hash-table)) #{src}")
end

# A tiny in-memory 3-node KV-store cluster, shared by every example below.
# Commands/responses are s-expressions encoded to bytevectors via write/read
# + string->utf8/utf8->string; the state machine keeps its data in a
# (creme hash-table). Short election/heartbeat timeouts keep specs fast.
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
      (raft-config '((election-timeout-min . 30) (election-timeout-max . 60) (heartbeat-interval . 15)))))

  (define n1 (make-kv-node "n1" (list "n2" "n3")))
  (define n2 (make-kv-node "n2" (list "n1" "n3")))
  (define n3 (make-kv-node "n3" (list "n1" "n2")))
  (define nodes (list n1 n2 n3))
  (for-each raft-start! nodes)
  (define leader (raft-await-leader! nodes 3000))
  SCHEME
end

describe "raft module" do
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
      (define set-response (decode (raft-propose! leader (encode '(set x 42)))))
      (for-each raft-stop! nodes)
      set-response
      SCHEME
  end

  it "raft-read returns the applied value after a commit" do
    w(<<-SCHEME).should eq("42")
      #{cluster_setup}
      (raft-propose! leader (encode '(set x 42)))
      (define get-response (decode (raft-read leader (encode '(get x)))))
      (for-each raft-stop! nodes)
      get-response
      SCHEME
  end

  it "raft-propose! on a non-leader raises NotLeader" do
    expect_raises(Scheme::SchemeRuntimeError, /raft-propose!/) do
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
      (raft-propose! leader (encode '(set x 42)))
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
