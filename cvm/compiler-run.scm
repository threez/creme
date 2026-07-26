;; ===========================================================================
;; cvm's "compiler mode" driver -- compiles and runs a plain .scm file
;; directly under cvm, with no live Crystal `creme` process involved.
;; ===========================================================================
;;
;; Precompiled once (bundling the self-hosted compiler, exactly like
;; cvm/repl.scm does), then used automatically by main.c whenever cvm is
;; pointed at a file that ISN'T already an SCB1 binary (main.c peeks the
;; first 4 bytes -- a plain .scm file can never coincidentally start with
;; "SCB1"): main.c stashes the real target path (cvm-target-path) and
;; loads+runs THIS chunk instead, which reads/compiles/runs the real
;; target itself.
;;
;; Build once, then run any script directly:
;;   ./bin/creme --emit-cvm cvm/compiler-run.scm cvm/compiler-run.cvmc
;;   ./cvm/cvm bench/creme.scm
;;
;; `include`/`include-ci`: the self-hosted compiler itself deliberately
;; doesn't support these (reader.sld's own header comment -- real support
;; needs a path-resolution design this project hasn't needed yet). Rather
;; than take that on, this driver expands them itself, entirely from
;; already-exported toolchain primitives (read-program/compile-program/
;; chunk->bytes -- no changes to reader.sld/compiler.sld/bytecode.sld):
;; parse the target into forms, recursively splice in each top-level
;; `(include "path" ...)`'s own parsed forms (resolved relative to the
;; INCLUDING file's own directory, so a nested include resolves against
;; wherever ITS OWN file lives), then compile the flattened list.
(import (scheme base) (scheme write) (scheme lazy)
        (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler))

;; This file's own imports above are resolved NATIVELY (Crystal's own
;; import machinery, since this whole file is compiled with --emit-cvm --
;; i.e. by the NATIVE compiler) and baked into compiler-run.cvmc at BUILD
;; time. But (creme compiler compiler)'s own self-hosted library loader
;; (ensure-libraries-loaded!, ultimately reached via compile-import! any
;; time compile-program hits a target script's own (import ...) form)
;; has no way to know that -- its own "already loaded" tracking starts
;; fresh every time THIS chunk boots, since native --emit-cvm never
;; touches it at all. So a target script that ALSO imports one of these
;; same file-based libraries (exactly what every spec/creme/*.scm file
;; does, transitively, via (creme compiler spec-helper)) would otherwise
;; have its source re-read and re-run a SECOND time -- re-executing
;; (creme bytecode)'s own (define-record-type <chunk> ...) and this
;; library's own (define-record-type <fcomp> ...), each creating a
;; nominally NEW record type that corrupts any chunk/fcomp object the
;; OUTER, still-in-progress compile-program call (compiling the target
;; script itself) is already holding from the original, pre-baked
;; generation -- confirmed empirically as the exact cause of "record
;; accessor: expected a <chunk> record" before this fix.
;;
;; Pre-seeding the tracking state (mark-self-hosted-library-loaded!,
;; exported from (creme compiler compiler) specifically for this) for
;; every file-based library THIS file itself already imports natively
;; makes ensure-library-loaded! correctly skip reloading them. (scheme
;; base)/(scheme write)/(scheme lazy)/(creme bootstrap)/(creme regex)
;; need no entry -- none has a .sld file on disk, so the loader already
;; no-ops for them regardless.
(mark-self-hosted-library-loaded! '(creme peg))
(mark-self-hosted-library-loaded! '(creme bytecode))
(mark-self-hosted-library-loaded! '(creme compiler reader))
(mark-self-hosted-library-loaded! '(creme compiler compiler))

;; cvm has no independent second evaluator to back a real `eval` --
;; unlike native Crystal's own (scheme eval), which really does run
;; against a wholly separate reference implementation, the ONLY compiler
;; cvm has any notion of at all is this same self-hosted one, already
;; loaded. So `eval` here is necessarily "compile+run this one form via
;; the same compile-program/load-chunk-bytes machinery" -- a genuinely
;; different ENTRY POINT (one form at a time, vs. compile-program's
;; whole-list-at-once) that can still catch real divergences between the
;; two, but is NOT an independent-reference comparison the way running
;; under plain `./bin/creme` or `--self-hosted` is. Spec files relying on
;; (scheme eval)'s `eval` (e.g. modules/creme/compiler/spec-helper.sld's
;; native-eval/native-eval-forms) should be read with that in mind when
;; run this way.
(define (eval form) (load-chunk-bytes (chunk->bytes (compile-program (list form)))))

;; (scheme base)'s with-exception-handler/raise-continuable, absent from
;; cvm as native C builtins -- built entirely atop dynamic-wind (a REAL
;; cvm-native builtin, cvm/builtins.c) instead of adding a second control-
;; flow mechanism in C: a plain top-level mutable list is the handler
;; stack, with-exception-handler pushes/pops around thunk (via dynamic-
;; wind, so an exception unwinding past it still restores the stack
;; correctly), and raise-continuable pops the current handler off (so a
;; handler that itself calls raise-continuable sees the NEXT-outer one,
;; not itself -- R7RS's own requirement, avoiding infinite recursion),
;; calls it, then pushes it back before returning the handler's own
;; result as raise-continuable's own value -- an ordinary, non-escaping
;; return, needing no continuation/longjmp machinery at all.
(define exception-handler-stack '())

(define (with-exception-handler handler thunk)
  (dynamic-wind
    (lambda () (set! exception-handler-stack (cons handler exception-handler-stack)))
    thunk
    (lambda () (set! exception-handler-stack (cdr exception-handler-stack)))))

(define (raise-continuable obj)
  (if (null? exception-handler-stack)
      (error "raise-continuable: no exception handler installed" obj)
      (let ((handler (car exception-handler-stack))
            (rest (cdr exception-handler-stack)))
        (set! exception-handler-stack rest)
        (let ((result (handler obj)))
          (set! exception-handler-stack (cons handler rest))
          result))))

;; cvm has no native (scheme read)/(scheme base) string-input-port
;; support at all (open-input-string/read/eof-object are all absent --
;; only read-line, hardwired to stdin, exists). Rather than writing a
;; NEW incremental s-expression parser in C, this reuses the self-hosted
;; reader ALREADY loaded here (read-program, which parses a whole string
;; into a list of forms in one pass) to back all three: open-input-string
;; parses the ENTIRE string upfront into a mutable "remaining forms" box;
;; read pops one form off it per call, returning the (fresh, distinct --
;; NOT #f, which is a legitimate datum a program could actually read)
;; eof-object sentinel once exhausted. Sufficient for every real use in
;; this project's own spec/creme test suite (native-eval/read-all-native
;; in modules/creme/compiler/spec-helper.sld, always reading a complete,
;; well-formed program) -- not a general incremental reader (e.g. mixing
;; read-char with read on the same port isn't meaningful here), but nothing
;; in this codebase needs that.
(define-record-type <input-string-port>
  (make-input-string-port forms)
  input-string-port?
  (forms input-string-port-forms set-input-string-port-forms!))

(define-record-type <eof-object>
  (make-eof-object)
  eof-object?)

(define the-eof-object (make-eof-object))
(define (eof-object) the-eof-object)

(define (open-input-string str)
  (make-input-string-port (read-program str)))

(define (read port)
  (let ((forms (input-string-port-forms port)))
    (if (null? forms)
        the-eof-object
        (let ((first (car forms)))
          (set-input-string-port-forms! port (cdr forms))
          first))))

(define (dirname path)
  (let loop ((i (- (string-length path) 1)))
    (cond
      ((< i 0) "")
      ((char=? (string-ref path i) #\/) (substring path 0 i))
      (else (loop (- i 1))))))

(define (path-join dir name)
  (if (string=? dir "") name (string-append dir "/" name)))

(define (expand-includes forms dir)
  (apply append
    (map (lambda (form)
           (if (and (pair? form) (or (eq? (car form) 'include) (eq? (car form) 'include-ci)))
               (apply append
                 (map (lambda (relpath)
                        (let ((full (path-join dir relpath)))
                          (expand-includes (read-program (read-whole-file full)) (dirname full))))
                      (cdr form)))
               (list form)))
         forms)))

(define target (cvm-target-path))
(define forms (expand-includes (read-program (read-whole-file target)) (dirname target)))
(load-chunk-bytes (chunk->bytes (compile-program forms)))
