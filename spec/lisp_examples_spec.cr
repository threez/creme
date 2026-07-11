require "./spec_helper"

private def run_example(path : String) : Nil
  LISP.run_file(LISP::Interpreter.new, path)
end

describe "integration: examples/*.lisp" do
  it "runs 01-bigdecimal-invoice-total.lisp end to end without raising" do
    run_example("examples/01-bigdecimal-invoice-total.lisp")
  end

  it "runs 02-math-quadratic-solver.lisp end to end without raising" do
    run_example("examples/02-math-quadratic-solver.lisp")
  end

  it "runs 03-random-password-generator.lisp end to end without raising" do
    run_example("examples/03-random-password-generator.lisp")
  end

  it "runs 04-digest-integrity-checker.lisp end to end without raising" do
    run_example("examples/04-digest-integrity-checker.lisp")
  end

  it "runs 05-regex-log-analyzer.lisp end to end without raising" do
    run_example("examples/05-regex-log-analyzer.lisp")
  end

  it "runs 06-json-config-loader.lisp end to end without raising" do
    run_example("examples/06-json-config-loader.lisp")
  end

  it "runs 07-time-process-stopwatch.lisp end to end without raising" do
    run_example("examples/07-time-process-stopwatch.lisp")
  end

  it "runs 08-env-json-report.lisp end to end without raising" do
    run_example("examples/08-env-json-report.lisp")
  end

  it "runs 09-string-template-engine.lisp end to end without raising" do
    run_example("examples/09-string-template-engine.lisp")
  end

  it "runs 10-random-dice-roller.lisp end to end without raising" do
    run_example("examples/10-random-dice-roller.lisp")
  end

  it "runs 11-word-frequency-counter.lisp end to end without raising" do
    run_example("examples/11-word-frequency-counter.lisp")
  end

  it "runs 12-vector-matrix-ops.lisp end to end without raising" do
    run_example("examples/12-vector-matrix-ops.lisp")
  end

  it "runs 13-json-data-transform.lisp end to end without raising" do
    run_example("examples/13-json-data-transform.lisp")
  end

  it "runs 14-process-build-pipeline.lisp end to end without raising" do
    run_example("examples/14-process-build-pipeline.lisp")
  end

  it "runs 15-digest-base64-roundtrip.lisp end to end without raising" do
    run_example("examples/15-digest-base64-roundtrip.lisp")
  end

  it "runs 16-bigdecimal-currency-converter.lisp end to end without raising" do
    run_example("examples/16-bigdecimal-currency-converter.lisp")
  end

  it "runs 17-random-lottery-drawer.lisp end to end without raising" do
    run_example("examples/17-random-lottery-drawer.lisp")
  end

  it "runs 18-regex-email-validator.lisp end to end without raising" do
    run_example("examples/18-regex-email-validator.lisp")
  end

  it "runs 19-env-feature-flags.lisp end to end without raising" do
    run_example("examples/19-env-feature-flags.lisp")
  end

  it "runs 20-time-json-event-log.lisp end to end without raising" do
    run_example("examples/20-time-json-event-log.lisp")
  end

  it "runs 21-sql-todo-tracker.lisp end to end without raising" do
    run_example("examples/21-sql-todo-tracker.lisp")
  end

  it "runs 22-sxql-report-builder.lisp end to end without raising" do
    run_example("examples/22-sxql-report-builder.lisp")
  end

  it "runs 23-clos-library-catalog.lisp end to end without raising" do
    run_example("examples/23-clos-library-catalog.lisp")
  end

  it "runs 24-tui-try-lisp.lisp end to end without raising" do
    run_example("examples/24-tui-try-lisp.lisp")
  end
end
