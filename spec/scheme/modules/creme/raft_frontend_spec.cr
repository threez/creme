require "../../../spec_helper"

# Proves modules/creme/raft-scheme/frontend.scm satisfies (creme raft)'s own
# contract -- same scenarios as raft_spec.cr (which always exercises the
# real threez/raft.cr FFI backend under native, since `(library (creme
# builtin raft))` is always true there), run here directly against the
# pure-Scheme frontend by reproducing the exact same prelude modules/creme/
# raft.sld's cond-expand `else` branch uses, bypassing cond-expand entirely
# so this spec is independent of which branch native's own build happens to
# pick. See modules/creme/raft.sld's own header comment for why cond-expand
# reliably picks the OTHER branch under cvm instead.
private PRELUDE = <<-SCHEME
  (import (scheme base) (scheme write) (scheme read) (scheme cxr) (scheme char)
          (creme actor) (creme sql) (creme process) (creme hash-table) (creme random))
  (include "raft-scheme/core.scm")
  (include "raft-scheme/frontend.scm")
  SCHEME

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  interp.push_load_dir(File.expand_path("./modules/creme"))
  Scheme.run_source(interp, "#{PRELUDE} #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  interp.push_load_dir(File.expand_path("./modules/creme"))
  Scheme.run_source(interp, "#{PRELUDE} #{src}")
end

# Same shape as raft_spec.cr's own cluster_setup, but using bytevector
# commands/raft-machine-style encode/decode directly (this spec predates
# needing (creme raft-machine) itself, so it just inlines the same encode/
# decode raft_spec.cr's own cluster_setup uses).
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

describe "(creme raft) pure-Scheme frontend (modules/creme/raft-scheme/frontend.scm)" do
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

  it "raft-propose! on a non-leader raises" do
    expect_raises(Scheme::SchemeRuntimeError) do
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

  it "raft-add-peer! replicates an entry to a newly added node" do
    w(<<-SCHEME).should eq("#t")
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
      (define n1 (make-kv-node "n1" (list "n2")))
      (define n2 (make-kv-node "n2" (list "n1")))
      (for-each raft-start! (list n1 n2))
      (define leader (raft-await-leader! (list n1 n2) 3000))
      (define n3 (make-kv-node "n3" '()))
      (raft-start! n3)
      (raft-add-peer! leader "n3")
      (raft-propose! leader (encode '(set z 9)))
      (sleep-ms! 300)
      (define n3-applied (cdr (assq 'entries-applied (raft-metrics n3))))
      (for-each raft-stop! (list n1 n2 n3))
      (if (> n3-applied 0) #t #f)
      SCHEME
  end

  it "raft-transport-partition!/-heal! isolate then reconnect a node" do
    w(<<-SCHEME).should eq("#t")
      #{cluster_setup}
      (raft-propose! leader (encode '(set x 1)))
      (define leader-id (raft-leader leader))
      (define (drop-eq lst x)
        (cond ((null? lst) '())
              ((eq? (car lst) x) (drop-eq (cdr lst) x))
              (else (cons (car lst) (drop-eq (cdr lst) x)))))
      (define (drop-str lst x)
        (cond ((null? lst) '())
              ((string=? (car lst) x) (drop-str (cdr lst) x))
              (else (cons (car lst) (drop-str (cdr lst) x)))))
      (define other-ids (drop-str '("n1" "n2" "n3") leader-id))
      (for-each (lambda (id) (raft-transport-partition! leader-id id)) other-ids)
      (define others (drop-eq nodes leader))
      (define new-leader (raft-await-leader! others 5000))
      (for-each (lambda (id) (raft-transport-heal! leader-id id)) other-ids)
      (define result (if new-leader #t #f))
      (for-each raft-stop! nodes)
      result
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
