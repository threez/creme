require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme logger) (creme string)) #{src}").write_string
end

describe "logger module" do
  it "writes a message at or above the threshold" do
    w(<<-SCHEME).should eq("#t")
      (define out (open-output-string))
      (define log (make-logger out))
      (logger-info! log "hello")
      (string-contains? (get-output-string out) "hello")
      SCHEME
  end

  it "includes the level name, uppercased, in the default format" do
    w(<<-SCHEME).should eq("#t")
      (define out (open-output-string))
      (define log (make-logger out))
      (logger-warn! log "careful")
      (string-contains? (get-output-string out) "[WARN]")
      SCHEME
  end

  it "suppresses a message below the threshold" do
    w(<<-SCHEME).should eq("\"\"")
      (define out (open-output-string))
      (define log (make-logger out 'warn))
      (logger-debug! log "should not appear")
      (get-output-string out)
      SCHEME
  end

  it "logger-level-set! changes the threshold in place" do
    w(<<-SCHEME).should eq("#t")
      (define out (open-output-string))
      (define log (make-logger out 'error))
      (logger-warn! log "first, suppressed")
      (logger-level-set! log 'warn)
      (logger-warn! log "second, allowed")
      (string-contains? (get-output-string out) "second, allowed")
      SCHEME
  end

  it "logger-add! logs at an explicit level symbol" do
    w(<<-SCHEME).should eq("#t")
      (define out (open-output-string))
      (define log (make-logger out))
      (logger-add! log 'fatal "boom")
      (string-contains? (get-output-string out) "[FATAL] ")
      SCHEME
  end

  it "supports a custom formatter" do
    w(<<-SCHEME).should eq(%("CUSTOM info: hi"))
      (define out (open-output-string))
      (define log (make-logger out))
      (logger-formatter-set! log (lambda (level ts msg) (string-append "CUSTOM " (symbol->string level) ": " msg)))
      (logger-info! log "hi")
      (get-output-string out)
      SCHEME
  end

  it "recognizes logger? only for logger values" do
    w(%((list (logger? (make-logger (open-output-string))) (logger? 5)))).should eq("(#t #f)")
  end
end
