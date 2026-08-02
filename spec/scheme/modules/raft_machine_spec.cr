require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (scheme cxr) (creme raft) (creme raft-machine) (creme hash-table) (creme extra) (creme string)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (scheme cxr) (creme raft) (creme raft-machine) (creme hash-table) (creme extra) (creme string)) #{src}")
end

# A 3-node in-memory KV-store cluster built entirely with the raft-machine
# DSL, shared by every example below. No raft-transport-in-memory-reset! —
# raft-cluster namespaces every id itself, so concurrent clusters (one per
# `it` block, all in the same process) never collide.
private def cluster_setup : String
  <<-SCHEME
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
  SCHEME
end

describe "raft-machine module" do
  it "raft-cluster wires each node's peers to every other (namespaced) id" do
    w(<<-SCHEME).should eq("(#t #t #t)")
      (define seen '())
      (define nodes
        (raft-cluster '("a" "b" "c")
          (lambda (id peers) (set! seen (cons (cons id peers) seen)) id)))
      (define ids (map car seen))
      (define (prefix id) (car (string-split id ":")))
      (define (peers-of id) (cdr (assoc id seen)))
      (list
        ;; every id shares this one raft-cluster call's namespace prefix
        (and (string=? (prefix (car ids)) (prefix (cadr ids)))
             (string=? (prefix (cadr ids)) (prefix (caddr ids))))
        ;; no id appears in its own peer list
        (every (lambda (id) (not (member id (peers-of id)))) ids)
        ;; every node sees the other two as peers
        (every (lambda (id) (= (length (peers-of id)) 2)) ids))
      SCHEME
  end

  it "raft-sexp->bytevector/raft-bytevector->sexp round-trip arbitrary data" do
    w("(raft-bytevector->sexp (raft-sexp->bytevector '(set widget-count 7)))").should eq("(set widget-count 7)")
  end

  it "raft-commands dispatches by command head and encodes the clause's result" do
    w(<<-SCHEME).should eq("ok")
      #{cluster_setup}
      (define set-response (raft-bytevector->sexp (raft-propose! leader (raft-sexp->bytevector '(set x 42)))))
      (for-each raft-stop! nodes)
      set-response
      SCHEME
  end

  it "raft-read after a commit returns the applied value" do
    w(<<-SCHEME).should eq("42")
      #{cluster_setup}
      (raft-propose! leader (raft-sexp->bytevector '(set x 42)))
      (define get-response (raft-bytevector->sexp (raft-read leader (raft-sexp->bytevector '(get x)))))
      (for-each raft-stop! nodes)
      get-response
      SCHEME
  end

  # Calls the apply-proc lambda built by raft-commands directly rather than
  # through an actual raft-node/raft-propose! — an unknown-command error
  # raised from inside a real node's apply-proc would crash that node's
  # private event-loop fiber without ever resolving the pending
  # raft-propose! response channel, hanging the caller forever instead of
  # raising. Exercising the macro's own dispatcher in isolation avoids that
  # and is a more precise unit test of raft-commands anyway.
  it "raft-commands raises on an unknown command" do
    expect_raises(Creme::SchemeRuntimeError, /unknown command/) do
      run(<<-SCHEME)
        (define apply-proc (raft-commands ((set key value) 'ok) ((get key) 'value)))
        (apply-proc (raft-sexp->bytevector '(delete x)))
        SCHEME
    end
  end
end
