;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch05_program_structure_
;; spec.cr -- see modules/creme/spec.sld's own header comment for the
;; framework this uses. Ported per the task porting spec/scheme/r7rs/*.cr
;; into spec/creme/r7rs/*.scm: unlike the Crystal original (which builds a
;; fresh Creme::Interpreter per `run`/`w` call purely for isolation),
;; every case here runs directly against this file's own single, real
;; Scheme runtime -- no run(src)/w(src) string-eval indirection, just
;; ordinary Scheme forms compared with should-equal?/should-raise?
;; against literal expected values. Cases that only needed a fresh
;; interpreter for lexical isolation (internal definitions, an internal
;; define-syntax) use a plain `let` scope instead; cases that need a
;; genuinely fresh, otherwise-almost-empty top-level (whether a name is
;; bound at all before/after an import) use (scheme eval)'s `environment`/
;; `eval`, exactly like spec/creme/r7rs/ch06_02_numbers_spec.scm's own
;; complex?/sqrt cases -- since `import` only works as a top-level
;; declaration (see spec/creme/compiler_libraries_spec.scm's "rejects a
;; non-top-level import").
;;
;; §5.6's cases all genuinely need a real `import`, and `import` only
;; works as a top-level declaration (compiler_libraries_spec.scm's own
;; "rejects a non-top-level import" already establishes this; nesting
;; one inside an `it`'s own lambda body raises "Import is only supported
;; at the top level, not inside a function body" here too) -- so each
;; one writes its own library .sld (plus, for include, a small fragment
;; file it splices in) via (creme file)'s file-write into ./modules
;; (library_search_path's own entry, and -- for include's own relative-
;; path resolution -- the running script's own directory would work too,
;; but modules/ matches compiler_libraries_spec.scm's own "imports a
;; library file written by an earlier form in the same program"
;; precedent) as plain top-level forms, immediately followed by a plain
;; top-level `import`, with the describe/it that asserts the result
;; coming after, and delete-file cleanup at the very end. An INLINE
;; (define-library ...) form directly in this script's own body (rather
;; than a real file resolved via library_search_path) works fine under
;; plain `./bin/creme`, but not under `./bin/creme --self-hosted`/`./icecreme/
;; icecreme` -- both run the self-hosted compiler's own library loader
;; (ensure-libraries-loaded!, compiler.sld), which only ever resolves a
;; library by searching for an actual file, never by noticing an
;; already-evaluated inline define-library earlier in the same program;
;; writing a real (if temporary) file sidesteps that gap entirely and
;; passes identically under all three.
;;
;; Run with (all cases pass, 0 pending, under all three):
;;   ./bin/creme spec/creme/r7rs/ch05_program_structure_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch05_program_structure_spec.scm
;;   ./icecreme/icecreme spec/creme/r7rs/ch05_program_structure_spec.scm
;;
;; §5.2's "only"/"except"/"prefix"/"rename" and §5.6's "a library body
;; sees only what it explicitly imports" cases USED to be icecreme-only gaps
;; (`environment` was entirely unbound under icecreme/icecreme, and icecreme's global
;; table has no runtime notion of "which library owns this name" at
;; all) but are now fixed -- see the "a library body sees only what it
;; explicitly imports" case's own comment below, and icecreme/README.md's
;; "environment/eval" section, for the full design (a purely compile-
;; time fix in the self-hosted compiler, not a runtime one -- icecreme's flat
;; global table itself is unchanged). "except" needed the same
;; fused-op-gating mechanism twice: once for `eval`'s own target
;; environment, once for a library body's own visibility.
;;
;; §5.6's export-rename, include/include-ci-in-a-library-body, and
;; cond-expand-as-a-library-declaration cases USED to be four more such
;; icecreme-only gaps here, each traced to modules/creme/compiler/compiler.sld's
;; own `ensure-library-loaded!` (the self-hosted compiler's own library
;; loader, the ONLY mechanism actually loading a pure-Scheme library
;; under icecreme -- native Crystal's own real `import!` does the equivalent
;; work directly, which is why `--self-hosted` never showed these even
;; before the fix, despite running the very same compiler.sld): it only
;; ever recognized literal `import`/`begin` clauses in a library's own
;; body, so `include`/`include-ci`/`cond-expand` declarations were simply
;; ignored, and a bare (non-only/except/prefix/rename) import-set's own
;; `import-set-alias-defines` case never consulted a library's own
;; `(export (rename internal external))` mapping at all. All four are
;; fixed now (`process-library-clause!`, `ascii-foldcase-string` for
;; include-ci's fold-case contract, and the new bare-import-set case in
;; `import-set-alias-defines`), so every case in this file runs
;; unconditionally except the one documented flat-table gap above.
;; ===========================================================================

(import (scheme base) (scheme write) (scheme eval) (creme file) (creme spec))

(describe "R7RS §5.1 Programs"
  (it "a program is a sequence of import declarations followed by expressions/definitions"
    (let ()
      (define x51 1)
      (should-equal? (+ x51 1) 2)))

  (it "(begin ...) at the outermost level is equivalent to the sequence of its own contents"
    (let ()
      (begin (define x52 1) (define y52 2))
      (should-equal? (+ x52 y52) 3))))

(describe "R7RS §5.2 Import declarations"
  (it "a bare (library name) import set imports everything the library exports"
    (should-equal? (+ 1 2) 3))

  (it "(only import-set identifier ...) imports just the listed identifiers"
    (should-equal? (eval '(+ 1 2) (environment '(only (scheme base) +))) 3))

  ;; Used to FAIL under `./icecreme/icecreme` only: `+` in CALL position (unlike a
  ;; bare reference to it) compiles to a fused Add opcode, baked in at
  ;; compile time independent of any environment -- so excluding `+`
  ;; from an environment couldn't stop `(+ 1 2)` from working there.
  ;; Fixed: `eval` (icecreme/icecreme.scm) now checks, via the new
  ;; `environment-bound?` builtin, which fusable primitive names the
  ;; target environment actually lacks, and temporarily tells the
  ;; compiler's own fusion gate (compiler.sld's `mark-redefined!`/
  ;; `unmark-redefined!`) to treat those as redefined for the duration of
  ;; compiling just this form -- forcing an ordinary GetGlobal+Call,
  ;; which genuinely fails against that environment. See icecreme/README.md's
  ;; own "environment/eval" section for the full explanation.
  (it "(except import-set identifier ...) imports everything except the listed identifiers"
    (should-raise? (lambda () (eval '(+ 1 2) (environment '(except (scheme base) +))))))

  (it "(prefix import-set identifier) renames every imported identifier with the given prefix"
    (should-equal? (eval '(b:+ 1 2) (environment '(prefix (scheme base) b:))) 3))

  (it "(rename import-set (id1 id2) ...) renames id1 to id2 in the imported bindings"
    (should-equal? (eval '(plus 1 2) (environment '(rename (scheme base) (+ plus)))) 3)))

(describe "R7RS §5.3 Variable definitions"
  (it "(define variable expression) binds variable to the value of expression"
    (let ()
      (define add3-53 (lambda (x) (+ x 3)))
      (should-equal? (add3-53 3) 6)))

  (it "(define (variable . formal) body) is sugar for (define variable (lambda formal body))"
    (let ()
      (define (f53 . args) args)
      (should-equal? (f53 1 2 3) (list 1 2 3))))

  (it "(define (variable formals) body) is sugar for (define variable (lambda (formals) body))"
    (let ()
      (define (first53 x) (car x))
      (should-equal? (first53 '(1 2)) 1)))

  (it "define-values creates multiple definitions from a single multiple-value expression"
    (let ()
      (define-values (x53 y53) (values 1 2))
      (should-equal? (+ x53 y53) 3)))

  (it "internal definitions occur at the beginning of a body (lambda/let/letrec/etc.)"
    (should-equal?
      (let ((x 5))
        (define foo (lambda (y) (bar x y)))
        (define bar (lambda (a b) (+ (* a b) a)))
        (foo (+ x 3)))
      45)))

(describe "R7RS §5.4 Syntax definitions"
  (it "define-syntax at the outermost level extends the global syntactic environment"
    (let ()
      (define-syntax swap54!
        (syntax-rules ()
          ((swap54! a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
      (define x54 1)
      (define y54 2)
      (swap54! x54 y54)
      (should-equal? (list x54 y54) (list 2 1))))

  (it "an internal syntax definition is local to the body it's defined in"
    (should-equal?
      (let ()
        (define-syntax double54 (syntax-rules () ((double54 e) (* 2 e))))
        (+ (double54 3) 1))
      7)))

(describe "R7RS §5.5 Record-type definitions (define-record-type)"
  (it "defines a constructor, predicate, and field accessors/modifiers for a new record type"
    (let ()
      (define-record-type <pare>
        (kons x y)
        pare?
        (x kar set-kar!)
        (y kdr))
      (define k (kons 1 2))
      (set-kar! k 3)
      (should-equal? (list (pare? k) (pare? (cons 1 2)) 1 2 (kar k)) (list #t #f 1 2 3))))

  (it "each define-record-type use creates a new, distinct record type even with the same field names"
    (let ()
      (define-record-type point55a (make-point55a x y) point55a? (x point55a-x) (y point55a-y))
      (define-record-type point55b (make-point55b x y) point55b? (x point55b-x) (y point55b-y))
      (should-be-false? (point55a? (make-point55b 1 2))))))

;; §5.6's cases below each write a real, tiny .sld (plus, for include, a
;; fragment file it splices in) into ./modules and `import` it -- and
;; `import` only works as a TOP-LEVEL declaration (compiler_libraries_
;; spec.scm's own "rejects a non-top-level import" already establishes
;; this; nesting one inside an `it`'s own lambda body raises "Import is
;; only supported at the top level, not inside a function body" here
;; too), so the file-write/import/delete-file sequence for each case
;; below runs as plain top-level forms, sandwiching the describe/it that
;; asserts the result -- not inside the `it` body itself.

(file-write "./modules/r7rs-ch05-triple-lib.sld"
  "(define-library (r7rs-ch05-triple-lib) (export triple) (import (scheme base)) (begin (define (triple x) (* x 3))))")
(import (r7rs-ch05-triple-lib))

(file-write "./modules/r7rs-ch05-rename-lib.sld"
  "(define-library (r7rs-ch05-rename-lib) (export (rename internal-add public-add)) (import (scheme base)) (begin (define (internal-add a b) (+ a b))))")
(import (r7rs-ch05-rename-lib))

(file-write "./modules/r7rs-ch05-no-implicit-base.sld"
  "(define-library (r7rs-ch05-no-implicit-base) (export broken) (import) (begin (define (broken) (+ 1 2))))")
(import (r7rs-ch05-no-implicit-base))

(file-write "./modules/r7rs-ch05-triple-frag.scm" "(define (triple2 x) (* x 3))")
(file-write "./modules/r7rs-ch05-include-lib.sld"
  "(define-library (r7rs-ch05-include-lib) (export triple2) (import (scheme base)) (include \"r7rs-ch05-triple-frag.scm\"))")
(import (r7rs-ch05-include-lib))

(file-write "./modules/r7rs-ch05-quad-frag.scm" "(DEFINE (QUADRUPLE2 X) (* X 4))")
(file-write "./modules/r7rs-ch05-include-ci-lib.sld"
  "(define-library (r7rs-ch05-include-ci-lib) (export quadruple2) (import (scheme base)) (include-ci \"r7rs-ch05-quad-frag.scm\"))")
(import (r7rs-ch05-include-ci-lib))

(file-write "./modules/r7rs-ch05-cond-expand-lib.sld"
  "(define-library (r7rs-ch05-cond-expand-lib) (export foo) (import (scheme base)) (cond-expand (r7rs (begin (define (foo) 'yes))) (else (begin (define (foo) 'no)))))")
(import (r7rs-ch05-cond-expand-lib))

(describe "R7RS §5.6 Libraries (define-library)"
  (it "a library exports only the identifiers listed in its export declaration"
    (should-equal? (triple 2) 6))

  (it "export supports (rename internal external) to expose a binding under a different external name"
    (should-equal? (public-add 2 3) 5))

  ;; USED to fail under `./icecreme/icecreme` only -- icecreme's global table is one
  ;; flat, whole-program-wide table with no runtime notion of "which
  ;; library owns this name" at all, so a naive fix would need a
  ;; genuinely separate VM per library (rejected -- icecreme bakes GetGlobal/
  ;; DefGlobal operands into raw indices into ONE specific VM's table at
  ;; load time, so an exported closure calling a sibling helper defined
  ;; in the same library would misresolve if called from a different
  ;; VM's dispatch context). Fixed instead purely at compile time, in
  ;; the self-hosted compiler (modules/creme/compiler/compiler.sld),
  ;; keeping icecreme's runtime completely unchanged: a library body's own
  ;; free-variable references that fall outside its own top-level
  ;; defines + resolved imports compile to a GetGlobal against a
  ;; mangled, guaranteed-never-bound name instead of the real one, so
  ;; the library still loads fine (matching native's own observed
  ;; behavior) and only actually CALLING through to the excluded name
  ;; raises "unbound variable" -- see icecreme/README.md's own "environment/
  ;; eval" section for the full design.
  (it "a library body sees only what it explicitly imports, not the importer's own bindings"
    (should-raise? (lambda () (broken))))

  (it "include reads and evaluates a file's forms as if they appeared inline in a begin declaration"
    (should-equal? (triple2 2) 6))

  (it "include-ci reads a file as if it began with #!fold-case, lowercasing identifiers before lexing"
    (should-equal? (quadruple2 2) 8))

  (it "cond-expand as a library declaration splices the matched clause's own declarations in place"
    (should-equal? (foo) 'yes)))

(delete-file "./modules/r7rs-ch05-triple-lib.sld")
(delete-file "./modules/r7rs-ch05-rename-lib.sld")
(delete-file "./modules/r7rs-ch05-no-implicit-base.sld")
(delete-file "./modules/r7rs-ch05-include-lib.sld")
(delete-file "./modules/r7rs-ch05-triple-frag.scm")
(delete-file "./modules/r7rs-ch05-include-ci-lib.sld")
(delete-file "./modules/r7rs-ch05-quad-frag.scm")
(delete-file "./modules/r7rs-ch05-cond-expand-lib.sld")

(spec-summary!)
