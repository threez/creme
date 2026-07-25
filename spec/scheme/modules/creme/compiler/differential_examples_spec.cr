require "../../../../spec_helper"

# Phase C of the vm/c compiler-parity effort: a broad differential sweep,
# running real example programs (not hand-picked one-liners) through BOTH
# the native Crystal BytecodeCompiler and the self-hosted (creme compiler
# compiler), comparing captured stdout. Complements compiler_spec.cr's own
# ~90 targeted snippets/library-load cases with whole, realistic programs
# this project already ships and exercises via scheme_examples_spec.cr.
#
# Excluded from the sweep (kept in scheme_examples_spec.cr's own native-only
# "runs without raising" coverage instead), each for a reason unrelated to
# compiler correctness -- a diff would spuriously fail even with identical
# compilers:
#   - 24-tui-try-scheme.scm: drives an interactive terminal UI.
#   - 27-http-json-fetch.scm, 34-actor-ping-pong.scm, 35-mux-router.scm:
#     real network I/O (sockets/HTTP) -- unavailable/flaky in CI, and 34
#     also spawns actor Fibers with non-deterministic interleaving.
#   - 37-raft-kv-store.scm: a multi-node Raft cluster; log/message
#     ordering across nodes isn't guaranteed byte-identical run to run.
#   - 03-random-password-generator.scm, 10-random-dice-roller.scm,
#     17-random-lottery-drawer.scm, 25-rfc8439-secure-message.scm:
#     unseeded (random) output (25 generates a random key/nonce), genuinely
#     different every run by design.
#   - 07-time-process-stopwatch.scm, 20-time-json-event-log.scm,
#     14-process-build-pipeline.scm, 38-memoized-fib.scm: print wall-clock
#     timestamps/elapsed durations.
#   - bench/bench.scm: shells out to external processes/language runtimes
#     (Ruby, Racket, Go, Node, ...) for a cross-language timing comparison
#     -- explicitly documented in its own header as "a single-run
#     comparison, not a best-of-N", never meant to be byte-reproducible.
#   - demo2.scm: an untracked, in-progress scratch file with a genuine
#     unterminated-list syntax error (missing a closing paren on its
#     pc-row definition) -- not part of the committed example corpus;
#     this is also why spec/scheme/modules/creme/compiler/reader_spec.cr's
#     own "every file in the repo" sweep currently fails the same way.
#
# 26-import-generated-library.scm is NOT excluded (a real finding this
# sweep DID catch and fix): compile-source-to-bytes compiles an entire
# program up front, so compile-import!'s eager compile-time import! (only
# there so a LATER macro use can see an import's exports already, see its
# own doc comment) used to abort the whole compile when a library
# genuinely doesn't exist yet at compile time -- as with this example,
# which writes its own library file with an EARLIER ordinary form
# (file-write) before importing it. Now guarded/swallowed there, relying
# on the runtime import! call already unconditionally emitted into the
# compiled program to do the real work once its turn comes, in the
# correct (post-file-write) order.
EXCLUDED = [
  "24-tui-try-scheme.scm",
  "27-http-json-fetch.scm",
  "34-actor-ping-pong.scm",
  "35-mux-router.scm",
  "37-raft-kv-store.scm",
  "03-random-password-generator.scm",
  "10-random-dice-roller.scm",
  "17-random-lottery-drawer.scm",
  "25-rfc8439-secure-message.scm",
  "07-time-process-stopwatch.scm",
  "20-time-json-event-log.scm",
  "14-process-build-pipeline.scm",
  "38-memoized-fib.scm",
  "demo2.scm",
]

private def load_toolchain(interp : Scheme::Interpreter) : Nil
  Scheme.run_source(interp, %((import (scheme lazy) (scheme eval) (scheme cxr) (creme peg) (creme regex) (creme bytecode) (creme bootstrap) (creme compiler reader) (creme compiler compiler))))
end

private def run_native(path : String) : String
  captured = IO::Memory.new
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"], stdout: captured, auto_import_base: false)
  Scheme.run_file(interp, path)
  captured.to_s
end

private def run_bootstrap(path : String) : String
  captured = IO::Memory.new
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"], stdout: captured, auto_import_base: false)
  load_toolchain(interp)
  interp.push_load_dir(File.dirname(File.expand_path(path)))
  begin
    interp.global.define("differential-example-source", Scheme::SchemeStr.new(File.read(path)))
    Scheme.run_source(interp, "(load-chunk-bytes (compile-source-to-bytes differential-example-source))", source_name: path)
  ensure
    interp.pop_load_dir
  end
  captured.to_s
end

describe "differential sweep: examples/*.scm compiled by both compilers" do
  # Scoped to examples/*.scm only -- bench/ has several other non-Scheme or
  # timing/external-process-dependent files (racket.scm is `#lang racket`,
  # creme.scm/workloads*.scm/guile.scm/prof.scm are all part of the same
  # timing-comparison machinery bench.scm itself is excluded for above) not
  # vetted for this sweep.
  files = Dir.glob("examples/*.scm")
    .reject { |path| EXCLUDED.includes?(File.basename(path)) }
    .sort

  files.each do |path|
    it "produces identical stdout for #{path} natively vs. self-hosted-compiled" do
      run_bootstrap(path).should eq(run_native(path))
    end
  end
end
