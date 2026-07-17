require "./spec_helper"

private def run_example(path : String) : Nil
  Scheme.run_file(Scheme::Interpreter.new(library_search_path: ["./modules"], auto_import_base: false), path)
end

describe "integration: examples/*.scm" do
  it "runs 01-bigdecimal-invoice-total.scm end to end without raising" do
    run_example("examples/01-bigdecimal-invoice-total.scm")
  end

  it "runs 02-math-quadratic-solver.scm end to end without raising" do
    run_example("examples/02-math-quadratic-solver.scm")
  end

  it "runs 03-random-password-generator.scm end to end without raising" do
    run_example("examples/03-random-password-generator.scm")
  end

  it "runs 04-digest-integrity-checker.scm end to end without raising" do
    run_example("examples/04-digest-integrity-checker.scm")
  end

  it "runs 05-regex-log-analyzer.scm end to end without raising" do
    run_example("examples/05-regex-log-analyzer.scm")
  end

  it "runs 06-json-config-loader.scm end to end without raising" do
    run_example("examples/06-json-config-loader.scm")
  end

  it "runs 07-time-process-stopwatch.scm end to end without raising" do
    run_example("examples/07-time-process-stopwatch.scm")
  end

  it "runs 08-env-json-report.scm end to end without raising" do
    run_example("examples/08-env-json-report.scm")
  end

  it "runs 09-string-template-engine.scm end to end without raising" do
    run_example("examples/09-string-template-engine.scm")
  end

  it "runs 10-random-dice-roller.scm end to end without raising" do
    run_example("examples/10-random-dice-roller.scm")
  end

  it "runs 11-word-frequency-counter.scm end to end without raising" do
    run_example("examples/11-word-frequency-counter.scm")
  end

  it "runs 12-vector-matrix-ops.scm end to end without raising" do
    run_example("examples/12-vector-matrix-ops.scm")
  end

  it "runs 13-json-data-transform.scm end to end without raising" do
    run_example("examples/13-json-data-transform.scm")
  end

  it "runs 14-process-build-pipeline.scm end to end without raising" do
    run_example("examples/14-process-build-pipeline.scm")
  end

  it "runs 15-digest-base64-roundtrip.scm end to end without raising" do
    run_example("examples/15-digest-base64-roundtrip.scm")
  end

  it "runs 16-bigdecimal-currency-converter.scm end to end without raising" do
    run_example("examples/16-bigdecimal-currency-converter.scm")
  end

  it "runs 17-random-lottery-drawer.scm end to end without raising" do
    run_example("examples/17-random-lottery-drawer.scm")
  end

  it "runs 18-regex-email-validator.scm end to end without raising" do
    run_example("examples/18-regex-email-validator.scm")
  end

  it "runs 19-env-feature-flags.scm end to end without raising" do
    run_example("examples/19-env-feature-flags.scm")
  end

  it "runs 20-time-json-event-log.scm end to end without raising" do
    run_example("examples/20-time-json-event-log.scm")
  end

  it "runs 21-sql-todo-tracker.scm end to end without raising" do
    run_example("examples/21-sql-todo-tracker.scm")
  end

  it "runs 22-sxql-report-builder.scm end to end without raising" do
    run_example("examples/22-sxql-report-builder.scm")
  end

  it "runs 24-tui-try-scheme.scm end to end without raising" do
    run_example("examples/24-tui-try-scheme.scm")
  end

  it "runs 25-rfc8439-secure-message.scm end to end without raising" do
    run_example("examples/25-rfc8439-secure-message.scm")
  end

  it "runs 26-import-generated-library.scm end to end without raising" do
    run_example("examples/26-import-generated-library.scm")
  end

  it "runs 27-http-json-fetch.scm end to end without raising" do
    run_example("examples/27-http-json-fetch.scm")
  end

  it "runs 28-r7rs-forms-task-runner.scm end to end without raising" do
    run_example("examples/28-r7rs-forms-task-runner.scm")
  end

  it "runs 29-rational-hashtable-gradebook.scm end to end without raising" do
    run_example("examples/29-rational-hashtable-gradebook.scm")
  end

  it "runs 30-bytevector-checksum.scm end to end without raising" do
    run_example("examples/30-bytevector-checksum.scm")
  end

  it "runs 31-exception-handling-pipeline.scm end to end without raising" do
    run_example("examples/31-exception-handling-pipeline.scm")
  end

  it "runs 32-dynamic-wind-resource-tracking.scm end to end without raising" do
    run_example("examples/32-dynamic-wind-resource-tracking.scm")
  end

  it "runs 33-complex-number-mandelbrot.scm end to end without raising" do
    run_example("examples/33-complex-number-mandelbrot.scm")
  end

  it "runs 34-actor-ping-pong.scm end to end without raising" do
    run_example("examples/34-actor-ping-pong.scm")
  end

  it "runs 35-mux-router.scm end to end without raising" do
    run_example("examples/35-mux-router.scm")
  end

  it "runs 36-html-builder.scm end to end without raising" do
    run_example("examples/36-html-builder.scm")
  end

  it "runs 37-raft-kv-store.scm end to end without raising" do
    run_example("examples/37-raft-kv-store.scm")
  end

  it "runs 38-memoized-fib.scm end to end without raising" do
    run_example("examples/38-memoized-fib.scm")
  end

  it "runs bench.scm end to end without raising" do
    run_example("bench/bench.scm")
  end
end
