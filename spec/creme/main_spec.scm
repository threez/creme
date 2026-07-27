;; ===========================================================================
;; The one entry point for running every spec/creme/*_spec.scm file and
;; getting back ONE combined "N examples, M failures" total -- see
;; modules/creme/spec-runner.sld's own header comment for why each file
;; still runs as its own separate process (several files deliberately
;; end by permanently redefining a shared builtin to test deopt
;; behavior, which is exactly why each needs its own fresh global table)
;; and how the aggregation itself works.
;;
;; Runs under all three backends:
;;   ./bin/creme spec/creme/main_spec.scm                 (native bin/creme; spawns bin/creme per file)
;;   ./bin/creme spec/creme/main_spec.scm --self-hosted    (native VM, self-hosted compiler; spawns bin/creme --self-hosted per file)
;;   ./bin/creme spec/creme/main_spec.scm --cvm            (spawns ./cvm/cvm per file)
;;   ./cvm/cvm spec/creme/main_spec.scm                    (cvm itself; ALSO spawns ./cvm/cvm per file)
;; The last two land on the same runner -- cvm's own process-run (cvm/
;; process.c, POSIX fork/pipe/execvp/waitpid, matching src/scheme/
;; modules/creme/process.cr's contract exactly) means it makes no
;; difference whether THIS file is itself being driven natively or
;; reentrantly under cvm: either way, each spec file still gets spawned
;; as its own genuinely separate OS process. cvm-under-cvm is detected
;; via cvm-target-path (cvm/bootstrap.c) being bound -- a marker that
;; only ever exists in a cvm compiler-mode process, checked via a guard+
;; eval probe (never calling it, just asking whether it's bound) so this
;; doesn't have to touch (command-line) at all when running that way
;; (cvm has no argv-passing mechanism into compiler mode beyond the
;; target path, so there'd be nothing to parse there anyway).
;;
;; (cvm/compiler-run.cvmc must already be built fresh before either cvm
;; path -- see the Makefile's own creme-spec-cvm target.)
;;
;; NOT itself named to match spec/creme/*_spec.scm's own usual naming --
;; deliberately doesn't end in "_spec.scm" the way every file it RUNS
;; does, so a future directory-glob-based loop (if one's ever
;; reintroduced) can't accidentally pick this file up and have it spawn
;; itself.
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context) (scheme eval) (creme spec) (creme spec-runner))

(define (bound? name) (guard (e (#t #f)) (eval name) #t))

(define spec-files
  '("spec/creme/actor_spec.scm"
    "spec/creme/bootstrap_spec.scm"
    "spec/creme/bytecode_spec.scm"
    "spec/creme/bytevectors_spec.scm"
    "spec/creme/char_spec.scm"
    "spec/creme/compiler_defmacro_spec.scm"
    "spec/creme/environments_spec.scm"
    "spec/creme/compiler_libraries_spec.scm"
    "spec/creme/compiler_numeric_tower_spec.scm"
    "spec/creme/compiler_self_host_spec.scm"
    "spec/creme/compiler_spec.scm"
    "spec/creme/csv_spec.scm"
    "spec/creme/digest_spec.scm"
    "spec/creme/file_ports_spec.scm"
    "spec/creme/hashtable_spec.scm"
    "spec/creme/inexact_spec.scm"
    "spec/creme/json_spec.scm"
    "spec/creme/macro_spec.scm"
    "spec/creme/math_spec.scm"
    "spec/creme/ports_spec.scm"
    "spec/creme/prim_call_spec.scm"
    "spec/creme/random_spec.scm"
    "spec/creme/reader_literals_spec.scm"
    "spec/creme/reader_native_spec.scm"
    "spec/creme/regex_spec.scm"
    "spec/creme/strings_arithmetic_spec.scm"
    "spec/creme/syntax_rules_spec.scm"
    "spec/creme/time_spec.scm"
    "spec/creme/treelist_spec.scm"
    "spec/creme/vm_spec.scm"))

;; (creme reader)'s lex-tokens/tokens->forms (reader_native_spec.scm's own
;; subject) are native-Crystal-only, with no cvm C equivalent at all -- see
;; that file's own header comment. Skipped only when the runner targets cvm.
(define cvm-excluded '("spec/creme/reader_native_spec.scm"))

(define runner
  (if (bound? 'cvm-target-path)
      '("./cvm/cvm")
      (let ((args (cdr (command-line))))
        (cond
          ((member "--cvm" args) '("./cvm/cvm"))
          ((member "--self-hosted" args) '("./bin/creme" "--self-hosted"))
          (else '("./bin/creme"))))))

(define exclude (if (equal? runner '("./cvm/cvm")) cvm-excluded '()))

(for-each
  (lambda (f) (if (not (member f exclude)) (run-spec-file! runner f)))
  spec-files)

(spec-summary!)
