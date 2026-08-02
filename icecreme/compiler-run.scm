;; ===========================================================================
;; icecreme's "compiler mode" driver -- compiles and runs a plain .scm file
;; directly under icecreme, with no live Crystal `creme` process involved.
;; ===========================================================================
;;
;; Precompiled once (bundling the self-hosted compiler, exactly like
;; icecreme/repl.scm does), then used automatically by main.c whenever icecreme is
;; pointed at a file that ISN'T already an ICE1 binary (main.c peeks the
;; first 4 bytes -- a plain .scm file can never coincidentally start with
;; "ICE1"): main.c stashes the real target path (icecreme-target-path) and
;; loads+runs THIS chunk instead, which reads/compiles/runs the real
;; target itself.
;;
;; Build once, then run any script directly:
;;   ./bin/creme --emit-icecreme icecreme/compiler-run.scm icecreme/compiler-run.ice
;;   ./icecreme/icecreme competition/scheme/bench/creme.scm
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
        (creme compiler reader) (creme compiler compiler) (creme hash-table))

;; This file's own imports above are resolved NATIVELY (Crystal's own
;; import machinery, since this whole file is compiled with --emit-icecreme --
;; i.e. by the NATIVE compiler) and baked into compiler-run.ice at BUILD
;; time. But (creme compiler compiler)'s own self-hosted library loader
;; (ensure-libraries-loaded!, ultimately reached via compile-import! any
;; time compile-program hits a target script's own (import ...) form)
;; has no way to know that -- its own "already loaded" tracking starts
;; fresh every time THIS chunk boots, since native --emit-icecreme never
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

;; icecreme has no independent second evaluator to back a real `eval` --
;; unlike native Crystal's own (scheme eval), which really does run
;; against a wholly separate reference implementation, the ONLY compiler
;; icecreme has any notion of at all is this same self-hosted one, already
;; loaded. So `eval` here is necessarily "compile+run this one form via
;; the same compile-program/load-chunk-bytes machinery" -- a genuinely
;; different ENTRY POINT (one form at a time, vs. compile-program's
;; whole-list-at-once) that can still catch real divergences between the
;; two, but is NOT an independent-reference comparison the way running
;; under plain `./bin/creme` or `--self-hosted` is. Spec files relying on
;; (scheme eval)'s `eval` (e.g. modules/creme/compiler/spec-helper.sld's
;; native-eval/native-eval-forms) should be read with that in mind when
;; run this way.
;;
;; `eval`'s optional second argument (an environment specifier) USED to
;; be accepted and ignored entirely -- icecreme/bootstrap.c's `make-
;; environment`/`environment-copy-global!`/`load-chunk-bytes-into` (a
;; genuinely separate child VM per environment, see cvm_new_empty_vm's
;; own doc comment, vm.c) now give this real per-environment isolation:
;; when `env` is supplied, the compiled form's bytecode loads and runs
;; against THAT environment's own global table (load-chunk-bytes-into)
;; instead of this program's own; compiling itself is unaffected either
;; way (compile-program produces plain bytecode bytes, independent of
;; any VM -- only the LOAD step, resolving GetGlobal/DefGlobal operands,
;; needs to know which table to target).
;; A fused opcode (e.g. Add for `(+ 1 2)` in call position) never
;; consults any environment at all -- baked in identically at compile
;; time regardless of which environment the compiled form eventually
;; runs against -- so without help, `environment`'s own only/except
;; filtering could never stop a CALL to an excluded fusable name, only a
;; bare reference to it (e.g. `(eval '+ env)`). Fixed by temporarily
;; telling the compiler's own fusion gate (mark-redefined!/
;; unmark-redefined!, compiler.sld) to treat each fusable name NOT
;; actually bound in the target environment as if it had been redefined
;; -- for the duration of compiling THIS form only -- so it falls back
;; to an ordinary GetGlobal+Call, which genuinely fails against that
;; environment the same way a bare reference already does.
(define (eval-excluded-fusable-names env)
  (let loop ((names fusable-prim-names))
    (cond
      ((null? names) '())
      ((environment-bound? env (symbol->string (car names))) (loop (cdr names)))
      (else (cons (car names) (loop (cdr names)))))))

(define (eval form . env)
  (if (null? env)
      (load-chunk-bytes (chunk->bytes (compile-program (list form))))
      (let* ((target (car env))
             (excluded (eval-excluded-fusable-names target)))
        (for-each mark-redefined! excluded)
        (let ((bytes
                (dynamic-wind
                  (lambda () #f)
                  (lambda () (chunk->bytes (compile-program (list form))))
                  (lambda () (for-each unmark-redefined! excluded)))))
          (load-chunk-bytes-into target bytes)))))

;; (environment import-set ...) -- a fresh, otherwise-empty environment
;; (make-environment) populated by importing each import-set, mirroring
;; native's own `environment` (src/creme/modules/scheme/eval.cr)
;; exactly: only/except/prefix/rename all genuinely restrict/rename what
;; ends up bound, not just alias a FEW extra names the way import!'s own
;; runtime bridge (bi_import_bang, icecreme/bootstrap.c) does for an ordinary
;; top-level `(import ...)` -- see import-set-resolved-bindings
;; (compiler.sld) for the actual only/except/prefix/rename resolution,
;; reused here as the single source of truth for "which external name
;; maps to which already-bound internal name" a given import-set means.
;; `ensure-libraries-loaded!` first guarantees each spec's own library is
;; actually loaded (as globals in THIS, the calling, environment) before
;; copying any of its bindings out of it -- needed for a library this
;; program imports for the FIRST time only via this environment call,
;; not via its own top-level (import ...).
(define (environment . import-sets)
  (let ((env (make-environment)))
    (ensure-libraries-loaded! import-sets)
    (for-each
      (lambda (spec)
        (for-each
          (lambda (binding)
            (environment-copy-global! env (symbol->string (car binding)) (symbol->string (cdr binding))))
          (import-set-resolved-bindings spec)))
      import-sets)
    env))

;; (null-environment version) -- R7RS: only syntax, no procedures. icecreme
;; has no global bindings for special forms at all to begin with (`if`/
;; `lambda`/`define`/... are handled by the compiler directly, never as
;; vm->globals entries) -- so a genuinely EMPTY environment (make-
;; environment, no import-sets applied) already IS exactly "no
;; procedures, only syntax", with no extra bookkeeping needed.
(define (null-environment . version) (make-environment))

;; (scheme-report-environment version) -- mirrors native's own
;; deliberate non-isolation here (r5rs.cr's own comment: "wraps
;; @base_env ... not any Scheme-defined additions" -- i.e. shares a
;; REAL, already-populated environment rather than building an isolated
;; one). current-environment (icecreme/bootstrap.c) wraps THIS running
;; program's own VM directly (not a copy) -- eval-ing against it behaves
;; exactly like eval's own 1-arg form. (scheme repl)'s
;; interaction-environment is the exact same idea (native's own
;; interpreter.cr: literally @global) -- both just call this.
(define (interaction-environment) (current-environment))
(define (scheme-report-environment . version) (current-environment))

;; (scheme base)'s with-exception-handler/raise-continuable/raise USED
;; to have no native C builtin at all here -- with-exception-handler/
;; raise-continuable were defined as plain Scheme right here (a mutable
;; handler-stack list atop dynamic-wind), meaning a precompiled
;; --emit-icecreme program could never use them (only scripts running through
;; THIS compiler-mode driver could). All three are now genuine icecreme-native
;; builtins (icecreme/builtins.c's bi_with_exception_handler/
;; bi_raise_continuable/bi_raise, backed by vm->exc_handlers -- see
;; icecreme/vm.h's own UNWIND_EXC_HANDLER doc comment) -- defining them again
;; here would just SHADOW those via this file's own top-level `define`
;; (icecreme's flat global table lets a later define overwrite an earlier
;; binding by name, same mechanism the REPL relies on for redefinition),
;; silently reverting to the old, narrower behavior for every script run
;; through compiler mode. Deliberately not redefined here anymore.

;; (scheme read)'s `read` has no native C implementation (icecreme/builtins.c's
;; ports are char-level -- read-char/peek-char/read-line -- not a full
;; incremental s-expression parser; open-input-string/eof-object/
;; eof-object?/read-char/etc. THEMSELVES are all real native builtins
;; now, unlike when this comment was first written). Rather than writing
;; a NEW incremental s-expression parser in C, `read` reuses the
;; self-hosted reader ALREADY loaded here (read-program, which parses a
;; whole string into a list of forms in one pass): on a port's FIRST
;; `read` call, drain it completely via native read-char into a string,
;; parse that once via read-program, and cache the resulting forms list
;; (keyed by the port's own IDENTITY, via a native hash table -- value_to_
;; fiobj's T_PORT case in hashtable.c hashes by pointer, i.e. eq?, exactly
;; what's needed here); each call pops one form off the cached list,
;; returning native (scheme base)'s own eof-object once exhausted.
;; Sufficient for every real use in this project's own spec/creme test
;; suite (native-eval/read-all-native in modules/creme/compiler/spec-
;; helper.sld, always reading a complete, well-formed program from a
;; port nothing else reads from) -- not a general incremental reader
;; (e.g. mixing read-char with read on the SAME port isn't meaningful:
;; the first read-char call drains it before read ever sees anything),
;; but nothing in this codebase needs that.
(define read-forms-cache (make-hash-table))

(define (read port)
  (if (not (hash-table-contains? read-forms-cache port))
      (let loop ((chars '()))
        (let ((c (read-char port)))
          (if (eof-object? c)
              (hash-table-set! read-forms-cache port (read-program (list->string (reverse chars))))
              (loop (cons c chars))))))
  (let ((forms (hash-table-ref read-forms-cache port)))
    (if (null? forms)
        (eof-object)
        (begin
          (hash-table-set! read-forms-cache port (cdr forms))
          (car forms)))))

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

;; (scheme load)'s `load` -- absent as an icecreme builtin entirely until now
;; (unlike eval/open-input-string/read just above, which this file
;; already defines). Reads, compiles, and runs `filename`'s own forms
;; via the SAME primitives the target script's own compile-and-run line
;; below uses (read-program/expand-includes/compile-program/chunk->bytes/
;; load-chunk-bytes) -- a relative filename resolves against
;; current-load-dir, a simple save/restore variable (not a general
;; stack -- nested load-within-load is rare enough not to need one)
;; mirroring native's own load.cr, which resolves against "the running
;; script's own directory" the same way expand-includes already does for
;; `include`. The optional 2nd (environment) argument is accepted and
;; ignored, same convention `eval` above already established -- icecreme has
;; exactly one flat global table, so there is no isolated environment to
;; actually load `filename`'s definitions against regardless of what's
;; passed.
(define current-load-dir "")

(define (load filename . env)
  (let* ((full (path-join current-load-dir filename))
         (saved-dir current-load-dir))
    (set! current-load-dir (dirname full))
    (let* ((forms (expand-includes (read-program (read-whole-file full)) current-load-dir))
           (result (load-chunk-bytes (chunk->bytes (compile-program forms full) (required-native-families-list)))))
      (set! current-load-dir saved-dir)
      result)))

(define target (icecreme-target-path))
(set! current-load-dir (dirname target))
(define forms (expand-includes (read-program (read-whole-file target)) current-load-dir))
(load-chunk-bytes (chunk->bytes (compile-program forms target) (required-native-families-list)))
