require "../../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme process)) #{src}")
end

describe "process module" do
  it "runs a command and captures stdout/stderr/status/success" do
    result = Creme.list_to_a(run(%((process-run "echo" (list "hi")))))
    result[0].as(Creme::SchemeStr).value.should eq("hi\n")
    result[1].as(Creme::SchemeStr).value.should eq("")
    result[2].as(Creme::SchemeInt).value.should eq(0)
    result[3].as(Creme::SchemeBool).value?.should be_true
  end

  it "reports a non-zero exit status as unsuccessful" do
    result = Creme.list_to_a(run(%((process-run "sh" (list "-c" "exit 1")))))
    result[2].as(Creme::SchemeInt).value.should eq(1)
    result[3].as(Creme::SchemeBool).value?.should be_false
  end

  it "raises when the command doesn't exist" do
    expect_raises(Creme::SchemeRuntimeError, /process-run:/) do
      run(%((process-run "this-command-does-not-exist-anywhere" (list))))
    end
  end

  describe "process-spawn/process-alive?/process-kill?/process-wait!" do
    it "spawns without blocking and reports the pid alive until killed" do
      result = run(<<-SCM)
        (define pid (process-spawn "sleep" (list "5")))
        (define alive-before (process-alive? pid))
        (define killed (process-kill! pid))
        (sleep! 0.3)
        (define alive-after (process-alive? pid))
        (list alive-before killed alive-after)
        SCM
      triple = Creme.list_to_a(result)
      triple[0].as(Creme::SchemeBool).value?.should be_true
      triple[1].as(Creme::SchemeBool).value?.should be_true
      triple[2].as(Creme::SchemeBool).value?.should be_false
    end

    it "process-kill! is idempotent -- a second kill on an already-dead pid returns #f" do
      result = run(<<-SCM)
        (define pid (process-spawn "sleep" (list "5")))
        (process-kill! pid)
        (sleep! 0.3)
        (process-kill! pid)
        SCM
      result.as(Creme::SchemeBool).value?.should be_false
    end

    it "accepts a raw signal number in addition to 'term/'kill/'int symbols" do
      result = run(<<-SCM)
        (define pid (process-spawn "sleep" (list "5")))
        (define killed (process-kill! pid 'signal 9))
        (sleep! 0.3)
        (define alive-after (process-alive? pid))
        (list killed alive-after)
        SCM
      pair = Creme.list_to_a(result)
      pair[0].as(Creme::SchemeBool).value?.should be_true
      pair[1].as(Creme::SchemeBool).value?.should be_false
    end

    it "process-alive? is #f for a pid that was never a real process" do
      run(%((process-alive? 999999999))).as(Creme::SchemeBool).value?.should be_false
    end

    it "'stdin 'keep-open gives the child a stdin that never hits EOF" do
      result = run(<<-SCM)
        (define pid (process-spawn "cat" (list) 'stdin 'keep-open 'stdout "/tmp/creme-process-spec-cat.log"))
        (sleep! 0.2)
        (define alive (process-alive? pid))
        (process-kill! pid)
        alive
        SCM
      result.as(Creme::SchemeBool).value?.should be_true
    end

    it "process-write-line! wakes a child blocking on its own stdin read" do
      result = run(<<-SCM)
        (define pid (process-spawn "sh" (list "-c" "read line; echo done")
                                    'stdin 'keep-open 'stdout "/tmp/creme-process-spec-write-line.log"))
        (process-write-line! pid "hello")
        (process-wait! pid)
        SCM
      result.as(Creme::SchemeInt).value.should eq(0)
      File.read("/tmp/creme-process-spec-write-line.log").should eq("done\n")
    end

    it "process-write-line! raises for a pid never spawned via process-spawn" do
      expect_raises(Creme::SchemeRuntimeError, /process-write-line!:/) do
        run(%((process-write-line! 999999999 "hello")))
      end
    end

    it "process-write-line! raises when the child's stdin wasn't opened with 'keep-open" do
      result = run(<<-SCM)
        (define pid (process-spawn "sleep" (list "5")))
        (define ok
          (guard (e (#t (process-kill! pid) #f))
            (process-write-line! pid "hello")
            #t))
        ok
        SCM
      result.as(Creme::SchemeBool).value?.should be_false
    end

    it "process-wait! blocks for a spawned pid and reports a signal-terminated exit as a negative code" do
      result = run(<<-SCM)
        (define pid (process-spawn "sleep" (list "5")))
        (process-kill! pid)
        (process-wait! pid)
        SCM
      result.as(Creme::SchemeInt).value.should eq(-15)
    end

    it "process-wait! raises for a pid never spawned via process-spawn" do
      expect_raises(Creme::SchemeRuntimeError, /process-wait!:/) do
        run(%((process-wait! 999999999)))
      end
    end
  end

  describe "sleep!" do
    it "blocks for roughly the requested number of seconds" do
      result = run(<<-SCM)
        (import (creme time))
        (define start (current-time))
        (sleep! 0.2)
        (- (current-time) start)
        SCM
      result.as(Creme::SchemeFloat).value.should be >= 0.15
    end
  end
end
