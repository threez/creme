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
    "spec/creme/bigdecimal_spec.scm"
    "spec/creme/bootstrap_spec.scm"
    "spec/creme/bytecode_spec.scm"
    "spec/creme/bytevectors_spec.scm"
    "spec/creme/char_spec.scm"
    "spec/creme/compiler_defmacro_spec.scm"
    "spec/creme/environments_spec.scm"
    "spec/creme/compiler_global_counted_loop_spec.scm"
    "spec/creme/compiler_libraries_spec.scm"
    "spec/creme/compiler_numeric_tower_spec.scm"
    "spec/creme/compiler_self_host_spec.scm"
    "spec/creme/compiler_spec.scm"
    "spec/creme/cipher_spec.scm"
    "spec/creme/csv_spec.scm"
    "spec/creme/digest_spec.scm"
    "spec/creme/examples_cvm_spec.scm"
    "spec/creme/file_extra_spec.scm"
    "spec/creme/file_ports_spec.scm"
    "spec/creme/general_loop_fusion_spec.scm"
    "spec/creme/hashtable_spec.scm"
    "spec/creme/http_spec.scm"
    "spec/creme/inexact_spec.scm"
    "spec/creme/json_spec.scm"
    "spec/creme/macro_spec.scm"
    "spec/creme/math_spec.scm"
    "spec/creme/pkey_spec.scm"
    "spec/creme/ports_spec.scm"
    "spec/creme/prim_call_spec.scm"
    "spec/creme/prim_quicken_spec.scm"
    "spec/creme/raft_dispatch_spec.scm"
    "spec/creme/raft_scheme_spec.scm"
    "spec/creme/random_spec.scm"
    "spec/creme/record_accessor_quicken_spec.scm"
    "spec/creme/repl_spec.scm"
    "spec/creme/reader_literals_spec.scm"
    "spec/creme/reader_native_spec.scm"
    "spec/creme/regex_spec.scm"
    "spec/creme/secure_random_spec.scm"
    "spec/creme/strings_arithmetic_spec.scm"
    "spec/creme/syntax_rules_spec.scm"
    "spec/creme/time_spec.scm"
    "spec/creme/treelist_spec.scm"
    "spec/creme/vm_spec.scm"
    "spec/creme/x509_spec.scm"
    "spec/creme/yaml_spec.scm"
    "spec/creme/r7rs/ch02_lexical_conventions_spec.scm"
    "spec/creme/r7rs/ch03_basic_concepts_spec.scm"
    "spec/creme/r7rs/ch04_expressions_spec.scm"
    "spec/creme/r7rs/ch05_program_structure_spec.scm"
    "spec/creme/r7rs/ch06_01_equivalence_spec.scm"
    "spec/creme/r7rs/ch06_02_numbers_spec.scm"
    "spec/creme/r7rs/ch06_03_booleans_spec.scm"
    "spec/creme/r7rs/ch06_04_pairs_lists_spec.scm"
    "spec/creme/r7rs/ch06_05_symbols_spec.scm"
    "spec/creme/r7rs/ch06_06_characters_spec.scm"
    "spec/creme/r7rs/ch06_07_strings_spec.scm"
    "spec/creme/r7rs/ch06_08_vectors_spec.scm"
    "spec/creme/r7rs/ch06_09_bytevectors_spec.scm"
    "spec/creme/r7rs/ch06_10_control_features_spec.scm"
    "spec/creme/r7rs/ch06_11_exceptions_spec.scm"
    "spec/creme/r7rs/ch06_12_environments_eval_spec.scm"
    "spec/creme/r7rs/ch06_13_input_output_spec.scm"
    "spec/creme/r7rs/ch06_14_system_interface_spec.scm"
    "spec/creme/r7rs/ch07_formal_syntax_spec.scm"
    "spec/creme/r7rs/appendix_a_standard_libraries_spec.scm"
    "spec/creme/r7rs/appendix_b_feature_identifiers_spec.scm"))

;; (creme reader)'s lex-tokens/tokens->forms (reader_native_spec.scm's own
;; subject) are native-Crystal-only, with no cvm C equivalent at all -- see
;; that file's own header comment. Skipped only when the runner targets cvm.
;;
;; The spec/creme/r7rs/*.scm ports (and bootstrap_spec.scm) each carry
;; their own PER-CASE `pending` via `it-unless`/`(spec-vm)`/`(spec-
;; compiler)` (see modules/creme/spec.sld and (creme introspection)'s
;; `runtime` builtin) for every genuine, individually-verified cvm/self-
;; hosted gap those ports surfaced -- so none of those files need a
;; whole-file exclusion entry here anymore; a file that used to be listed
;; below now just reports some cases as `[PEND]` instead of `[FAIL]`
;; under the backend(s) where the gap applies, while still running (and
;; asserting) everything else for real. See each such file's own header
;; comment for exactly which cases are conditionally pending and why.
(define cvm-excluded '("spec/creme/reader_native_spec.scm"))

(define self-hosted-excluded '())

;; The inverse case: http_spec.scm's own live-server cases spawn a real
;; (creme mux) HTTP server on a (creme actor) thread and hit it with
;; (creme http)'s client, within the SAME script -- this only works
;; under cvm, whose mux-listen! blocks a spawned actor's own OS thread
;; forever (see that file's own header comment), letting the main
;; thread's requests run concurrently. Native's mux-listen! has
;; different (Fiber-based) concurrency semantics that don't line up the
;; same way in this exact shape -- and native's own (creme http) already
;; has its own full, separate Crystal spec coverage
;; (spec/scheme/modules/creme/http_spec.cr, a real HTTP::Server on its
;; own Fiber) verifying the identical request/response contract, so
;; nothing is left untested by skipping this file under native/self-
;; hosted. Skipped only when the runner does NOT target cvm.
(define native-excluded '("spec/creme/http_spec.scm"))

(define runner
  (if (bound? 'cvm-target-path)
      '("./cvm/cvm")
      (let ((args (cdr (command-line))))
        (cond
          ((member "--cvm" args) '("./cvm/cvm"))
          ((member "--self-hosted" args) '("./bin/creme" "--self-hosted"))
          (else '("./bin/creme"))))))

(define exclude
  (cond
    ((equal? runner '("./cvm/cvm")) cvm-excluded)
    ((equal? runner '("./bin/creme" "--self-hosted")) (append native-excluded self-hosted-excluded))
    (else native-excluded)))

(for-each
  (lambda (f) (if (not (member f exclude)) (run-spec-file! runner f)))
  spec-files)

(spec-summary!)
