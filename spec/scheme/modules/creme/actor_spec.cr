require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme actor)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme actor)) #{src}")
end

describe "actor module" do
  it "spawns an actor and exchanges messages via send!/receive!" do
    w(<<-SCHEME).should eq("ok")
      (define echo (spawn (lambda () (send! (receive!) 'ok))))
      (send! echo (self))
      (receive!)
      SCHEME
  end

  it "self returns a ref that can be sent to from within the same actor" do
    w(<<-SCHEME).should eq("hi")
      (send! (self) 'hi)
      (receive!)
      SCHEME
  end

  it "register!/whereis resolve a name to a ref, #f when unregistered" do
    w(<<-SCHEME).should eq("(found missing)")
      (define a (spawn (lambda () (receive!))))
      (register! 'svc a)
      (list (if (whereis 'svc) 'found 'missing) (if (whereis 'nope) 'found 'missing))
      SCHEME
  end

  it "monitor delivers a <down> record with the crash reason" do
    w(<<-SCHEME).should eq(%((#t "boom")))
      (define c (spawn (lambda () (error "boom"))))
      (monitor c)
      (let ((d (receive!)))
        (list (down? d) (down-reason d)))
      SCHEME
  end

  it "down? is false for an ordinary record" do
    w(<<-SCHEME).should eq("#f")
      (define-record-type <pt> (make-pt x) pt? (x pt-x))
      (down? (make-pt 1))
      SCHEME
  end

  it "send! raises for an unknown registered name" do
    expect_raises(Scheme::SchemeRuntimeError, /no actor registered/) do
      run(%((send! 'nope 'hi)))
    end
  end

  it "delivers a message to a remote actor over a real TCP connection authenticated by the shared cookie" do
    w(<<-SCHEME).should eq("pong")
      (start-node "127.0.0.1" 0 "shared-secret")
      (define port (node-port))
      (register! 'svc (spawn (lambda () (send! (receive!) 'pong))))
      (start-node "127.0.0.1" 0 "shared-secret")
      (define ref (remote-ref (string-append "tcp://svc@127.0.0.1:" (number->string port))))
      (send! ref (self))
      (receive!)
      SCHEME
  end

  it "rejects a connection whose cookie doesn't match the server's" do
    expect_raises(Scheme::SchemeRuntimeError, /handshake/) do
      run(<<-SCHEME)
        (start-node "127.0.0.1" 0 "right-secret")
        (define port (node-port))
        (spawn (lambda () (receive!)))
        (register! 'svc (spawn (lambda () (receive!))))
        (start-node "127.0.0.1" 0 "WRONG-secret")
        (define ref (remote-ref (string-append "tcp://svc@127.0.0.1:" (number->string port))))
        (send! ref "hi")
        SCHEME
    end
  end

  it "round-trips a record and an actor ref as a message field over the network" do
    w(<<-SCHEME).should eq("7")
      (define-record-type <ping> (make-ping reply-to n) ping? (reply-to ping-reply-to) (n ping-n))
      (start-node "127.0.0.1" 0 "shared-secret")
      (define port (node-port))
      (register! 'svc
        (spawn (lambda ()
                 (let ((msg (receive!)))
                   (send! (ping-reply-to msg) (ping-n msg))))))
      (start-node "127.0.0.1" 0 "shared-secret")
      (define ref (remote-ref (string-append "tcp://svc@127.0.0.1:" (number->string port))))
      (send! ref (make-ping (self) 7))
      (receive!)
      SCHEME
  end

  it "an actor's own top-level define via eval does not leak into the parent's global env" do
    w(<<-SCHEME).should eq("(unbound parent-still-fine 7)")
      (import (scheme eval) (scheme repl))
      (define done
        (spawn (lambda ()
                 (eval '(define leaked-secret 42) (interaction-environment))
                 (send! (self) 'noop))))
      (monitor done)
      (receive!)
      (define parent-var 7)
      (list
        (if (guard (e (#t #f)) (eval 'leaked-secret (interaction-environment)) #t) 'leaked 'unbound)
        'parent-still-fine
        (eval 'parent-var (interaction-environment)))
      SCHEME
  end

  it "an actor's own library import via eval does not leak into the parent's loaded libraries" do
    w(<<-SCHEME).should eq(%("unbound-as-expected"))
      (import (scheme eval) (scheme repl))
      (define done
        (spawn (lambda ()
                 (eval '(import (creme regex)) (interaction-environment))
                 (send! (self) 'noop))))
      (monitor done)
      (receive!)
      (guard (e (#t "unbound-as-expected"))
        (eval '(regexp "a+") (interaction-environment))
        "LEAKED")
      SCHEME
  end

  # ---- unix: transport -------------------------------------------------------
  # Mirrors the three tcp: remote tests above, over a real Unix domain
  # socket instead. Each test gets its own throwaway socket path (cleaned up
  # after) rather than sharing one across examples.

  it "delivers a message to a remote actor over a real Unix domain socket authenticated by the shared cookie" do
    path = "/tmp/creme-actor-test-#{Random.new.hex(8)}.sock"
    begin
      w(<<-SCHEME).should eq("pong")
        (start-node 'unix "#{path}" "shared-secret")
        (register! 'svc (spawn (lambda () (send! (receive!) 'pong))))
        (start-node 'unix "#{path}-client" "shared-secret")
        (define ref (remote-ref "unix://svc@#{path}"))
        (send! ref (self))
        (receive!)
        SCHEME
    ensure
      File.delete(path) rescue nil
      File.delete("#{path}-client") rescue nil
    end
  end

  it "rejects a unix: connection whose cookie doesn't match the server's" do
    path = "/tmp/creme-actor-test-#{Random.new.hex(8)}.sock"
    begin
      expect_raises(Scheme::SchemeRuntimeError, /handshake/) do
        run(<<-SCHEME)
          (start-node 'unix "#{path}" "right-secret")
          (register! 'svc (spawn (lambda () (receive!))))
          (start-node 'unix "#{path}-client" "WRONG-secret")
          (define ref (remote-ref "unix://svc@#{path}"))
          (send! ref "hi")
          SCHEME
      end
    ensure
      File.delete(path) rescue nil
      File.delete("#{path}-client") rescue nil
    end
  end

  it "round-trips a record and an actor ref as a message field over a unix: socket" do
    path = "/tmp/creme-actor-test-#{Random.new.hex(8)}.sock"
    begin
      w(<<-SCHEME).should eq("7")
        (define-record-type <ping> (make-ping reply-to n) ping? (reply-to ping-reply-to) (n ping-n))
        (start-node 'unix "#{path}" "shared-secret")
        (register! 'svc
          (spawn (lambda ()
                   (let ((msg (receive!)))
                     (send! (ping-reply-to msg) (ping-n msg))))))
        (start-node 'unix "#{path}-client" "shared-secret")
        (define ref (remote-ref "unix://svc@#{path}"))
        (send! ref (make-ping (self) 7))
        (receive!)
        SCHEME
    ensure
      File.delete(path) rescue nil
      File.delete("#{path}-client") rescue nil
    end
  end

  it "node-address builds the correct URI for tcp/unix nodes" do
    path = "/tmp/creme-actor-test-#{Random.new.hex(8)}.sock"
    begin
      w(<<-SCHEME).should eq("(#t #t)")
        (define tcp-node (start-node 'tcp "127.0.0.1" 0 "cookie"))
        (define unix-node (start-node 'unix "#{path}" "cookie"))
        (list
          (string=? (node-address tcp-node 'svc)
                     (string-append "tcp://svc@127.0.0.1:" (number->string (node-port tcp-node))))
          (string=? (node-address unix-node 'svc) "unix://svc@#{path}"))
        SCHEME
    ensure
      File.delete(path) rescue nil
    end
  end

  # ---- local: transport -------------------------------------------------------
  # An in-process transport: two start-node'd ActorSystems in the SAME OS
  # process (and, in every test below, the same script/Interpreter) address
  # each other via local://<id>@<node-name> through the process-wide
  # LocalNodeRegistry, with no socket/handshake/wire-encoding at all. Node
  # names must be unique PER TEST (the registry is process-wide, not
  # per-Interpreter, and persists across examples in the same spec run), so
  # each test gets its own random suffix rather than reusing "node-a"/
  # "node-b" literally.

  it "delivers a message between two local: nodes in one process" do
    a, b = "node-a-#{Random.new.hex(4)}", "node-b-#{Random.new.hex(4)}"
    w(<<-SCHEME).should eq("pong")
      (start-node 'local "#{a}" "cookie")
      (register! 'svc (spawn (lambda () (send! (receive!) 'pong))))
      (start-node 'local "#{b}" "cookie")
      (define ref (remote-ref "local://svc@#{a}"))
      (send! ref (self))
      (receive!)
      SCHEME
  end

  it "a (self) reply-to ref survives a local: send across two different nodes" do
    # The regression this guards: send_remote's LocalAddress branch must
    # rewrite a bare (same-system) actor ref embedded in the message (here,
    # the reply-to built by (self)) into a fully-qualified local:// address
    # naming the SENDING node — otherwise the receiving node's reply lands
    # in the wrong ActorSystem's registry and the sender hangs forever.
    a, b = "node-a-#{Random.new.hex(4)}", "node-b-#{Random.new.hex(4)}"
    w(<<-SCHEME).should eq("pong")
      (start-node 'local "#{a}" "cookie")
      (register! 'echo (spawn (lambda () (send! (receive!) 'pong))))
      (start-node 'local "#{b}" "cookie")
      (send! (remote-ref "local://echo@#{a}") (self))
      (receive!)
      SCHEME
  end

  it "send! to an unregistered local: node name raises a clear error" do
    expect_raises(Scheme::SchemeRuntimeError, /no local node registered/) do
      run(%((send! (remote-ref "local://x@no-such-node-#{Random.new.hex(4)}") 'hi)))
    end
  end

  it "a record (and its embedded list) passed through a local: send arrives as the SAME object, unlike tcp:/unix:" do
    a, b = "node-a-#{Random.new.hex(4)}", "node-b-#{Random.new.hex(4)}"
    w(<<-SCHEME).should eq("(#t (1 2 3) #t)")
      (define-record-type <box> (make-box v) box? (v box-v))
      (start-node 'local "#{a}" "cookie")
      (define shared (list 1 2 3))
      (define echo (spawn (lambda () (send! (receive!) (receive!)))))
      (register! 'echo echo)
      (start-node 'local "#{b}" "cookie")
      (define ref (remote-ref "local://echo@#{a}"))
      (send! ref (self))
      (send! ref (make-box shared))
      (define got (receive!))
      (list (box? got) (box-v got) (eq? (box-v got) shared))
      SCHEME
  end
end
