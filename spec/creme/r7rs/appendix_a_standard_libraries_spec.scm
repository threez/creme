;; ===========================================================================
;; A (creme spec)-based port of
;; spec/scheme/r7rs/appendix_a_standard_libraries_spec.cr's own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this uses.
;;
;; Unlike that Crystal file (which drives a fresh Creme::Interpreter per
;; `w`/`run` call and inspects it directly, e.g. interp.library_export_
;; names/interp.global.get?), this file already runs directly in a real
;; Scheme runtime with no Interpreter object of its own to poke at, so the
;; "every export is actually bound" checks below go through (creme
;; introspection)'s own library-exports (an already-registered library's
;; export alist) plus a bound? probe built on eval/guard -- the same
;; pattern spec/creme/main_spec.scm's own bound? helper and modules/creme/
;; compiler/compiler.sld's own global-bound? use.
;;
;; Every standard (scheme ...) library name here is still a valid public
;; library name via this project's own frontend .sld shim files (modules/
;; scheme/*.sld), even though their native backing now lives under (creme
;; builtin <name>) internally -- see e.g. modules/scheme/base.sld's own
;; header comment. That internal reshuffle is invisible from user code, so
;; every (import (scheme ...)) form below is unaffected by it.
;;
;; (scheme load)'s `load` has no equivalent anywhere in cvm (neither a
;; native C builtin in cvm/builtins.c nor a Scheme-level shim in cvm/
;; compiler-run.scm, unlike eval/interaction-environment/scheme-report-
;; environment/null-environment, which compiler-run.scm defines as
;; reduced-but-real stubs -- see that file's own comments) -- a genuine,
;; undocumented-but-real cvm gap, so "(scheme load) provides the load
;; procedure" below is gated behind `it-unless (equal? (spec-vm) "cvm")`
;; and shows as [PEND] only under ./cvm/cvm.
;;
;; `load` (src/creme/modules/scheme/load.cr) joins a relative path
;; against the RUNNING SCRIPT's own directory (the last entry of
;; active.load_dirs, pushed once by Scheme.run_file/runner.cr) via a
;; plain File.join -- which, unlike File.expand_path, does NOT special-
;; case an already-absolute second argument, so passing our /tmp probe
;; path to `load` as-is would get silently prefixed with this spec
;; file's own directory instead of being used directly. Climbing back
;; out with a generous run of literal ".."  segments (harmless once
;; they run past the real filesystem root) sidesteps that without
;; needing this spec file's own absolute directory at all.
;;
;; (scheme file)'s probe path below uses a fixed /tmp path (never created
;; by this file), matching file_ports_spec.scm's own house style, rather
;; than the Crystal original's freshly Dir.mkdir_p'd temp directory.
;;
;; "importing an unknown library name ... raises the same clear error"
;; USED to be a genuine cvm gap too (README's old "Deliberate cuts"
;; wording: "no eval, no dynamically loading a library cvm wasn't built
;; with" -- so importing a nonexistent library was a silent no-op there
;; instead of an error) -- now fixed: `ensure-library-loaded!`
;; (modules/creme/compiler/compiler.sld) raises when a name has no .sld
;; file AND doesn't match the `(creme builtin <family>)` shape every
;; genuine native pseudo-library uses, but ONLY when genuinely running
;; under cvm (`global-bound? 'read-whole-file`) -- under native/
;; --self-hosted, `read-whole-file` is always unbound regardless of
;; whether a real .sld exists, so this check would otherwise
;; misidentify perfectly ordinary libraries as "unknown" there; native's
;; own real import already raises this error correctly by a completely
;; different path. "(scheme process-context) exports command-line/..."
;; USED to be a second such gap (README used to say "process-context
;; beyond get-environment-variable/exit" had no cvm-native counterpart
;; at all) but `(scheme process-context)` is now a full port -- see
;; cvm/README.md's own builtins table -- so that case runs
;; unconditionally now.
;;
;; Run with (all cases pass under bin/creme and --self-hosted, 0 pending;
;; under ./cvm/cvm, "(scheme load) provides the load procedure" and
;; "importing an unknown library name..." show as [PEND], per the
;; genuine gap described above):
;;   ./bin/creme spec/creme/r7rs/appendix_a_standard_libraries_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/appendix_a_standard_libraries_spec.scm
;;   ./cvm/cvm spec/creme/r7rs/appendix_a_standard_libraries_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme case-lambda) (scheme char)
        (scheme complex) (scheme cxr) (scheme eval) (scheme file)
        (scheme inexact) (scheme lazy) (scheme load) (scheme process-context)
        (scheme read) (scheme repl) (scheme time) (scheme r5rs)
        (creme introspection) (creme spec))

(describe "Appendix A Standard Libraries"
  (define (bound? name) (guard (e (#t #f)) (eval name) #t))

  (it "(scheme base) imports and every (scheme base) export is bound in @global"
    (for-each
      (lambda (pair) (should-be-true? (bound? (car pair))))
      (library-exports '(scheme base))))

  (it "(scheme write) imports and exports display/write"
    (should-equal? (+ 1 1) 2)
    (for-each
      (lambda (pair) (should-be-true? (bound? (car pair))))
      (library-exports '(scheme write))))

  (it "(scheme case-lambda) exports case-lambda, and its result is callable"
    (should-equal? ((case-lambda ((x) x)) 5) 5))

  (it "procedure? recognizes a case-lambda value as a procedure"
    (should-be-true? (procedure? (case-lambda ((x) x)))))

  (it "(scheme char) exports the Unicode-table-dependent character/string procedures"
    (should-equal? (char-foldcase #\A) #\a))

  (it "(scheme complex) exports procedures typically only useful with non-real numbers"
    (should-equal? (real-part 3) 3))

  (it "(scheme cxr) exports the depth-3/4 car/cdr compositions"
    (should-equal? (caaar '(((1 2) 3) 4)) 1))

  (it "(scheme eval) exports eval"
    (should-equal? (eval '(+ 1 1)) 2))

  (it "(scheme file) provides procedures for accessing files"
    (should-be-false? (file-exists? "/tmp/creme-r7rs-appendix-a-spec-probe-never-created.txt")))

  (it "(scheme inexact) exports procedures typically only useful with inexact values"
    (should-be-true? (finite? 3)))

  (it "(scheme lazy) exports promise-related syntax/procedures"
    (should-be-true? (promise? (delay 1))))

  (it "(scheme load) provides the load procedure"
    (let ((abs-path "/tmp/creme-r7rs-appendix-a-spec-answer.scm")
          ;; See this file's own header comment on why `load` needs a
          ;; path relative to ITS OWN directory, not this absolute one.
          (relative-path (string-append "../../../../../../../../../../../../../../../../../../../../../../../../../../../../../../tmp/creme-r7rs-appendix-a-spec-answer.scm")))
      (let ((op (open-output-file abs-path)))
        (write-string "(define answer 42)" op)
        (close-port op))
      (load relative-path)
      (should-equal? (eval 'answer) 42)))

  (it "(scheme process-context) exports command-line/exit/environment-variable access"
    (should-be-true? (list? (command-line))))

  (it "(scheme read) exports read"
    (should-equal? (read (open-input-string "a")) 'a))

  (it "(scheme repl) exports interaction-environment"
    ;; `(define x 7)` here must land as a genuine GLOBAL binding (the
    ;; same one interaction-environment's own env argument sees), not an
    ;; ordinary internal define local to this `it` thunk's own lambda --
    ;; so it's run via `eval`, same as (scheme load)'s own case above.
    (eval '(define x 7))
    (should-equal? (eval 'x (interaction-environment)) 7))

  (it "(scheme time) exports current-second/current-jiffy/jiffies-per-second"
    (should-be-true? (number? (current-second))))

  (it "(scheme r5rs) exports the R5RS-report bindings, including null-environment/scheme-report-environment"
    (should-equal? (+ 1 2) 3)
    (should-equal? (eval '(* 2 3) (scheme-report-environment 5)) 6))

  (it "importing an unknown library name (not just an unimplemented standard one) raises the same clear error"
    (should-raise? (lambda () (eval '(import (totally not a real library)))))))

(spec-summary!)
