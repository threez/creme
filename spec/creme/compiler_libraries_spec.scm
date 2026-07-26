;; ===========================================================================
;; A (creme spec)-based port of compiler_spec.cr's pure-Scheme file-based
;; library cases -- (creme dao)'s defmacro-exported define-dao, (creme
;; sxql)'s imported defmacro sxql-select!, import-set filters (prefix/
;; rename), a library file written and then imported by an earlier form in
;; the SAME program, and rejecting a non-top-level import -- see modules/
;; creme/spec.sld's own header comment for the framework this uses, and
;; compiler_spec.scm's own header comment for the general should-match-
;; native? approach (source is a quoted list of forms here, not a string
;; -- see spec-helper's own header comment on why either works).
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/compiler_libraries_spec.scm
;;   ./bin/creme --self-hosted spec/creme/compiler_libraries_spec.scm
;;   ./cvm/cvm spec/creme/compiler_libraries_spec.scm
;; (cvm's Op::HelperForm now binds a runtime value for kind 3/define-
;; syntax too, not just kind 4/defmacro -- see modules/creme/compiler/
;; compiler.sld's own define-syntax-expand-form and cvm/vm.c's Op::
;; HelperForm comment -- so "honors a prefix import-set filter against a
;; pure-Scheme library" (which aliases (creme extra)'s own `times`, a
;; top-level define-syntax) now passes there too.)
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme file) (creme spec) (creme compiler spec-helper))

;; (creme dao)'s define-dao is a defmacro EXPORTED from a pure-Scheme,
;; file-based library (modules/creme/dao.sld) -- exercises the self-hosted
;; library loader (ensure-libraries-loaded!) end to end: recursively
;; loading dao.sld's own (creme sxql)/(creme sql) dependencies, compiling
;; +running its (begin ...) body (which registers define-dao into
;; macro-table via compile-defmacro!, the same as a textually-local one),
;; then successfully expanding+compiling a real define-dao use. This is
;; the exact pattern that made cvm's own compiler mode abort with "unbound
;; variable: todo" before this support existed.
(describe "pure-Scheme file-based libraries"
  (it "loads a defmacro-exporting library (creme dao) via the self-hosted loader"
    (should-match-native?
      '((import (scheme base) (creme sql) (creme dao))
        (define conn (sql-open ":memory:"))
        (define-dao todo conn
          (id integer primary-key auto-increment)
          (title text not-null)
          (done bool not-null (default #f)))
        (todo-create! 'title "hello" 'done #f)
        (define result (todo-all))
        (sql-close conn)
        result)))

  (it "expands an imported defmacro (sxql-select!) from (creme sxql)"
    (should-match-native?
      '((import (creme sql) (creme sxql))
        (define conn (sql-open ":memory:"))
        (sql-execute conn "CREATE TABLE sale (region TEXT, amount REAL)")
        (sql-execute conn "INSERT INTO sale (region, amount) VALUES ('north', 120.0)")
        (sql-execute conn "INSERT INTO sale (region, amount) VALUES ('north', 80.0)")
        (sql-execute conn "INSERT INTO sale (region, amount) VALUES ('south', 45.0)")
        (define result
          (map (lambda (row) (cdr (assoc ':amount row)))
               (sxql-select! conn (:amount)
                 (from :sale)
                 (where (:= :region "north"))
                 (order-by (:desc :amount)))))
        (sql-close conn)
        result)))

  (it "honors a prefix import-set filter against a pure-Scheme library"
    (should-match-native? '((import (prefix (creme extra) extra:)) (extra:filter odd? '(1 2 3 4 5)))))

  (it "honors a rename import-set filter against a pure-Scheme library"
    (should-match-native? '((import (rename (creme extra) (filter my-filter))) (my-filter odd? '(1 2 3 4 5)))))

  ;; compile-source-to-bytes compiles a WHOLE program up front, before any
  ;; of it runs -- so compile-import!'s eager compile-time import! (there
  ;; only to make an import's exports visible to a LATER macro use) used
  ;; to raise and abort the entire compile when a library genuinely
  ;; doesn't exist yet at compile time, as here: an earlier ordinary form
  ;; writes the library file this later (import ...) then loads. That
  ;; eager call is now guarded/swallowed; the runtime import! call
  ;; already unconditionally emitted into the compiled program does the
  ;; real work once its turn comes, in the correct (post-file-write)
  ;; order -- exactly like examples/26-import-generated-library.scm,
  ;; which this mirrors.
  (it "imports a library file written by an earlier form in the same program"
    (should-match-native?
      '((import (creme file))
        (file-write "./modules/compiler-spec-generated.sld"
          "(define-library (compiler-spec-generated) (export greet) (import (scheme base)) (begin (define (greet name) (string-append \"hi \" name))))")
        (import (compiler-spec-generated))
        (define result (greet "Ada"))
        (delete-file "./modules/compiler-spec-generated.sld")
        result)))

  (it "compiles a self-recursive named-let loop over 200000 iterations without overflowing"
    (should-match-native? '((let loop ((i 0) (acc 0)) (if (= i 200000) acc (loop (+ i 1) (+ acc i)))))))

  (it "rejects a non-top-level import"
    (should-raise? (lambda () (compile-program '((define (f) (import (creme regex)) 1) (f)))))))

(spec-summary!)
