;; ===========================================================================
;; The one entry point for running every spec/creme/*_spec.scm file and
;; getting back ONE combined "N examples, M failures" total -- see
;; modules/creme/spec-runner.sld's own header comment for why each file
;; still runs as its own separate process (several files deliberately
;; end by permanently redefining a shared builtin to test deopt
;; behavior, which is exactly why each needs its own fresh global table)
;; and how the aggregation itself works.
;;
;; This file itself only ever runs NATIVELY (`./bin/creme spec/creme/
;; main_spec.scm`, optionally `--self-hosted`) -- spawning subprocesses
;; ((creme process)'s process-run, via (creme spec-runner)) is a native
;; OS capability, not something cvm's standalone C VM has any notion of.
;; It can still drive a run of every spec file AGAINST cvm, though: pass
;; --cvm and it spawns `./cvm/cvm <file>` for each one instead of `./bin/
;; creme <file>` -- cvm itself never runs this file, it's just the
;; child command this file's own subprocesses happen to invoke.
;;
;; NOT itself named to match spec/creme/*_spec.scm's own usual naming --
;; deliberately doesn't end in "_spec.scm" the way every file it RUNS
;; does, so a future directory-glob-based loop (if one's ever
;; reintroduced) can't accidentally pick this file up and have it spawn
;; itself.
;;
;; Run with:
;;   ./bin/creme spec/creme/main_spec.scm                 (native bin/creme)
;;   ./bin/creme spec/creme/main_spec.scm --self-hosted    (native VM, self-hosted compiler)
;;   ./bin/creme spec/creme/main_spec.scm --cvm            (cvm's standalone C11 VM)
;; (cvm/compiler-run.cvmc must already be built fresh for --cvm -- see
;; the Makefile's own creme-spec-cvm target.)
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (creme spec) (creme spec-runner))

(define spec-files
  '("spec/creme/bootstrap_spec.scm"
    "spec/creme/bytecode_spec.scm"
    "spec/creme/compiler_defmacro_spec.scm"
    "spec/creme/compiler_libraries_spec.scm"
    "spec/creme/compiler_numeric_tower_spec.scm"
    "spec/creme/compiler_self_host_spec.scm"
    "spec/creme/compiler_spec.scm"
    "spec/creme/macro_spec.scm"
    "spec/creme/prim_call_spec.scm"
    "spec/creme/reader_literals_spec.scm"
    "spec/creme/reader_native_spec.scm"
    "spec/creme/syntax_rules_spec.scm"
    "spec/creme/vm_spec.scm"))

;; (creme reader)'s lex-tokens/tokens->forms (reader_native_spec.scm's own
;; subject) are native-Crystal-only, with no cvm C equivalent at all -- see
;; that file's own header comment. Skipped only when the runner targets cvm.
(define cvm-excluded '("spec/creme/reader_native_spec.scm"))

(define args (cdr (command-line)))

(define runner
  (cond
    ((member "--cvm" args) '("./cvm/cvm"))
    ((member "--self-hosted" args) '("./bin/creme" "--self-hosted"))
    (else '("./bin/creme"))))

(define exclude (if (member "--cvm" args) cvm-excluded '()))

(for-each
  (lambda (f) (if (not (member f exclude)) (run-spec-file! runner f)))
  spec-files)

(spec-summary!)
