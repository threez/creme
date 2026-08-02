require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme actor) (creme actor-supervisor)) #{src}").write_string
end

# Forces at least one scheduling round-trip on the calling actor/fiber, so
# any other already-triggered fiber (e.g. a supervisor reacting to its own
# <down> copy) gets a chance to run before the caller proceeds — spawn only
# enqueues a fiber, it doesn't run it, so code right after a spawn/send!
# can't assume the spawned fiber has done anything yet without yielding
# via a blocking receive! like this one.
private def yield_a_bit : String
  <<-SCHEME
    (let ((echo (spawn (lambda () (send! (receive!) 'ok)))))
      (send! echo (self))
      (receive!))
    SCHEME
end

describe "actor-supervisor module" do
  it "starts each child and registers it under its spec's name" do
    w(<<-SCHEME).should eq("42")
      (define sup
        (start-supervisor
          (list (child-spec 'worker (lambda () (lambda () (send! (receive!) 42))) 'permanent))))
      #{yield_a_bit}
      (send! 'worker (self))
      (receive!)
      SCHEME
  end

  it "restarts a 'permanent child under the same name after it crashes" do
    w(<<-SCHEME).should eq("(#t #t)")
      (define (crasher)
        (lambda ()
          (let ((msg (receive!)))
            (if (eq? msg 'crash) (error "boom") (send! msg 'alive)))))
      (define sup
        (start-supervisor (list (child-spec 'worker crasher 'permanent))))
      #{yield_a_bit}
      (define original (whereis 'worker))
      (monitor original)
      (send! 'worker 'crash)
      (define reason-is-string (string? (down-reason (receive!))))
      #{yield_a_bit}
      #{yield_a_bit}
      (define restarted (not (string=? (actor-ref-id original) (actor-ref-id (whereis 'worker)))))
      (send! 'worker (self))
      (list (and restarted (eq? (receive!) 'alive)) reason-is-string)
      SCHEME
  end
end
