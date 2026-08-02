;; ===========================================================================
;; (creme compiler compiler): a self-hosted, one-pass Scheme->bytecode
;; compiler, targeting (creme bytecode)'s Chunk assembler/SCB1 serializer
;; so its output can be run via (creme bootstrap)'s `load-chunk-bytes` on
;; the real Crystal VM -- the verification loop this whole bootstrap
;; effort is built around (see
;; spec/scheme/modules/creme/compiler/compiler_spec.cr: compile a
;; program with this library, run it through load-chunk-bytes, and diff
;; the result against just running the same source natively).
;;
;; This library owns the actual Scheme-to-bytecode TRANSLATION strategy --
;; the function-compiler (lexical scopes, register allocation, upvalue
;; resolution) and one compile-*! per special form -- while (creme
;; bytecode) owns everything about actually BUILDING/EMITTING/
;; serializing a Chunk (op-name lookup, jump patching, the const/proto/
;; upvalue pools, SCB1 bytes). Every chunk-*!/op-ordinal call below comes
;; from that library; this file never touches instruction/const-pool
;; internals directly. (creme compiler reader) supplies read-program,
;; used by compile-source-to-bytes.
;;
;; Scope: unlike the real BytecodeCompiler (src/creme/compile/
;; bytecode_compiler.cr), this covers define (top-level only, both plain
;; and (define (f . args) ...) sugar, plus internal defines hoisted into
;; a letrec* -- see hoist-internal-defines), lambda (fixed + dotted-rest
;; params), let/let*/letrec/letrec* (plain and named), if, when, unless
;; (both desugared straight to if -- see their compile-form! entries),
;; and, or, cond (plain/bodyless/=> clauses, else), case, do, begin,
;; set!, quote (plus unquoted vector/bytevector literals, which are
;; just as self-evaluating as numbers/strings/booleans -- see
;; compile-expr!'s literal check),
;; quasiquote (expanded to cons/append/list->vector calls entirely at
;; compile time -- see qq-expand; genuine nested-depth tracking, see its
;; own doc comment), define-record-type (a genuine SchemeRecordType/
;; SchemeRecord at the top level, via the same Op::HelperForm Crystal's
;; own compiler emits -- see compile-define-record-type!; an INTERNAL
;; define-record-type is hoisted like any other internal define, but is
;; still desugared into ordinary defines over a tagged vector, see
;; record-type->define-forms's own doc comment for why), let-values/
;; let*-values/define-values, guard, parameterize, delay/delay-force
;; (both back the same MakePromise op; force itself needs no compiler
;; support, see compile-delay!), case-lambda, define-syntax/syntax-rules
;; (non-hygienic, plain substitution -- see the "syntax-rules macros"
;; section below; matches this Scheme's own reference implementation's
;; own known unhygienic caveat, so no capture-avoidance was needed to
;; reach parity with it), let-syntax/letrec-syntax (a save/restore
;; snapshot of the whole macro-table around the body -- see
;; compile-let-syntax!, no proper per-name un-registration), cond-expand
;; (a small, honestly-hardcoded feature list -- see feature-satisfied?;
;; no (library ...) requirement support, since this compiler has no
;; library registry to query the way the real analyzer does), import
;; (top-level only; runs for real at compile time AND is emitted as a
;; runtime call to a new (creme bootstrap) builtin, `import!`, that
;; wraps Interpreter#import_into -- see compile-import!), a fallback
;; macro-use check against whatever import! just brought into the
;; target env -- see target-env-macro-expand, needed since a defmacro/
;; define-syntax macro EXPORTED from another library is exported live
;; (a plain Macro/SchemeSyntaxRules value sitting in an env binding,
;; same as any other export), not expanded away ahead of time -- and
;; ordinary application (including call/cc,
;; dynamic-wind, make-parameter, force, and eval, which need no special
;; compiler support at all -- they're just ordinary global procedures).
;; No full numeric tower as
;; quoted literal data beyond what (creme bytecode) itself serializes
;; (that library's write-datum! supports the full tower, floats
;; included, via a real IEEE754 bit-level primitive -- see
;; modules/creme/math.cr's flonum->bits), and no include/include-ci
;; (deliberately skipped: correct relative-path resolution for an
;; included file is a real design question this bootstrap effort didn't
;; need an answer to yet, and getting it wrong silently is worse than
;; not having it). Growing this dialect the rest of the way toward full
;; R7RS parity is tracked separately; this library's job is to prove the
;; compile-verify-via-load-chunk-bytes loop actually works end to end on
;; a real, nontrivial, self-hosting program.
;;
;; Every primitive (+, -, car, vector-ref, ...) compiles as an ORDINARY
;; call to its global binding -- no fused arithmetic/comparison/vector
;; opcodes are emitted at all, since Call already dispatches to a Builtin
;; correctly.
;;
;; Register allocation is a dumb, never-reclaiming bump allocator (Lua-
;; style FunctionCompiler#alloc_reg minus the scope-reclaim/high-water-
;; mark discipline) -- correct but wasteful; acceptable for a bootstrap
;; compiler compiling modest-sized programs. Call arguments (and
;; Destructure targets, and case-lambda clauses) are the places
;; contiguity actually matters: the callee's and every argument's
;; register is reserved FIRST, in order, before any of their expressions
;; are compiled, so nested sub-expression temporaries (allocated
;; afterward) can never land inside that reserved block.
;; ===========================================================================

(define-library (creme compiler compiler)
  (export compile-source-to-bytes compile-program ensure-libraries-loaded! defmacro-expand-form
          define-syntax-expand-form mark-self-hosted-library-loaded! import!-apply-aliases!
          required-native-families-list mark-redefined! unmark-redefined! fusable-prim-names)
  (import (scheme base) (scheme cxr) (scheme inexact) (scheme complex) (scheme eval)
          (creme bytecode) (creme bootstrap) (creme introspection) (creme compiler reader)
          (creme file))
  (begin

    ;; ---------------------------------------------------------------------
    ;; Function-compiler: one per lambda (+ one for the top-level program),
    ;; tracking its own chunk, lexical scope chain, and register watermark.
    ;; ---------------------------------------------------------------------

    (define-record-type <fcomp>
      (make-fcomp-raw chunk parent scopes next-reg captured-regs)
      fcomp?
      (chunk fcomp-chunk)
      (parent fcomp-parent)
      (scopes fcomp-scopes fcomp-scopes-set!)
      (next-reg fcomp-next-reg fcomp-next-reg-set!)
      (captured-regs fcomp-captured-regs fcomp-captured-regs-set!))

    ;; A scope frame is #(names-alist saved-next-reg persistent-high-water)
    ;; -- a plain mutable vector, consistent with this compiler's existing
    ;; preference for plain data structures over new record types (e.g.
    ;; fused-prim-table) rather than a dedicated define-record-type.
    ;; `saved-next-reg` is fcomp-next-reg as of fcomp-push-scope!, restored
    ;; (subject to the captured-register floor below) by fcomp-pop-scope!.
    ;; `persistent-high-water` is the highest register+1 among this scope's
    ;; OWN declared locals so far (bumped by fcomp-declare-local!) -- a
    ;; MID-scope reclaim (fcomp-reclaim-to!, some statement's own disposable
    ;; temps) must never roll back below it, or a persistent local declared
    ;; by that very statement (an internal define, extending the CURRENT
    ;; scope rather than pushing its own) would have its register silently
    ;; handed back out to a later, unrelated temp. A scope-EXIT reclaim
    ;; (fcomp-pop-scope!) does NOT consult this -- mirroring
    ;; bytecode_compiler.cr's own reclaim_to/pop_scope split exactly (see
    ;; that file's own doc comment) -- the whole scope, persistent locals
    ;; included, is genuinely gone once it pops.
    (define (make-scope-frame saved-next-reg)
      (vector '() saved-next-reg saved-next-reg))
    (define (scope-frame-names f) (vector-ref f 0))
    (define (scope-frame-names-set! f v) (vector-set! f 0 v))
    (define (scope-frame-saved-next-reg f) (vector-ref f 1))
    (define (scope-frame-persistent-high-water f) (vector-ref f 2))
    (define (scope-frame-persistent-high-water-set! f v) (vector-set! f 2 v))

    (define (make-fcomp chunk parent) (make-fcomp-raw chunk parent (list (make-scope-frame 0)) 0 '()))

    ;; Whole-function (not scope-local), incrementally-populated set of this
    ;; function's OWN local registers that some nested closure has captured
    ;; as an upvalue -- mirrors bytecode_compiler.cr's captured_registers,
    ;; populated at exactly the same moment (see fcomp-resolve-upvalue!'s
    ;; from-parent-local branch below). Used to gate the fast in-place
    ;; tail-call-argument path (see compile-ordinary-app!): a register in
    ;; this set may be an OPEN upvalue, so writing a new tail-call argument
    ;; directly into it before the runtime closes that upvalue would let
    ;; the closure observe the wrong value. Safe as a single incremental,
    ;; single-pass set (not a pre-scan) because this compiler compiles a
    ;; function body in strict textual order, matching the only order
    ;; execution can take within one invocation (no backward jumps within a
    ;; frame, only recursive calls that start fresh frames) -- any closure
    ;; whose capture could possibly still be open when a given tail call
    ;; executes must, in that same invocation, have been created (and thus
    ;; already compiled, already recorded here) earlier in that same
    ;; control-flow path.
    ;;
    ;; ALSO used (unlike the reference compiler) as a floor on register
    ;; reclaim generally -- see fcomp-captured-floor/fcomp-pop-scope!/
    ;; fcomp-reclaim-to! below. bytecode_compiler.cr's own pop_scope rolls
    ;; next_reg back to saved_next_reg UNCONDITIONALLY, never consulting
    ;; captured_registers at all; verified empirically this is a genuine,
    ;; reproducible correctness bug in that implementation (a closure
    ;; capturing a let-bound local, called after a LATER sibling scope's
    ;; own local happens to reuse the same now-reclaimed register number,
    ;; observes the sibling's value instead -- upvalues are only closed at
    ;; frame-return/tail-call time, never at ordinary lexical scope exit,
    ;; per vm.cr's close_upvalues call sites). This compiler's own version
    ;; is deliberately stricter: never reclaim ANY register at or below the
    ;; highest one ever captured in this function, for the rest of this
    ;; function's compilation -- a conservative, safe-by-construction
    ;; over-approximation, exactly the same tradeoff captured-regs itself
    ;; already makes (whole-function rather than true liveness).
    (define (fcomp-mark-captured! fc reg)
      (fcomp-captured-regs-set! fc (cons reg (fcomp-captured-regs fc))))
    (define (fcomp-captured? fc reg) (and (memv reg (fcomp-captured-regs fc)) #t))
    (define (fcomp-captured-floor fc)
      (let loop ((regs (fcomp-captured-regs fc)) (best -1))
        (if (null? regs)
            (+ best 1)
            (loop (cdr regs) (if (> (car regs) best) (car regs) best)))))

    (define (fcomp-alloc-reg! fc)
      (let ((r (fcomp-next-reg fc)))
        (fcomp-next-reg-set! fc (+ r 1))
        (if (> (+ r 1) (chunk-num-registers (fcomp-chunk fc)))
            (chunk-num-registers-set! (fcomp-chunk fc) (+ r 1)))
        r))

    ;; Returns the first of `n` contiguously allocated registers -- the same
    ;; "reserve the whole block up front" pattern compile-app!'s call args
    ;; and case-lambda's clauses use, needed here for Destructure's
    ;; dst[b..b+c) contiguity requirement.
    (define (fcomp-alloc-regs! fc n)
      (let ((first (fcomp-alloc-reg! fc)))
        (let loop ((i 1))
          (if (< i n) (begin (fcomp-alloc-reg! fc) (loop (+ i 1)))))
        first))

    (define (fcomp-push-scope! fc)
      (fcomp-scopes-set! fc (cons (make-scope-frame (fcomp-next-reg fc)) (fcomp-scopes fc))))

    ;; #t only at the TRUE top level of a whole program -- not inside any
    ;; closure (fcomp-parent) AND not inside any lexical scope at all, not
    ;; even a plain (let () ...) with no closure of its own (make-fcomp
    ;; always seeds one base scope-frame, so "no scope" is (cdr (fcomp-
    ;; scopes fc)) being empty, one frame short of fcomp-scopes itself
    ;; being null -- fcomp-scopes is NEVER actually null). Mirrors
    ;; bytecode_compiler.cr's own at_toplevel check (fc.scope.nil? &&
    ;; fc.is_toplevel?) exactly -- used by compile-defmacro!/compile-
    ;; define-syntax! to decide whether a HelperForm-emitting runtime
    ;; global registration is correct here (only at true top level) or
    ;; would incorrectly leak an internal, let-scoped macro's binding
    ;; past its own lexical scope.
    (define (fcomp-at-toplevel? fc)
      (and (not (fcomp-parent fc)) (null? (cdr (fcomp-scopes fc)))))

    ;; Scope-exit reclaim: restores next-reg to this scope's saved-next-reg
    ;; (NOT respecting persistent-high-water -- the whole scope, persistent
    ;; locals included, is genuinely gone), floored at fcomp-captured-floor
    ;; (see its own doc comment for why this floor exists at all).
    (define (fcomp-pop-scope! fc)
      (let* ((frames (fcomp-scopes fc))
             (top (car frames))
             (floor (fcomp-captured-floor fc))
             (target (scope-frame-saved-next-reg top)))
        (fcomp-scopes-set! fc (cdr frames))
        (fcomp-next-reg-set! fc (if (> target floor) target floor))))

    ;; Mid-scope reclaim: rolls next-reg back to `mark` -- some expression's
    ;; own disposable temporaries -- floored at whichever is higher: the
    ;; CURRENT scope's persistent-high-water (protects a persistent local
    ;; declared as part of compiling that very statement) or
    ;; fcomp-captured-floor (protects any register captured anywhere in
    ;; this function so far). Safe to call with no active scope at all
    ;; (shouldn't happen in practice -- make-fcomp always seeds one base
    ;; frame -- but falls back to just `mark` if it ever did).
    (define (fcomp-reclaim-to! fc mark)
      (let* ((frames (fcomp-scopes fc))
             (scope-floor (if (null? frames) mark (scope-frame-persistent-high-water (car frames))))
             (captured-floor (fcomp-captured-floor fc))
             (floor (if (> scope-floor captured-floor) scope-floor captured-floor)))
        (fcomp-next-reg-set! fc (if (> mark floor) mark floor))))

    (define (fcomp-declare-local! fc name reg)
      (let ((top (car (fcomp-scopes fc))))
        (scope-frame-names-set! top (cons (cons name reg) (scope-frame-names top)))
        (if (> (+ reg 1) (scope-frame-persistent-high-water top))
            (scope-frame-persistent-high-water-set! top (+ reg 1)))))

    (define (fcomp-lookup-local fc name)
      (let loop ((frames (fcomp-scopes fc)))
        (if (null? frames)
            #f
            (let ((hit (assq name (scope-frame-names (car frames)))))
              (if hit (cdr hit) (loop (cdr frames)))))))

    ;; Standard Lua-style upvalue-chain resolution: a free variable is either
    ;; already captured by this function, a LOCAL in the immediately
    ;; enclosing function (from-parent-local #t), or forwarded from that
    ;; function's own upvalue array (from-parent-local #f) -- recursing all
    ;; the way up; #f if it's not found anywhere (a global reference).
    (define (fcomp-resolve-upvalue! fc name)
      (let* ((ch (fcomp-chunk fc))
             (existing (chunk-find-upval-index ch name)))
        (if existing
            existing
            (let ((parent (fcomp-parent fc)))
              (if (not parent)
                  #f
                  (let ((plocal (fcomp-lookup-local parent name)))
                    (if plocal
                        (begin
                          (fcomp-mark-captured! parent plocal)
                          (chunk-add-upval! ch name #t plocal))
                        (let ((pupval (fcomp-resolve-upvalue! parent name)))
                          (if pupval (chunk-add-upval! ch name #f pupval) #f)))))))))

    ;; ---------------------------------------------------------------------
    ;; Compilation. Every compile-*! writes its result into register `dest`;
    ;; when `tail?` is true, it ALSO fully finishes control flow itself
    ;; (Return or TailCall) -- callers never emit a trailing Return of their
    ;; own, since a tail expression's own compilation always already did.
    ;; ---------------------------------------------------------------------

    (define (parse-formals formals)
      (cond
        ((null? formals) (cons '() #f))
        ((symbol? formals) (cons '() formals))
        ((pair? formals)
         (if (not (symbol? (car formals)))
             (error "bootstrap compiler: bad formal parameter" (car formals)))
         (let ((rest (parse-formals (cdr formals))))
           (cons (cons (car formals) (car rest)) (cdr rest))))
        (else (error "bootstrap compiler: bad formals" formals))))

    (define (finish-tail! fc dest tail?)
      (if tail? (chunk-emit! (fcomp-chunk fc) 'Return dest 0 0 0))
      dest)

    (define (compile-literal-datum! fc datum dest tail?)
      (chunk-emit! (fcomp-chunk fc) 'LoadK dest (chunk-add-const! (fcomp-chunk fc) datum) 0 0)
      (finish-tail! fc dest tail?))

    ;; When compiling a specific library's own body (current-library-
    ;; visible-names non-#f), a free-variable name this library never
    ;; imported/defined itself is compiled against a MANGLED global name
    ;; instead of the real one -- guaranteed to never be genuinely bound
    ;; process-wide, so the library's own definition still compiles and
    ;; loads successfully (matching native's own observed behavior: a
    ;; library loads fine even referencing something it can't see), and
    ;; only actually CALLING through to it raises "unbound variable", at
    ;; the R7RS-mandated moment -- not a moment earlier. See current-
    ;; library-visible-names' own doc comment for the full mechanism.
    (define (global-ref-name fc name)
      (if (and current-library-visible-names
               (not (fcomp-lookup-local fc name))
               (not (fcomp-resolve-upvalue! fc name))
               (not (memq name current-library-visible-names)))
          (string-append current-library-mangle-prefix ":" (symbol->string name))
          name))

    ;; `tail?`: when true, this read is immediately returned -- dest is
    ;; discarded the instant the call returns, so there's nothing to gain by
    ;; materializing the value there first. A local just Returns straight
    ;; from its own register (Return already accepts any register, no new
    ;; op needed); an upvalue/global has no register to already be in, so
    ;; ReturnUpval/ReturnGlobal resolve and deliver directly, skipping the
    ;; register write GetUpval/GetGlobal would otherwise need -- mirrors
    ;; bytecode_compiler.cr's compile_name_read exactly (previously this
    ;; always emitted Move/GetUpval/GetGlobal + a separate trailing Return,
    ;; a real extra-instruction codegen gap in every tail-position variable
    ;; reference, not just the local case).
    (define (compile-var-ref! fc name dest tail?)
      (let ((local (fcomp-lookup-local fc name)))
        (cond
          (local
           (if tail?
               (chunk-emit! (fcomp-chunk fc) 'Return local 0 0 0)
               (chunk-emit! (fcomp-chunk fc) 'Move dest local 0 0)))
          (else
           (let ((up (fcomp-resolve-upvalue! fc name)))
             (cond
               (up
                (if tail?
                    (chunk-emit! (fcomp-chunk fc) 'ReturnUpval up 0 0 0)
                    (chunk-emit! (fcomp-chunk fc) 'GetUpval dest up 0 0)))
               (else
                (if tail?
                    (chunk-emit! (fcomp-chunk fc) 'ReturnGlobal (chunk-add-const! (fcomp-chunk fc) (global-ref-name fc name)) 0 0 0)
                    (chunk-emit! (fcomp-chunk fc) 'GetGlobal dest (chunk-add-const! (fcomp-chunk fc) (global-ref-name fc name)) 0 0)))))))))

    ;; ---------------------------------------------------------------------
    ;; syntax-rules macros -- non-hygienic (plain substitution, no renaming),
    ;; matching this Scheme's own reference implementation (see its README's
    ;; Known caveats: "define-syntax/syntax-rules is unhygienic") -- so this
    ;; doesn't need to solve capture-avoidance at all, only pattern matching
    ;; and template substitution. define-syntax is COMPILE-TIME only: it
    ;; registers a transformer in a single shared, always-global table
    ;; (macro-table) -- no per-file/per-library isolation, just save/restore
    ;; scoping for let-syntax/letrec-syntax (see compile-let-syntax!) -- and
    ;; no runtime bytecode is ever emitted for the define-syntax form
    ;; itself. A macro use is expanded the moment compile-form! sees its
    ;; keyword in head position, then the EXPANSION is compiled in its
    ;; place -- recursively, so a macro expanding to another macro use
    ;; (including itself, for a loop-shaped macro) just works via ordinary
    ;; compile-expr! recursion.
    ;;
    ;; Only single-level `...` ellipsis is supported per pattern/template
    ;; list (no nested repeated ellipsis) -- the same restriction quasiquote
    ;; expansion accepts, and enough for the overwhelming majority of real
    ;; macros (variadic argument lists, simple recursive clause-list macros).
    ;; ---------------------------------------------------------------------

    (define macro-table '())
    (define (macro-register! name transformer) (set! macro-table (cons (cons name transformer) macro-table)))
    (define (macro-lookup name)
      (let ((hit (assq name macro-table)))
        (if hit (cdr hit) #f)))

    (define (sr-pattern-vars pat literals)
      (cond
        ((eq? pat '_) '())
        ((eq? pat '...) '())
        ((and (symbol? pat) (memq pat literals)) '())
        ((symbol? pat) (list pat))
        ((pair? pat) (append (sr-pattern-vars (car pat) literals) (sr-pattern-vars (cdr pat) literals)))
        (else '())))

    (define (sr-pattern-fixed-length pat)
      (if (pair? pat) (+ 1 (sr-pattern-fixed-length (cdr pat))) 0))

    (define (sr-list-take lst n) (if (= n 0) '() (cons (car lst) (sr-list-take (cdr lst) (- n 1)))))
    (define (sr-list-drop lst n) (if (= n 0) lst (sr-list-drop (cdr lst) (- n 1))))
    (define (sr-any-false? lst) (and (pair? lst) (or (not (car lst)) (sr-any-false? (cdr lst)))))

    ;; Returns an alist of (pattern-var . value), where an ellipsis-repeated
    ;; variable's value is (ellipsis v0 v1 ... vn) -- one entry per
    ;; repetition, in order -- or #f on mismatch. The pattern's own head
    ;; (traditionally the macro's name/an underscore) is never matched here;
    ;; callers pass (cdr pattern)/(cdr form).
    (define (sr-match pattern form literals)
      (cond
        ((eq? pattern '_) '())
        ((and (symbol? pattern) (memq pattern literals)) (if (eq? form pattern) '() #f))
        ((symbol? pattern) (list (cons pattern form)))
        ((null? pattern) (if (null? form) '() #f))
        ((pair? pattern)
         (if (and (pair? (cdr pattern)) (eq? (cadr pattern) '...))
             (sr-match-ellipsis pattern form literals)
             (and (pair? form)
                  (let ((b1 (sr-match (car pattern) (car form) literals)))
                    (and b1
                         (let ((b2 (sr-match (cdr pattern) (cdr form) literals)))
                           (and b2 (append b1 b2))))))))
        (else (if (equal? pattern form) '() #f))))

    (define (sr-match-ellipsis pattern form literals)
      (let* ((rep-pat (car pattern))
             (rest-pat (cddr pattern))
             (rest-len (sr-pattern-fixed-length rest-pat)))
        (if (or (not (list? form)) (< (length form) rest-len))
            #f
            (let* ((n-rep (- (length form) rest-len))
                   (rep-forms (sr-list-take form n-rep))
                   (rest-forms (sr-list-drop form n-rep))
                   (rep-bindings (map (lambda (f) (sr-match rep-pat f literals)) rep-forms)))
              (if (sr-any-false? rep-bindings)
                  #f
                  (let* ((vars (sr-pattern-vars rep-pat literals))
                         (ellipsis-bindings
                           (map (lambda (v) (cons v (cons 'ellipsis (map (lambda (b) (cdr (assq v b))) rep-bindings)))) vars))
                         (rest-bindings (sr-match rest-pat rest-forms literals)))
                    (and rest-bindings (append ellipsis-bindings rest-bindings))))))))

    (define (sr-template-vars t)
      (cond
        ((symbol? t) (list t))
        ((pair? t) (append (sr-template-vars (car t)) (sr-template-vars (cdr t))))
        (else '())))

    (define (sr-ellipsis-binding? bindings v)
      (let ((hit (assq v bindings))) (and hit (pair? (cdr hit)) (eq? (cadr hit) 'ellipsis))))

    (define (sr-expand template bindings)
      (cond
        ((symbol? template)
         (let ((hit (assq template bindings)))
           (if hit (cdr hit) template)))
        ((pair? template)
         (if (and (pair? (cdr template)) (eq? (cadr template) '...))
             (append (sr-expand-ellipsis (car template) bindings) (sr-expand (cddr template) bindings))
             (cons (sr-expand (car template) bindings) (sr-expand (cdr template) bindings))))
        (else template)))

    (define (sr-expand-ellipsis sub-template bindings)
      (let* ((vars (sr-template-vars sub-template))
             (ell-vars (sr-filter (lambda (v) (sr-ellipsis-binding? bindings v)) vars)))
        (if (null? ell-vars)
            '()
            (let ((n (length (cddr (assq (car ell-vars) bindings)))))
              (map
                (lambda (i)
                  (let ((sub-bindings
                          (map (lambda (b) (if (memq (car b) ell-vars) (cons (car b) (sr-list-ref (cddr b) i)) b)) bindings)))
                    (sr-expand sub-template sub-bindings)))
                (sr-iota n))))))

    (define (sr-filter pred lst)
      (cond ((null? lst) '()) ((pred (car lst)) (cons (car lst) (sr-filter pred (cdr lst)))) (else (sr-filter pred (cdr lst)))))
    (define (sr-iota n)
      (let loop ((i 0) (acc '())) (if (= i n) (reverse acc) (loop (+ i 1) (cons i acc)))))
    (define (sr-list-ref lst i) (if (= i 0) (car lst) (sr-list-ref (cdr lst) (- i 1))))

    (define (sr-make-transformer literals clauses)
      (lambda (form)
        (let loop ((cs clauses))
          (if (null? cs)
              (error "bootstrap compiler: no matching syntax-rules clause for" form)
              (let* ((clause (car cs))
                     (pattern (car clause))
                     (template (cadr clause))
                     (bindings (sr-match (cdr pattern) (cdr form) literals)))
                (if bindings (sr-expand template bindings) (loop (cdr cs))))))))

    ;; Compiles `forms` as an entirely fresh, independent top-level program
    ;; (its own <fcomp>, its own Chunk) and immediately runs the result
    ;; against the CURRENT process's own global table -- the self-hosted
    ;; compiler compiling and running a small snippet AT ITS OWN COMPILE
    ;; TIME, not as part of whatever OUTER program it's currently
    ;; compiling. Used by both compile-defmacro! (a transformer invocation)
    ;; and the library loader below (a library's own top-level body).
    ;; load-chunk-bytes is hardwired to run against the global table on
    ;; both backends (there is no way to target an arbitrary non-global
    ;; environment) -- fine here, since everything this is used for only
    ;; ever needs ordinary global-scope bindings anyway.
    ;; Passes the CURRENT required-native-families-list (accumulated so
    ;; far, forward reference -- see this section's own convention on why
    ;; that's fine) into chunk->bytes, not just an implicit empty list: a
    ;; file-based library's own top-level (begin ...) body can genuinely
    ;; call a native builtin directly (not just via a nested `import`,
    ;; which ensure-library-loaded! -- the only caller of THIS
    ;; procedure -- already processes first, per-clause, in file order,
    ;; so by the time a library's OWN begin clause runs, any earlier
    ;; import clause's own required families are already recorded here).
    ;; Needed for e.g. (creme spec)'s own top-level ANSI-color-detection
    ;; code, which calls (creme term)'s stdout-tty? and (scheme
    ;; process-context)'s environment accessors immediately at library-
    ;; load time -- without this, that call would abort on an unbound
    ;; variable, caught and silently swallowed by compile-import!'s own
    ;; (guard (e (#t #f)) ...), leaving the WHOLE library's exports
    ;; (spec-describe!/spec-it!/etc) undefined with no visible error until
    ;; a much later, more confusing "unbound variable: spec-describe!".
    (define (run-compiled-forms! forms)
      (load-chunk-bytes (chunk->bytes (compile-program forms) (required-native-families-list))))

    ;; define-syntax's own "value" is unspecified, same convention as
    ;; define/set!: nothing reads a non-tail define-syntax's dest.
    ;;
    ;; A TOP-LEVEL define-syntax also emits Op::HelperForm (kind 3), the
    ;; SAME opcode/kind Crystal's own bytecode_compiler.cr emits for one
    ;; (compile_helper_form's DefineSyntax branch) -- at run time this
    ;; calls Interpreter#eval_define_syntax (vm.cr's exec_helper_form),
    ;; which defines a genuine runtime SchemeSyntaxRules value into the
    ;; global env, exactly like Crystal's own compiler produces. Without
    ;; this, macro-register! alone only ever affected THIS compile
    ;; session's own macro-table (needed so a LATER top-level form in the
    ;; same compile-program call can still use the macro), leaving no
    ;; runtime-visible binding at all -- so expand-if-macro (used by
    ;; cvm's bootstrap bridge, or any later, separate program/eval call)
    ;; could never detect a self-hosted-compiled top-level macro, unlike
    ;; a natively-compiled one. An INTERNAL (non-top-level) define-syntax
    ;; does NOT get this -- matching native's own at_toplevel check
    ;; (compile_helper_form): its scoping is already fully handled by
    ;; macro-table's own save/restore (compile-scoped-body!), and giving
    ;; it a permanent runtime global binding would leak it past its own
    ;; lexical scope, the same misbehavior compile-scoped-body!'s own
    ;; fix was for.
    (define (compile-define-syntax! fc expr dest tail?)
      (let* ((name (cadr expr))
             (sr-form (caddr expr)))
        (if (not (eq? (car sr-form) 'syntax-rules))
            (error "bootstrap compiler: only (syntax-rules ...) transformers are supported in define-syntax" expr)
            (macro-register! name (sr-make-transformer (cadr sr-form) (cddr sr-form))))
        (if (fcomp-at-toplevel? fc)
            (let* ((ch (fcomp-chunk fc))
                   (form-idx (chunk-add-const! ch expr)))
              (chunk-emit! ch 'HelperForm dest form-idx 3 0)
              (if tail? (chunk-emit! ch 'Return dest 0 0 0)))
            (if tail? (compile-literal-datum! fc '() dest #t)))))

    ;; (defmacro name (formals...) body...) -- this interpreter's own
    ;; non-hygienic macro form (see e.g. modules/creme/dao.sld's
    ;; define-dao). Unlike syntax-rules' pattern-matching transformer, a
    ;; defmacro's formals bind POSITIONALLY against the macro use's own
    ;; argument list -- ordinary lambda-formals semantics (dotted rest
    ;; included, via the same parse-formals compile-lambda! already uses),
    ;; each bound to the RAW, UNEVALUATED argument form; the transformer
    ;; BODY then runs, its LAST form's value becoming the expansion
    ;; (mirrors the real interpreter's own expand_defmacro exactly: bind
    ;; params to raw arg forms in a fresh env, run the body forms against
    ;; it, last value wins -- interpreter.cr's own bind_params/run_program
    ;; sequence).
    ;;
    ;; This compiler has no way to run a form against an arbitrary
    ;; non-global environment (run-compiled-forms!/load-chunk-bytes is
    ;; hardwired to the global table on both backends -- there's no
    ;; per-call fresh-env mechanism available), so instead of a real fresh
    ;; env, the params are bound via an ordinary `let` wrapping the
    ;; transformer body, each value a `(quote ...)`'d copy of its own raw
    ;; argument form -- genuine lexical binding regardless of which env
    ;; the wrapping compile-program targets. Behaviorally identical to the
    ;; real semantics for any transformer whose body only touches
    ;; ordinary global bindings -- the only kind of transformer this
    ;; compiler could support either way (see dao.sld's own header
    ;; comment: a defmacro transformer already can't see its OWN
    ;; library's private, non-exported bindings under the real
    ;; interpreter either, for exactly this reason).
    ;;
    ;; Shared by compile-defmacro!'s own registered transformer below (for
    ;; a LOCAL, same-compile-session macro use) and cvm's bootstrap.c
    ;; (bi_expand_if_macro, via cvm_apply, looking this up by name in
    ;; vm->globals) for a defmacro EXPORTED from a library compiled
    ;; straight to bytecode -- e.g. sxql-select! from (creme sxql),
    ;; Crystal-native-precompiled into a cvm image -- whose runtime value,
    ;; once Op::HelperForm's kind==4 case binds it (vm.c), is a T_MACRO
    ;; wrapping this exact (defmacro name (params...) body...) form. Both
    ;; call sites need the SAME "bind params positionally to the call's
    ;; own raw, unevaluated argument forms, then compile+run the body"
    ;; semantics (mirrors the real interpreter's own expand_defmacro
    ;; exactly, see compile-defmacro!'s own doc comment below), so it's
    ;; built once here from the RAW form rather than risking the two
    ;; drifting apart. Exported under this exact name (compiler.sld's own
    ;; export clause) since a C builtin can only ever find a Scheme
    ;; procedure by looking it up as a named global.
    (define (defmacro-expand-form macro-def-form call-form)
      (let* ((parsed (parse-formals (caddr macro-def-form)))
             (fixed (car parsed))
             (rest (cdr parsed))
             (body (cdddr macro-def-form))
             (args (cdr call-form))
             (n (length fixed))
             (n-args (length args)))
        ;; Explicit arity check -- too few args used to crash inside
        ;; sr-list-take itself (car of an already-exhausted list), an
        ;; incidental but still-raising error; too many args (with no
        ;; rest param to absorb them) used to silently succeed, dropping
        ;; the extras with no error at all -- found by porting spec/
        ;; scheme/compile/macro_spec.cr's own "shadows a special form"
        ;; case: (defmacro if (a) a) (if #t 1 2) expanded with `a` bound
        ;; only to #t, silently discarding the 2 extra call args, instead
        ;; of raising like native's own build_macro/bind_params does.
        (if (< n-args n) (error "bootstrap compiler: macro call: too few arguments" call-form))
        (if (and (not rest) (> n-args n)) (error "bootstrap compiler: macro call: too many arguments" call-form))
        (let* ((fixed-args (sr-list-take args n))
               (rest-args (sr-list-drop args n))
               (fixed-bindings (map (lambda (p a) (list p (list 'quote a))) fixed fixed-args))
               (rest-binding (if rest (list (list rest (list 'quote rest-args))) '())))
          (run-compiled-forms! (list (cons 'let (cons (append fixed-bindings rest-binding) body)))))))

    ;; defmacro-expand-form's own sibling for a TOP-LEVEL define-syntax
    ;; exported to bytecode -- same reason/same two call sites (a LOCAL,
    ;; same-compile-session use via macro-table, and cvm's bootstrap.c
    ;; bi_expand_if_macro for one reentrant-compiled under cvm), just
    ;; syntax-rules' own real pattern-matching semantics (sr-make-
    ;; transformer, already used by compile-define-syntax! below to
    ;; register a LOCAL macro-table entry) instead of defmacro's
    ;; positional-binding ones -- the two transformer models are NOT
    ;; interchangeable (a define-syntax form's own body, `(syntax-rules
    ;; (literals...) (pattern template) ...)`, has nothing in common with
    ;; a defmacro's `(formals) body...`), so bridging a define-syntax-
    ;; exported macro through defmacro-expand-form would silently
    ;; misparse it. `raw-form` here is `(define-syntax name (syntax-rules
    ;; ...))` -- (caddr raw-form) is that whole `(syntax-rules ...)` form.
    (define (define-syntax-expand-form raw-form call-form)
      (let ((sr-form (caddr raw-form)))
        ((sr-make-transformer (cadr sr-form) (cddr sr-form)) call-form)))

    ;; Validates expr's own (defmacro name formals body...) shape EAGERLY,
    ;; at compile time -- matching where native's own build_macro
    ;; (interpreter.cr, called from eval_defmacro) raises: at the
    ;; defmacro FORM's own eval time, unconditionally (its analyze-time
    ;; call, analyze_defmacro, silently swallows the same errors so they
    ;; surface only once, at eval). Without this, every one of these
    ;; malformed shapes silently registered a transformer anyway
    ;; (macro-register! never inspected expr itself) that would only
    ;; raise a confusing, unrelated internal error (e.g. "caddr: expected
    ;; pair, got ()") the first time the macro was actually USED, if ever
    ;; -- found by porting spec/scheme/compile/macro_spec.cr's own
    ;; "malformed input" cases, none of which ever call the macro they
    ;; define.
    ;;
    ;; A TOP-LEVEL defmacro also emits Op::HelperForm (kind 4) -- see
    ;; compile-define-syntax!'s own comment on the identical case there
    ;; (same runtime mechanism, same at-toplevel-only rule, same reason:
    ;; without it, expand-if-macro could never detect a self-hosted-
    ;; compiled top-level defmacro, only a natively-compiled one).
    (define (compile-defmacro! fc expr dest tail?)
      (if (not (pair? (cdr expr))) (error "bootstrap compiler: defmacro: malformed" expr))
      (let ((name (cadr expr)))
        (if (not (symbol? name)) (error "bootstrap compiler: defmacro: macro name must be a symbol" expr))
        (if (not (pair? (cddr expr))) (error "bootstrap compiler: defmacro: malformed" expr))
        (if (null? (cdddr expr)) (error "bootstrap compiler: defmacro: macro body is empty" expr))
        (parse-formals (caddr expr)) ; raises "bad formals" for a malformed formal-parameter spec
        (macro-register! name (lambda (form) (defmacro-expand-form expr form)))
        (if (fcomp-at-toplevel? fc)
            (let* ((ch (fcomp-chunk fc))
                   (form-idx (chunk-add-const! ch expr)))
              (chunk-emit! ch 'HelperForm dest form-idx 4 0)
              (if tail? (chunk-emit! ch 'Return dest 0 0 0)))
            (if tail? (compile-literal-datum! fc '() dest #t)))))

    ;; let-syntax/letrec-syntax -- treated identically (macro-table lookup
    ;; is global regardless of registration order, so there's no observable
    ;; difference between "these macros can see each other" and "they
    ;; can't" the way there would be for letrec vs let with real values).
    ;; Scoped by saving/restoring the WHOLE macro-table snapshot around the
    ;; body, rather than un-registering just these names afterward, so
    ;; shadowing an outer macro of the same name also un-shadows correctly
    ;; once the body's done. Simplification: a define-syntax textually
    ;; nested inside the body that's meant to escape this scope (unusual)
    ;; would also get discarded by the restore -- rare enough to accept
    ;; (and, checked this session against analyzer.cr's own analyze_
    ;; define_syntax: Crystal's parent-chained MacroEnv discards it the
    ;; same way, registering into whatever @analyzing_macros is current --
    ;; the child, while inside let-syntax -- so this isn't even a
    ;; divergence from Crystal, just a shared restriction). Verified
    ;; equivalent to Crystal's child-MacroEnv chain (analyze_let_syntax)
    ;; for shadowing an outer macro of the same name and correctly un-
    ;; shadowing it afterward, sibling let-syntax forms not leaking into
    ;; each other, and nested let-syntax shadowing an enclosing let-
    ;; syntax's own same-named macro -- see compiler_spec.cr's own
    ;; "let-syntax/letrec-syntax scoping edge cases" comment.
    (define (compile-let-syntax! fc bindings body dest tail?)
      (let ((saved macro-table))
        (for-each
          (lambda (binding)
            (let* ((name (car binding)) (sr-form (cadr binding)))
              (if (not (eq? (car sr-form) 'syntax-rules))
                  (error "bootstrap compiler: only (syntax-rules ...) transformers are supported" binding)
                  (macro-register! name (sr-make-transformer (cadr sr-form) (cddr sr-form))))))
          bindings)
        (compile-scoped-body! fc body dest tail?)
        (set! macro-table saved)))

    (define (compile-expr! fc expr dest tail?)
      (cond
        ((symbol? expr) (compile-var-ref! fc expr dest tail?))
        ((or (number? expr) (string? expr) (char? expr) (boolean? expr) (vector? expr) (bytevector? expr))
         (compile-literal-datum! fc expr dest tail?))
        ((pair? expr) (compile-form! fc expr dest tail?))
        (else (error "bootstrap compiler: cannot compile expression" expr))))

    ;; R7RS: syntactic keywords are lexically scoped bindings, so a local
    ;; macro (defmacro/define-syntax/let-syntax) named after a special
    ;; form -- e.g. (defmacro if (a) a) -- shadows it, exactly like any
    ;; other identifier. macro-lookup (a cheap assq over this compile
    ;; session's own, typically tiny, macro-table) is checked FIRST, here,
    ;; before any fixed special-form dispatch below, to make that possible
    ;; -- mirroring native's own priority order exactly (analyzer.cr's
    ;; analyze_cons checks @analyzing_macros.lookup, the local-macro
    ;; table, BEFORE env.get?'s SchemeSpecialForm marker check). The
    ;; expensive Crystal-bridge fallback (target-env-macro-expand, for a
    ;; macro exported from an already-compiled bytecode library) stays a
    ;; LOW-priority fallback below, unlike this: shadowing a special form
    ;; via a precompiled bytecode macro is vanishingly rare, and checking
    ;; it first would run an expensive bridge call for every ordinary
    ;; special-form use in the program, not just macro-table's cheap
    ;; local lookup.
    (define (compile-form! fc expr dest tail?)
      (let ((head (car expr)))
        (cond
          ((macro-lookup head) => (lambda (transformer) (compile-expr! fc (transformer expr) dest tail?)))
          ((eq? head 'quote) (compile-literal-datum! fc (cadr expr) dest tail?))
          ((eq? head 'if) (compile-if! fc expr dest tail?))
          ((eq? head 'lambda) (compile-lambda! fc (cadr expr) (cddr expr) dest tail? "lambda"))
          ((eq? head 'case-lambda) (compile-case-lambda! fc (cdr expr) dest tail?))
          ((or (eq? head 'delay) (eq? head 'delay-force)) (compile-delay! fc expr dest tail?))
          ((eq? head 'let) (compile-let! fc expr dest tail?))
          ((eq? head 'let*) (compile-let-star! fc (cadr expr) (cddr expr) dest tail?))
          ((or (eq? head 'letrec) (eq? head 'letrec*)) (compile-letrec! fc (cadr expr) (cddr expr) dest tail?))
          ((eq? head 'let-values) (compile-let-values! fc (cadr expr) (cddr expr) dest tail?))
          ((eq? head 'let*-values) (compile-let-star-values! fc (cadr expr) (cddr expr) dest tail?))
          ((eq? head 'define-values) (compile-define-values! fc expr dest tail?))
          ((eq? head 'guard) (compile-guard! fc expr dest tail?))
          ((eq? head 'parameterize) (compile-parameterize! fc expr dest tail?))
          ((eq? head 'when) (compile-when! fc (cadr expr) (cddr expr) dest tail?))
          ((eq? head 'unless) (compile-unless! fc (cadr expr) (cddr expr) dest tail?))
          ((eq? head 'and) (compile-and! fc (cdr expr) dest tail?))
          ((eq? head 'or) (compile-or! fc (cdr expr) dest tail?))
          ((eq? head 'cond) (compile-cond! fc (cdr expr) dest tail?))
          ((eq? head 'case) (compile-case! fc expr dest tail?))
          ((eq? head 'do) (compile-do! fc expr dest tail?))
          ((eq? head 'cond-expand) (compile-cond-expand! fc (cdr expr) dest tail?))
          ((eq? head 'begin) (compile-body! fc (cdr expr) dest tail?))
          ((eq? head 'set!) (compile-set! fc expr dest tail?))
          ((eq? head 'quasiquote) (compile-expr! fc (qq-expand-top (cadr expr)) dest tail?))
          ((eq? head 'define) (compile-define! fc expr dest tail?))
          ((eq? head 'define-record-type) (compile-define-record-type! fc expr dest tail?))
          ((eq? head 'define-syntax) (compile-define-syntax! fc expr dest tail?))
          ((eq? head 'defmacro) (compile-defmacro! fc expr dest tail?))
          ((eq? head 'import) (compile-import! fc expr dest tail?))
          ((or (eq? head 'let-syntax) (eq? head 'letrec-syntax)) (compile-let-syntax! fc (cadr expr) (cddr expr) dest tail?))
          ((target-env-macro-expand expr) => (lambda (expanded) (compile-expr! fc expanded dest tail?)))
          (else (compile-app! fc expr dest tail?)))))

    ;; Fallback macro check for a head this compiler never itself
    ;; registered via define-syntax/let-syntax -- an imported binding
    ;; that resolves, in the env compile-import! just eagerly imported
    ;; into (see compile-import! below), to a native defmacro-defined
    ;; Macro or a define-syntax-defined SchemeSyntaxRules value. Mirrors
    ;; the real analyzer's own two-tier check (local macro table first,
    ;; then the live target env) -- see (creme bootstrap)'s
    ;; expand-if-macro for why this needs a Crystal-side bridge at all:
    ;; detecting/expanding either value type needs Crystal-internal
    ;; state this compiler has no other way to see.
    (define (target-env-macro-expand expr)
      (let ((r (expand-if-macro expr)))
        (if (pair? r) (cdr r) #f)))

    ;; Splicing semantics -- a form here compiles exactly as compile-expr!
    ;; would compile it standalone, so a (define ...) among `forms` keeps
    ;; whatever meaning it already has at this point (global at the true top
    ;; level). Used for `begin` and the top-level program, neither of which
    ;; introduces a new lexical scope of its own. A body that DOES introduce
    ;; one (lambda/let/let*/letrec/named-let) goes through
    ;; compile-scoped-body! instead, which hoists internal defines first --
    ;; see hoist-internal-defines below.
    (define (compile-body! fc forms dest tail?)
      (if (null? forms)
          (compile-literal-datum! fc '() dest tail?)
          (let loop ((fs forms))
            (if (null? (cdr fs))
                (compile-expr! fc (car fs) dest tail?)
                (let ((mark (fcomp-next-reg fc)))
                  (compile-expr! fc (car fs) (fcomp-alloc-reg! fc) #f)
                  (fcomp-reclaim-to! fc mark)
                  (loop (cdr fs)))))))

    ;; Internal (define ...) forms anywhere in `forms` (not just leading --
    ;; R7RS's own formal grammar wants them first, but this Scheme's own
    ;; reference implementation is deliberately lenient about that too, see
    ;; its README's Known caveats), including ones nested inside a further
    ;; `begin` (flattened first, matching begin's own splicing semantics --
    ;; equivalent to compiling it un-flattened either way when it has no
    ;; defines, so this is always safe to do), are hoisted into a letrec*
    ;; wrapping the rest of the body, giving them genuine local bindings
    ;; instead of silently becoming global defines the instant they're
    ;; nested one level deeper than the top-level program.
    ;;
    ;; `include`/`include-ci` forms are ALSO flattened in here (splicing
    ;; the named file's own top-level forms in place, same as a nested
    ;; `begin`'s own contents) -- this is what gives `include` genuine
    ;; R7RS body-position support (usable inside a `let`/`lambda` body,
    ;; not just at a file's own top level, which cvm/compiler-run.scm's
    ;; separate expand-includes already handled): flatten-begins runs
    ;; for every scope-introducing body (compile-scoped-body!'s own
    ;; hoist-internal-defines call), unlike compile-program's direct
    ;; compile-body! call for the outermost program (which cvm/
    ;; compiler-run.scm's own pre-pass already covers). See
    ;; current-compiling-file/expand-include-form (below dirname/
    ;; path-join/ascii-foldcase-string's own definitions further down
    ;; this file, fine as forward references -- nothing calls either
    ;; until long after the whole library body has finished loading).
    (define (flatten-begins forms)
      (cond
        ((null? forms) '())
        ((and (pair? (car forms)) (eq? (car (car forms)) 'begin))
         (append (flatten-begins (cdr (car forms))) (flatten-begins (cdr forms))))
        ((and (pair? (car forms)) (or (eq? (car (car forms)) 'include) (eq? (car (car forms)) 'include-ci)))
         (append (expand-include-form (car forms)) (flatten-begins (cdr forms))))
        (else (cons (car forms) (flatten-begins (cdr forms))))))

    ;; The file currently being compiled -- set (with save/restore, so a
    ;; NESTED compile-program call, e.g. ensure-library-loaded!'s own
    ;; run-compiled-forms! reentrant while the outer program's own
    ;; compile-program call is still in progress processing an `(import
    ;; ...)` form, doesn't leave the OUTER file's own current-compiling-
    ;; file clobbered once that nested call returns) by compile-program's
    ;; own optional 2nd argument. Defaults to "" (an `include` inside a
    ;; program compiled without ever passing a file path -- e.g. `eval`'s
    ;; one-off single-form compiles -- simply has no directory to resolve
    ;; a relative path against, matching what dirname/path-join already
    ;; do for an empty string).
    (define current-compiling-file "")

    ;; Non-#f only while compiling a SPECIFIC library's own top-level
    ;; body (ensure-library-loaded!, further down) -- a list of symbols
    ;; this library is actually allowed to see as free variables (its own
    ;; top-level defines, union'd with whatever its own `import` clauses
    ;; resolved). #f (the default, for ordinary top-level/REPL/script
    ;; compiles) means "no restriction," matching every behavior this
    ;; compiler had before this pair of variables existed. See compile-
    ;; var-ref!'s own use of these, and ensure-library-loaded!'s save/
    ;; restore around processing one library's clauses, for the full
    ;; mechanism (cvm/README.md's own "environment/eval" section has the
    ;; complete design rationale for why this is a compile-time-only
    ;; masking trick rather than genuine runtime isolation).
    (define current-library-visible-names #f)
    (define current-library-mangle-prefix #f)

    ;; Splices `form` = (include "path" ...) / (include-ci "path" ...)'s
    ;; own named file(s)' top-level forms in, resolved relative to
    ;; current-compiling-file's own directory -- include-ci additionally
    ;; fold-cases the source first (ascii-foldcase-string, the same
    ;; ASCII-only simplification ensure-library-loaded!'s own include-ci
    ;; handling already uses). Recurses through flatten-begins itself (not
    ;; just read-program) so a nested include-of-include is ALSO expanded,
    ;; correctly resolved against ITS OWN file's directory (current-
    ;; compiling-file is updated to the included file's own path for the
    ;; duration of that nested flatten-begins call, then restored).
    (define (expand-include-form form)
      (let ((fold-case? (eq? (car form) 'include-ci))
            (dir (dirname current-compiling-file)))
        (apply append
          (map (lambda (relpath)
                 (let* ((full (path-join dir relpath))
                        (src (file-read full))
                        (saved current-compiling-file))
                   (set! current-compiling-file full)
                   (let ((forms (flatten-begins (read-program (if fold-case? (ascii-foldcase-string src) src)))))
                     (set! current-compiling-file saved)
                     forms)))
               (cdr form)))))

    ;; Only used now to gather the SET of names a body's own top-level
    ;; `define`s introduce (for letrec*'s own pre-declaration bindings,
    ;; see hoist-internal-defines below) -- NOT to separate defines from
    ;; other forms into two reordered lists the way this used to (see
    ;; that function's own doc comment for why reordering was a genuine
    ;; bug). `rest` (non-define forms) is no longer produced or used.
    (define (partition-defines forms)
      (if (null? forms)
          '()
          (if (and (pair? (car forms)) (eq? (car (car forms)) 'define))
              (cons (car forms) (partition-defines (cdr forms)))
              (partition-defines (cdr forms)))))

    (define (define-form-name d)
      (let ((sig (cadr d))) (if (pair? sig) (car sig) sig)))

    (define (define-form-val-expr d)
      (let ((sig (cadr d)))
        (if (pair? sig) (cons 'lambda (cons (cdr sig) (cddr d))) (caddr d))))

    ;; The IN-PLACE replacement for a `define` once its name is already
    ;; letrec*-pre-declared (hoist-internal-defines below): an ordinary
    ;; assignment, evaluated exactly where the original `define` sat in
    ;; the body's own source order -- this is the actual fix for the
    ;; evaluation-order bug that function's own doc comment describes.
    (define (define-form->set!-form d)
      (list 'set! (define-form-name d) (define-form-val-expr d)))

    ;; Internal define-values desugars into a hidden temp holding the
    ;; multi-value result as a list (call-with-values + the `list`
    ;; procedure), followed by one ordinary (define name (list-ref/-tail
    ;; tmp i)) per formal -- reusing the exact plain-define shape
    ;; hoist-internal-defines/define-form->set!-form already knows how to
    ;; fold into a letrec*-preceded set! sequence (whose in-order
    ;; evaluation, see hoist-internal-defines' own doc comment, guarantees
    ;; the temp is assigned before any derived binding reads it). Top-
    ;; level define-values keeps its own existing Destructure-based
    ;; compile-define-values! -- unrelated to this, only used for the
    ;; internal/hoisted case.
    (define (define-values->define-forms expr)
      (let* ((parsed (parse-formals (cadr expr)))
             (fixed (car parsed))
             (rest (cdr parsed))
             (tmp (fresh-symbol! "define-values-tmp-")))
        (cons
          (list 'define tmp (list 'call-with-values (list 'lambda '() (caddr expr)) 'list))
          (append
            (let loop ((names fixed) (i 0))
              (if (null? names)
                  '()
                  (cons (list 'define (car names) (list 'list-ref tmp i))
                        (loop (cdr names) (+ i 1)))))
            (if rest (list (list 'define rest (list 'list-tail tmp (length fixed)))) '())))))

    ;; Expands a define-record-type/define-values form into an equivalent
    ;; (begin (define ...) ...) of plain defines, so hoist-internal-defines
    ;; (which only recognizes plain define) can fold them into the same
    ;; letrec* as any other internal define -- everything else passes
    ;; through unchanged.
    (define (expand-definition-form form)
      (if (pair? form)
          (cond
            ((eq? (car form) 'define-record-type) (cons 'begin (record-type->define-forms form)))
            ((eq? (car form) 'define-values) (cons 'begin (define-values->define-forms form)))
            (else form))
          form))

    ;; Folds a body's own top-level internal defines into a letrec* --
    ;; needed so a define anywhere in the body can be referenced by a
    ;; nested lambda defined EARLIER in the same body (ordinary mutual
    ;; recursion, e.g. even?/odd?), which a plain sequential compile
    ;; (each define landing in whatever register is next, no forward
    ;; visibility) can't give for free.
    ;;
    ;; USED to build this by bucketing forms into two SEPARATE lists --
    ;; defines (become letrec*'s own bindings, evaluated ALL BEFORE the
    ;; body) and rest (become the body, run AFTER every binding) -- which
    ;; silently REORDERED a body that interleaves defines and plain
    ;; expressions: a `define` appearing textually AFTER some expression
    ;; had its own initializer moved to evaluate BEFORE that expression
    ;; instead. Confirmed as a genuine, reproducible bug (cvm/README.md's
    ;; own "Known bugs" section, found while porting (creme actor)):
    ;;   (define worker 42)
    ;;   (register! worker)        ; a plain expression
    ;;   (define found (lookup))   ; define AFTER an expression
    ;;   found
    ;; used to compile as `(letrec* ((worker 42) (found (lookup)))
    ;; (register! worker) found)` -- (lookup)'s call ran as part of the
    ;; letrec*'s OWN bindings, i.e. BEFORE (register! worker) ever ran,
    ;; instead of after it as the source order requires.
    ;;
    ;; Fixed by keeping letrec* ONLY for forward-reference visibility
    ;; (every defined name pre-declared, bound to an unspecified
    ;; placeholder #f) and replacing each `define` IN PLACE, in the
    ;; body's own original order, with an ordinary `set!` to that
    ;; already-declared name -- exactly what a `define` actually does at
    ;; the point it runs, once its name already has a location to assign
    ;; into. Every non-define form is left untouched, so the full
    ;; interleaved sequence -- defines-turned-set!s and plain
    ;; expressions alike -- now evaluates in the exact order the source
    ;; wrote it in, while nested lambdas defined anywhere in the body
    ;; still see every other define's name from the start (as letrec*
    ;; intends), just not yet assigned until its own set! runs.
    (define (hoist-internal-defines forms)
      (let* ((flat (flatten-begins (map expand-definition-form (flatten-begins forms))))
             (defines (partition-defines flat)))
        (if (null? defines)
            forms
            (list (cons 'letrec*
                    (cons (map (lambda (d) (list (define-form-name d) #f)) defines)
                          (map (lambda (form)
                                 (if (and (pair? form) (eq? (car form) 'define))
                                     (define-form->set!-form form)
                                     form))
                               flat)))))))

    ;; Saves/restores macro-table around the body -- same snapshot/restore
    ;; compile-let-syntax! already uses (see its own header comment for
    ;; the accepted simplification this shares), extended here to EVERY
    ;; scope-introducing body, not just let-syntax/letrec-syntax: a plain
    ;; internal defmacro/define-syntax (registered via compile-defmacro!/
    ;; compile-define-syntax!, both unconditional macro-register! calls
    ;; with no scoping of their own) would otherwise leak into macro-table
    ;; permanently, visible even after this body's own lexical scope
    ;; exits -- found by porting spec/scheme/compile/macro_spec.cr's own
    ;; "supports local, nested macro definitions scoped to their let"
    ;; case: a (let () (defmacro m (x) x) (m 5)) followed by a LATER,
    ;; separate (m 5) call should raise unbound-variable, matching
    ;; native's own parent-chained @analyzing_macros (analyzer.cr), which
    ;; pushes/pops a child scope around every body for exactly this
    ;; reason (analyze_defmacro registers into whatever @analyzing_macros
    ;; is current, same as define-syntax).
    (define (compile-scoped-body! fc forms dest tail?)
      (let ((saved macro-table))
        (compile-body! fc (hoist-internal-defines forms) dest tail?)
        (set! macro-table saved)))

    ;; Fused compare-and-branch: when `test-expr` is itself a call to one of
    ;; the 6 comparison/eq? primitives (not shadowed/redefined -- same gate
    ;; fusable-call? uses), emits ONE TestLt/.../TestIsEq(-Imm/-Up)
    ;; instruction that both compares and conditionally jumps (a=src1,
    ;; b=offset, c=src2/literal/upvalue-idx -- offset left 0 here, patched
    ;; later via chunk-patch-jump-to-here! exactly like TestFalse's own
    ;; handle), returning that instruction as the caller's jmp-false handle.
    ;; Returns #f (no fusion) for anything else, so the caller falls back to
    ;; compiling the test into a register and emitting a plain TestFalse --
    ;; that fallback still benefits from ordinary value-producing primitive
    ;; fusion (e.g. `(if (+ a b) ...)` still fuses Add, just isn't ALSO
    ;; folded into the branch itself, since there's no TestAdd). Only used
    ;; by compile-if! (which when/unless already desugar into) -- and/or/
    ;; cond/case/guard clauses must keep the test's own VALUE (bodyless/=>
    ;; clauses, or's return-the-truthy-operand semantics), so they can never
    ;; use a fused op that only knows truthy/falsy.
    (define (compile-fused-test! fc test-expr)
      (and (pair? test-expr)
           (symbol? (car test-expr))
           (not (fcomp-lookup-local fc (car test-expr)))
           (not (fcomp-resolve-upvalue! fc (car test-expr)))
           (not (memq (car test-expr) redefined-fusable-globals))
           (= (length (cdr test-expr)) 2)
           (let ((entry (fused-prim-lookup (car test-expr) 2)))
             (and entry
                  (memq (fp-op entry) '(NumLt NumLe NumGt NumGe NumEq IsEq))
                  (let* ((ch (fcomp-chunk fc))
                         (op (fp-op entry))
                         (arg1 (cadr test-expr))
                         (arg2 (caddr test-expr))
                         (imm-op (op-table-lookup 'test-imm op))
                         (imm-val (and imm-op (imm-literal-int arg2)))
                         (up-op (and (not imm-val) (op-table-lookup 'test-up op)))
                         (up-idx (and up-op (leaf-expr? fc arg1) (upvalue-operand fc arg2)))
                         (mark (fcomp-next-reg fc))
                         (result
                           (cond
                             (imm-val
                              (let ((r1 (compile-arg! fc arg1 #t)))
                                (chunk-emit! ch imm-op r1 0 imm-val 0)))
                             (up-idx
                              (let ((r1 (compile-arg! fc arg1 #t)))
                                (chunk-emit! ch up-op r1 0 up-idx 0)))
                             (else
                              (let* ((r1 (compile-arg! fc arg1 (leaf-expr? fc arg2)))
                                     (r2 (compile-arg! fc arg2 #t)))
                                (chunk-emit! ch (op-table-lookup 'test-base op) r1 0 r2 0))))))
                    (fcomp-reclaim-to! fc mark)
                    result)))))

    ;; Both then/else are always compiled uniformly here -- an absent else
    ;; clause is represented as the literal expression `(quote ())`, which
    ;; compile-expr! already compiles identically to what the old explicit
    ;; compile-literal-datum! special-case did (compile-form!'s own `quote`
    ;; dispatch goes straight to compile-literal-datum!), so no special
    ;; casing is needed here for it.
    (define (compile-if-branches! fc test-expr then-expr else-expr dest tail?)
      (let* ((ch (fcomp-chunk fc))
             (jmp-false (or (compile-fused-test! fc test-expr)
                            (let ((mark (fcomp-next-reg fc))
                                  (test-reg (fcomp-alloc-reg! fc)))
                              (compile-expr! fc test-expr test-reg #f)
                              (let ((instr (chunk-emit! ch 'TestFalse test-reg 0 0 0)))
                                (fcomp-reclaim-to! fc mark)
                                instr)))))
        (compile-expr! fc then-expr dest tail?)
        (if tail?
            (begin
              (chunk-patch-jump-to-here! ch jmp-false)
              (compile-expr! fc else-expr dest #t))
            (let ((jmp-end (chunk-emit! ch 'Jmp 0 0 0 0)))
              (chunk-patch-jump-to-here! ch jmp-false)
              (compile-expr! fc else-expr dest #f)
              (chunk-patch-jump-to-here! ch jmp-end)))))

    ;; A leading (not X) test is peeled here -- (if (not X) T E) means
    ;; "if X is false, T; else E", i.e. exactly (if X E T) with X as the
    ;; direct (now fusable) test -- so peeling swaps then/else rather than
    ;; needing any different jump polarity from compile-fused-test!/
    ;; TestFalse (both always mean "jump when the given test is false").
    ;; unless already desugars to exactly this single-argument (not ...)
    ;; shape, so this transparently speeds up any unless whose condition is
    ;; a comparison too.
    (define (compile-if! fc expr dest tail?)
      (let* ((raw-test (cadr expr))
             (raw-then (caddr expr))
             (raw-else (if (pair? (cdddr expr)) (cadddr expr) (list 'quote '()))))
        (if (and (pair? raw-test) (eq? (car raw-test) 'not) (pair? (cdr raw-test)) (null? (cddr raw-test)))
            (compile-if-branches! fc (cadr raw-test) raw-else raw-then dest tail?)
            (compile-if-branches! fc raw-test raw-then raw-else dest tail?))))

    ;; when/unless -- same single-branch structure and TestFalse jump
    ;; polarity as compile-if-branches!, but the present branch is a BODY
    ;; (a list of forms, scoped/hoisted via compile-scoped-body! so an
    ;; internal (define ...) works here exactly as it does in a lambda/let
    ;; body -- matching bytecode_compiler.cr's uniform compile_seq_tail
    ;; use for WhenNode), not a single expr the way compile-if-branches!
    ;; assumes. `then-forms`/`else-forms` is #f for the absent branch
    ;; (compiles to the same literal '() compile-if-branches! uses).
    (define (compile-if-body-branches! fc test-expr then-forms else-forms dest tail?)
      (let* ((ch (fcomp-chunk fc))
             (jmp-false (or (compile-fused-test! fc test-expr)
                            (let ((mark (fcomp-next-reg fc))
                                  (test-reg (fcomp-alloc-reg! fc)))
                              (compile-expr! fc test-expr test-reg #f)
                              (let ((instr (chunk-emit! ch 'TestFalse test-reg 0 0 0)))
                                (fcomp-reclaim-to! fc mark)
                                instr)))))
        (if then-forms (compile-scoped-body! fc then-forms dest tail?) (compile-literal-datum! fc '() dest tail?))
        (if tail?
            (begin
              (chunk-patch-jump-to-here! ch jmp-false)
              (if else-forms (compile-scoped-body! fc else-forms dest #t) (compile-literal-datum! fc '() dest #t)))
            (let ((jmp-end (chunk-emit! ch 'Jmp 0 0 0 0)))
              (chunk-patch-jump-to-here! ch jmp-false)
              (if else-forms (compile-scoped-body! fc else-forms dest #f) (compile-literal-datum! fc '() dest #f))
              (chunk-patch-jump-to-here! ch jmp-end)))))

    (define (compile-when! fc test-expr body dest tail?)
      (compile-if-body-branches! fc test-expr body #f dest tail?))

    (define (compile-unless! fc test-expr body dest tail?)
      (compile-if-body-branches! fc test-expr #f body dest tail?))

    (define (compile-and! fc exprs dest tail?)
      (cond
        ((null? exprs) (compile-literal-datum! fc #t dest tail?))
        ((null? (cdr exprs)) (compile-expr! fc (car exprs) dest tail?))
        (else
         (let ((ch (fcomp-chunk fc))
               (mark (fcomp-next-reg fc)))
           (compile-expr! fc (car exprs) dest #f)
           (fcomp-reclaim-to! fc mark)
           (let ((jmp-false (chunk-emit! ch 'TestFalse dest 0 0 0)))
             (compile-and! fc (cdr exprs) dest tail?)
             (chunk-patch-jump-to-here! ch jmp-false)
             (if tail? (chunk-emit! ch 'Return dest 0 0 0)))))))

    (define (compile-or! fc exprs dest tail?)
      (cond
        ((null? exprs) (compile-literal-datum! fc #f dest tail?))
        ((null? (cdr exprs)) (compile-expr! fc (car exprs) dest tail?))
        (else
         (let ((ch (fcomp-chunk fc))
               (mark (fcomp-next-reg fc)))
           (compile-expr! fc (car exprs) dest #f)
           (fcomp-reclaim-to! fc mark)
           (let ((jmp-false (chunk-emit! ch 'TestFalse dest 0 0 0)))
             (let ((jmp-true-end (if tail? (begin (chunk-emit! ch 'Return dest 0 0 0) #f) (chunk-emit! ch 'Jmp 0 0 0 0))))
               (chunk-patch-jump-to-here! ch jmp-false)
               (compile-or! fc (cdr exprs) dest tail?)
               (if (not tail?) (chunk-patch-jump-to-here! ch jmp-true-end))))))))

    (define (compile-arrow-call! fc proc-expr arg-reg dest tail?)
      (let* ((ch (fcomp-chunk fc))
             (fn-reg (fcomp-alloc-reg! fc))
             (call-arg-reg (fcomp-alloc-reg! fc)))
        (compile-expr! fc proc-expr fn-reg #f)
        (chunk-emit! ch 'Move call-arg-reg arg-reg 0 0)
        (if tail?
            (chunk-emit! ch 'TailCall fn-reg 1 0 0)
            (chunk-emit! ch 'Call fn-reg 1 dest 0))))

    ;; (set! name val) -- writes into the variable's own home register
    ;; (local), the upvalue cell (SetUpval), or the global binding
    ;; (SetGlobal), whichever resolves. Unspecified value, same convention as
    ;; define: nothing reads a non-tail set!'s dest. A global set! can
    ;; rebind a fusable primitive's name exactly like a top-level define
    ;; can, so it's tracked the same way (mark-redefined! is defined further
    ;; down, alongside the fusion machinery it protects).
    (define (compile-set! fc expr dest tail?)
      (let* ((name (cadr expr))
             (val-expr (caddr expr))
             (ch (fcomp-chunk fc))
             (val-reg (fcomp-alloc-reg! fc)))
        (compile-expr! fc val-expr val-reg #f)
        (let ((local (fcomp-lookup-local fc name)))
          (cond
            (local (chunk-emit! ch 'Move local val-reg 0 0))
            (else
             (let ((up (fcomp-resolve-upvalue! fc name)))
               (if up
                   (chunk-emit! ch 'SetUpval up val-reg 0 0)
                   (begin
                     (chunk-emit! ch 'SetGlobal (chunk-add-const! ch name) val-reg 0 0)
                     (mark-redefined! name)))))))
        (if tail? (chunk-emit! ch 'Return val-reg 0 0 0))))

    ;; A plain incrementing counter, not gensym/hygiene -- good enough for
    ;; names this compiler itself introduces (case's dispatch key, do's loop
    ;; name) that real source is exceedingly unlikely to also spell out.
    (define fresh-symbol-counter 0)
    (define (fresh-symbol! prefix)
      (set! fresh-symbol-counter (+ fresh-symbol-counter 1))
      (string->symbol (string-append prefix (number->string fresh-symbol-counter))))

    ;; case -- each non-else clause emits Op::CaseMatch (key eqv? against a
    ;; vector of the clause's own datums, same op + same const shape
    ;; bytecode_compiler.cr's own compile_case_clauses emits) + TestFalse,
    ;; the same jump shape as an ordinary cond clause; the else clause (if
    ;; present) is unconditional at the end; a => clause (on an ordinary
    ;; clause OR the else clause -- R7RS allows both, and native's own
    ;; compile_case_result handles the arrow uniformly regardless of
    ;; clause.els?) calls its proc on the KEY's own value (key-reg), per
    ;; R7RS, exactly like compile-cond!'s own => handling calls it on the
    ;; test's value.
    ;;
    ;; Only the LINEAR path -- Crystal's own >=8-hashable-datum
    ;; Op::CaseDispatch hash-table fast path (compile_case_hash_dispatch)
    ;; needs a CaseDispatchTable structure this chunk format has no
    ;; constructor for yet (chunk-add-case-dispatch-table!/case-dispatch-
    ;; tables, which would need wiring through (creme bytecode)'s own
    ;; chunk record AND chunk_serializer.cr/chunk_deserializer.cr/cvm's
    ;; SCB1 (de)serialization, not just this compiler) -- a real,
    ;; deliberately out-of-scope-for-now gap. Behavior is identical either
    ;; way: CaseDispatch is a pure O(1)-vs-O(n) perf optimization over
    ;; CaseMatch (see hashable_case?'s own gating), and this compiler's
    ;; always-CaseMatch path is exactly what Crystal itself also falls
    ;; back to below the 8-datum threshold.
    (define (compile-case-clauses! fc key-reg clauses dest tail?)
      (if (null? clauses)
          (compile-literal-datum! fc '() dest tail?)
          (let* ((clause (car clauses))
                 (test (car clause))
                 (body (cdr clause))
                 (ch (fcomp-chunk fc)))
            (if (eq? test 'else)
                (if (and (pair? body) (eq? (car body) '=>))
                    (compile-arrow-call! fc (cadr body) key-reg dest tail?)
                    (compile-scoped-body! fc body dest tail?))
                (let* ((mark (fcomp-next-reg fc))
                       (match-reg (fcomp-alloc-reg! fc))
                       (datums-const (chunk-add-const! ch (list->vector test))))
                  (chunk-emit! ch 'CaseMatch match-reg key-reg datums-const 0)
                  (let ((jmp-false (chunk-emit! ch 'TestFalse match-reg 0 0 0)))
                    (fcomp-reclaim-to! fc mark)
                    (if (and (pair? body) (eq? (car body) '=>))
                        (compile-arrow-call! fc (cadr body) key-reg dest tail?)
                        (compile-scoped-body! fc body dest tail?))
                    (if tail?
                        (begin
                          (chunk-patch-jump-to-here! ch jmp-false)
                          (compile-case-clauses! fc key-reg (cdr clauses) dest #t))
                        (let ((jmp-end (chunk-emit! ch 'Jmp 0 0 0 0)))
                          (chunk-patch-jump-to-here! ch jmp-false)
                          (compile-case-clauses! fc key-reg (cdr clauses) dest #f)
                          (chunk-patch-jump-to-here! ch jmp-end)))))))))

    (define (compile-case! fc expr dest tail?)
      (let* ((key-expr (cadr expr))
             (clauses (cddr expr))
             (key-reg (fcomp-alloc-reg! fc)))
        (compile-expr! fc key-expr key-reg #f)
        (compile-case-clauses! fc key-reg clauses dest tail?)))

    ;; do -- the standard named-let desugaring: (var init step) bindings
    ;; become the loop's params/initial args, step defaults to the var
    ;; itself when omitted, and the loop body is `commands... (loop
    ;; next-steps...)` guarded by the test.
    (define (do-binding-var b) (car b))
    (define (do-binding-init b) (cadr b))
    (define (do-binding-step b) (if (pair? (cddr b)) (caddr b) (car b)))

    (define (compile-do! fc expr dest tail?)
      (let* ((bindings (cadr expr))
             (test-clause (caddr expr))
             (test-expr (car test-clause))
             (result-exprs (cdr test-clause))
             (commands (cdddr expr))
             (loop-sym (fresh-symbol! "do-loop-"))
             (vars (map do-binding-var bindings))
             (inits (map do-binding-init bindings))
             (steps (map do-binding-step bindings))
             (loop-call (cons loop-sym steps))
             (then-expr (cons 'begin (if (null? result-exprs) (list (list 'quote '())) result-exprs)))
             (else-expr (cons 'begin (append commands (list loop-call)))))
        (compile-expr! fc
          (list 'let loop-sym (map list vars inits) (list 'if test-expr then-expr else-expr))
          dest tail?)))

    ;; quasiquote -- expanded entirely at COMPILE TIME into ordinary cons/
    ;; append/list->vector calls (classic technique), so it needs no runtime
    ;; support of its own (no Quasiquote op, no qq_templates).
    ;;
    ;; Deliberately NOT using Crystal's own Op::Quasiquote fast path
    ;; (bytecode_compiler.cr's compile_quasiquote): its own doc comment
    ;; says its QQTemplate tree is "never serialized into the const pool
    ;; since only VM#build_qq's Crystal code ever reads it" -- i.e. it's a
    ;; same-process-only optimization with NO SCB1 wire representation at
    ;; all. A chunk built by THIS compiler exists specifically to be
    ;; serialized and reloaded standalone (load-chunk-bytes/cvm), so
    ;; emitting Op::Quasiquote here wouldn't just need extra format work
    ;; (unlike Op::CaseDispatch's missing-but-addable table) -- it would
    ;; produce chunks that never round-trip correctly at all, a real
    ;; regression rather than a missed optimization. The cons/append
    ;; desugaring below has no such limitation.
    ;;
    ;; `depth` tracks nested quasiquote levels: an inner (quasiquote X)
    ;; increments it (X is still just literal DATA being reconstructed, one
    ;; level further removed from evaluation); an (unquote X) or
    ;; (unquote-splicing X) decrements it -- only at depth 1 does an unquote
    ;; actually evaluate its operand for real; at any deeper depth it stays
    ;; literal structure (rebuilt via `list`), just with ITS OWN contents
    ;; still recursively processed at the decremented depth, since a
    ;; sufficiently-nested unquote can still "reach back up" to depth 1
    ;; inside a doubly/triply-nested quasiquote.
    (define (qq-expand-top template) (qq-expand template 1))

    ;; cond-expand -- picks the first clause whose feature requirement is
    ;; satisfied (else always matches), compiling only ITS body; the other
    ;; clauses are never even looked at by compile-expr!, exactly like the
    ;; #ifdef-style compile-time conditional this is meant to be. Only a
    ;; small, honestly-hardcoded feature identifier set is recognized
    ;; (this compiler has no live library REGISTRY the way the real
    ;; analyzer does) -- but (library ...) requirements are genuinely
    ;; checked (feature-satisfied?'s own 'library case, below), not just
    ;; guessed at or always rejected.
    (define cond-expand-known-features (list 'else 'r7rs 'creme 'creme.cr))

    (define (feature-satisfied? req)
      (cond
        ((symbol? req) (and (memq req cond-expand-known-features) #t))
        ((eq? (car req) 'and) (sr-all? feature-satisfied? (cdr req)))
        ((eq? (car req) 'or) (sr-any? feature-satisfied? (cdr req)))
        ((eq? (car req) 'not) (not (feature-satisfied? (cadr req))))
        ;; (library (name ...)) -- USED to be unconditionally #f (this
        ;; compiler has no live library registry to query, unlike
        ;; native's own real Interpreter). library-export-alist
        ;; (defined further below in this same file, fine as a forward
        ;; reference -- nothing calls feature-satisfied? before the
        ;; whole body finishes loading) already answers exactly this
        ;; question for any OTHER purpose (resolving what a library
        ;; exports) via the same file-then-native-fallback check
        ;; ensure-library-loaded!/import-set-resolved-bindings rely on,
        ;; so reusing it here needs no new logic at all: a library
        ;; genuinely exists (real .sld file, or a native family
        ;; introspection recognizes) exactly when it has a non-#f
        ;; export alist.
        ((eq? (car req) 'library) (and (library-export-alist (cadr req)) #t))
        (else #f)))

    (define (sr-all? pred lst) (or (null? lst) (and (pred (car lst)) (sr-all? pred (cdr lst)))))
    (define (sr-any? pred lst) (and (pair? lst) (or (pred (car lst)) (sr-any? pred (cdr lst)))))

    (define (compile-cond-expand! fc clauses dest tail?)
      (if (null? clauses)
          (compile-literal-datum! fc '() dest tail?)
          (if (feature-satisfied? (car (car clauses)))
              (compile-body! fc (cdr (car clauses)) dest tail?)
              (compile-cond-expand! fc (cdr clauses) dest tail?))))

    (define (qq-expand template depth)
      (cond
        ((vector? template) (list 'list->vector (qq-expand (vector->list template) depth)))
        ((not (pair? template)) (list 'quote template))
        ((eq? (car template) 'quasiquote)
         (list 'list (list 'quote 'quasiquote) (qq-expand (cadr template) (+ depth 1))))
        ((eq? (car template) 'unquote)
         (if (= depth 1)
             (cadr template)
             (list 'list (list 'quote 'unquote) (qq-expand (cadr template) (- depth 1)))))
        ((and (pair? (car template)) (eq? (car (car template)) 'unquote-splicing))
         (if (= depth 1)
             (list 'append (cadr (car template)) (qq-expand (cdr template) depth))
             (list 'cons
                   (list 'list (list 'quote 'unquote-splicing) (qq-expand (cadr (car template)) (- depth 1)))
                   (qq-expand (cdr template) depth))))
        (else (list 'cons (qq-expand (car template) depth) (qq-expand (cdr template) depth)))))

    (define (compile-cond! fc clauses dest tail?)
      (if (null? clauses)
          (compile-literal-datum! fc '() dest tail?)
          (let* ((clause (car clauses))
                 (test (car clause))
                 (body (cdr clause))
                 (ch (fcomp-chunk fc)))
            (cond
              ((eq? test 'else) (compile-scoped-body! fc body dest tail?))
              ((null? body)
               (let ((mark (fcomp-next-reg fc)))
                 (compile-expr! fc test dest #f)
                 (fcomp-reclaim-to! fc mark))
               (let ((jmp-false (chunk-emit! ch 'TestFalse dest 0 0 0)))
                 (if tail?
                     (begin
                       (chunk-emit! ch 'Return dest 0 0 0)
                       (chunk-patch-jump-to-here! ch jmp-false)
                       (compile-cond! fc (cdr clauses) dest #t))
                     (let ((jmp-end (chunk-emit! ch 'Jmp 0 0 0 0)))
                       (chunk-patch-jump-to-here! ch jmp-false)
                       (compile-cond! fc (cdr clauses) dest #f)
                       (chunk-patch-jump-to-here! ch jmp-end)))))
              ((eq? (car body) '=>)
               (let* ((mark (fcomp-next-reg fc))
                      (test-reg (fcomp-alloc-reg! fc)))
                 (compile-expr! fc test test-reg #f)
                 (let ((jmp-false (chunk-emit! ch 'TestFalse test-reg 0 0 0)))
                   (compile-arrow-call! fc (cadr body) test-reg dest tail?)
                   (fcomp-reclaim-to! fc mark)
                   (if tail?
                       (begin
                         (chunk-patch-jump-to-here! ch jmp-false)
                         (compile-cond! fc (cdr clauses) dest #t))
                       (let ((jmp-end (chunk-emit! ch 'Jmp 0 0 0 0)))
                         (chunk-patch-jump-to-here! ch jmp-false)
                         (compile-cond! fc (cdr clauses) dest #f)
                         (chunk-patch-jump-to-here! ch jmp-end))))))
              (else
               (let ((mark (fcomp-next-reg fc)))
                 (compile-expr! fc test dest #f)
                 (fcomp-reclaim-to! fc mark))
               (let ((jmp-false (chunk-emit! ch 'TestFalse dest 0 0 0)))
                 (compile-scoped-body! fc body dest tail?)
                 (if tail?
                     (begin
                       (chunk-patch-jump-to-here! ch jmp-false)
                       (compile-cond! fc (cdr clauses) dest #t))
                     (let ((jmp-end (chunk-emit! ch 'Jmp 0 0 0 0)))
                       (chunk-patch-jump-to-here! ch jmp-false)
                       (compile-cond! fc (cdr clauses) dest #f)
                       (chunk-patch-jump-to-here! ch jmp-end)))))))))

    ;; (guard (var clause...) body...). Same clause shapes as cond (else/
    ;; bodyless/=>/plain), except no-match RE-RAISES (GuardReraise) instead
    ;; of yielding nil -- an unmatched condition must propagate to an outer
    ;; handler, not silently vanish. Mirrors bytecode_compiler.cr's own
    ;; compile_guard_clauses (same reasoning, same op sequence).
    (define (compile-guard-clauses! fc clauses dest tail?)
      (if (null? clauses)
          (chunk-emit! (fcomp-chunk fc) 'GuardReraise 0 0 0 0)
          (let* ((clause (car clauses))
                 (test (car clause))
                 (body (cdr clause))
                 (ch (fcomp-chunk fc)))
            (cond
              ((eq? test 'else) (compile-scoped-body! fc body dest tail?))
              ((null? body)
               (let ((mark (fcomp-next-reg fc)))
                 (compile-expr! fc test dest #f)
                 (fcomp-reclaim-to! fc mark))
               (let ((jmp-false (chunk-emit! ch 'TestFalse dest 0 0 0)))
                 (if tail?
                     (begin
                       (chunk-emit! ch 'Return dest 0 0 0)
                       (chunk-patch-jump-to-here! ch jmp-false)
                       (compile-guard-clauses! fc (cdr clauses) dest #t))
                     (let ((jmp-end (chunk-emit! ch 'Jmp 0 0 0 0)))
                       (chunk-patch-jump-to-here! ch jmp-false)
                       (compile-guard-clauses! fc (cdr clauses) dest #f)
                       (chunk-patch-jump-to-here! ch jmp-end)))))
              ((eq? (car body) '=>)
               (let* ((mark (fcomp-next-reg fc))
                      (test-reg (fcomp-alloc-reg! fc)))
                 (compile-expr! fc test test-reg #f)
                 (let ((jmp-false (chunk-emit! ch 'TestFalse test-reg 0 0 0)))
                   (compile-arrow-call! fc (cadr body) test-reg dest tail?)
                   (fcomp-reclaim-to! fc mark)
                   (if tail?
                       (begin
                         (chunk-patch-jump-to-here! ch jmp-false)
                         (compile-guard-clauses! fc (cdr clauses) dest #t))
                       (let ((jmp-end (chunk-emit! ch 'Jmp 0 0 0 0)))
                         (chunk-patch-jump-to-here! ch jmp-false)
                         (compile-guard-clauses! fc (cdr clauses) dest #f)
                         (chunk-patch-jump-to-here! ch jmp-end))))))
              (else
               (let ((mark (fcomp-next-reg fc)))
                 (compile-expr! fc test dest #f)
                 (fcomp-reclaim-to! fc mark))
               (let ((jmp-false (chunk-emit! ch 'TestFalse dest 0 0 0)))
                 (compile-scoped-body! fc body dest tail?)
                 (if tail?
                     (begin
                       (chunk-patch-jump-to-here! ch jmp-false)
                       (compile-guard-clauses! fc (cdr clauses) dest #t))
                     (let ((jmp-end (chunk-emit! ch 'Jmp 0 0 0 0)))
                       (chunk-patch-jump-to-here! ch jmp-false)
                       (compile-guard-clauses! fc (cdr clauses) dest #f)
                       (chunk-patch-jump-to-here! ch jmp-end)))))))))

    ;; guard's protected body always compiles NON-tail (a TailCall inside it
    ;; would repoint this frame's chunk/ip while the handler installed by
    ;; PushHandler is still meant to be guarding it -- see PushHandler's own
    ;; doc comment in opcode.cr); clauses run only once the handler that
    ;; protected the body has already been popped, so THEY can tail-call/
    ;; return normally if the whole guard form itself is in tail position.
    (define (compile-guard! fc expr dest tail?)
      (let* ((spec (cadr expr))
             (var (car spec))
             (clauses (cdr spec))
             (body (cddr expr))
             (ch (fcomp-chunk fc))
             (condition-reg (fcomp-alloc-reg! fc)))
        (let ((push-handler-instr (chunk-emit! ch 'PushHandler condition-reg 0 0 0)))
          (compile-scoped-body! fc body dest #f)
          (chunk-emit! ch 'PopHandler 0 0 0 0)
          (let ((jmp-over-clauses (chunk-emit! ch 'Jmp 0 0 0 0)))
            (chunk-patch-jump-to-here! ch push-handler-instr)
            (fcomp-push-scope! fc)
            (fcomp-declare-local! fc var condition-reg)
            (compile-guard-clauses! fc clauses dest tail?)
            (fcomp-pop-scope! fc)
            (chunk-patch-jump-to-here! ch jmp-over-clauses)
            (if tail? (chunk-emit! ch 'Return dest 0 0 0))))))

    ;; (parameterize ((param val) ...) body...). Same non-tail-body reasoning
    ;; as guard: ParamPop must genuinely run afterward to restore the saved
    ;; values, which a TailCall inside body would skip by repointing this
    ;; frame at somewhere else entirely. ParamPush needs params and their new
    ;; values in TWO separate contiguous register runs (not interleaved) --
    ;; params allocated and compiled fully, then vals.
    (define (compile-parameterize! fc expr dest tail?)
      (let* ((bindings (cadr expr))
             (body (cddr expr))
             (params (map car bindings))
             (vals (map cadr bindings))
             (count (length bindings))
             (ch (fcomp-chunk fc))
             (mark (fcomp-next-reg fc))
             (param-regs (map (lambda (p) (fcomp-alloc-reg! fc)) params)))
        (for-each (lambda (p r) (compile-expr! fc p r #f)) params param-regs)
        (let ((val-regs (map (lambda (v) (fcomp-alloc-reg! fc)) vals)))
          (for-each (lambda (v r) (compile-expr! fc v r #f)) vals val-regs)
          (chunk-emit! ch 'ParamPush (car param-regs) (car val-regs) count 0)
          (fcomp-reclaim-to! fc mark)
          (compile-scoped-body! fc body dest #f)
          (chunk-emit! ch 'ParamPop 0 0 0 0)
          (if tail? (chunk-emit! ch 'Return dest 0 0 0)))))

    (define (compile-lambda! fc formals body-forms dest tail? proc-name)
      (let* ((parsed (parse-formals formals))
             (fixed (car parsed))
             (rest (cdr parsed))
             (child-chunk (make-chunk proc-name))
             (child-fc (make-fcomp child-chunk fc)))
        (for-each (lambda (p) (fcomp-declare-local! child-fc p (fcomp-alloc-reg! child-fc))) fixed)
        (chunk-param-count-set! child-chunk (length fixed))
        (if rest
            (begin
              (fcomp-declare-local! child-fc rest (fcomp-alloc-reg! child-fc))
              (chunk-has-rest-set! child-chunk #t)))
        ;; A plain self-recursive (define (f params...) body) gets the same
        ;; counted-loop fusion a let-loop/do already would (see
        ;; try-compile-global-counted-loop!'s own doc comment) -- tried
        ;; first, falling back unconditionally to the ordinary
        ;; compile-scoped-body! path the moment it declines. Never even
        ;; attempted for a rest-arg lambda -- the recognizer's arity-based
        ;; self-call matching doesn't account for one.
        (or (and (not rest) (try-compile-global-counted-loop! child-fc (string->symbol proc-name) fixed body-forms))
            (compile-scoped-body! child-fc body-forms (fcomp-alloc-reg! child-fc) #t))
        (let ((proto-idx (chunk-add-proto! (fcomp-chunk fc) child-chunk)))
          (chunk-emit! (fcomp-chunk fc) 'Closure dest proto-idx 0 0)
          (finish-tail! fc dest tail?))))

    ;; (delay expr) / (delay-force expr) -- both back onto the same
    ;; MakePromise op (wraps a 0-arg thunk in a SchemePromise); the
    ;; difference between them is entirely `force`'s own job at force-time
    ;; (delay-force's thunk may itself return another promise, which force
    ;; iterates on) -- force is an ordinary global procedure already, no
    ;; compiler support needed for it.
    (define (compile-delay! fc expr dest tail?)
      (let* ((ch (fcomp-chunk fc))
             (thunk-reg (fcomp-alloc-reg! fc)))
        (compile-lambda! fc '() (cdr expr) thunk-reg #f "promise-thunk")
        (chunk-emit! ch 'MakePromise dest thunk-reg 0 0)
        (finish-tail! fc dest tail?)))

    ;; (case-lambda (formals1 body1...) (formals2 body2...) ...) -- each
    ;; clause compiles as an ordinary lambda (its own Closure instruction)
    ;; into a contiguous register run, reserved up front the same way
    ;; compile-app!'s call args are, then MakeCaseClosure bundles that whole
    ;; run into one dispatch-by-arity closure value.
    (define (compile-case-lambda! fc clauses dest tail?)
      (let* ((mark (fcomp-next-reg fc))
             (clause-regs (map (lambda (c) (fcomp-alloc-reg! fc)) clauses)))
        (for-each
          (lambda (clause r) (compile-lambda! fc (car clause) (cdr clause) r #f "case-lambda-clause"))
          clauses clause-regs)
        (chunk-emit! (fcomp-chunk fc) 'MakeCaseClosure dest (car clause-regs) (length clauses) 0)
        (fcomp-reclaim-to! fc mark)
        (finish-tail! fc dest tail?)))

    ;; ---------------------------------------------------------------------
    ;; Primitive call fusion -- mirrors the real Crystal analyzer's PRIM_OPS
    ;; table (src/creme/compile/ast.cr) and its analyze_app fusion gate
    ;; (analyzer.cr), just decided here at compile time instead of a
    ;; separate analyze pass (this compiler has none): a call whose head is
    ;; a bare symbol, not locally/upvalue-shadowed, naming a known
    ;; primitive at the exact arity it expects, compiles directly to the
    ;; fused opcode instead of GetGlobal+Call. Table entries are (name
    ;; arity op return-op extra): `return-op` is the *Return-fused variant
    ;; to use in tail position (see opcode.cr), #f when none exists;
    ;; `extra` is CmpZero's test selector (0 zero?/1 positive?/2 negative?),
    ;; 0 for every other op. car/cdr/caar/.../cddddr aren't listed here --
    ;; recognized by name pattern (cxr-name?) like the real analyzer does.
    ;; ---------------------------------------------------------------------

    (define fused-prim-table
      (list
        (list '+ 2 'Add 'AddReturn 0)
        (list '- 2 'Sub 'SubReturn 0)
        (list '* 2 'Mul 'MulReturn 0)
        (list '< 2 'NumLt 'NumLtReturn 0)
        (list '<= 2 'NumLe 'NumLeReturn 0)
        (list '> 2 'NumGt 'NumGtReturn 0)
        (list '>= 2 'NumGe 'NumGeReturn 0)
        (list '= 2 'NumEq 'NumEqReturn 0)
        (list 'eq? 2 'IsEq 'IsEqReturn 0)
        (list 'cons 2 'Cons #f 0)
        (list 'vector-ref 2 'VecRef #f 0)
        (list 'string-ref 2 'StrRef #f 0)
        (list 'bytevector-u8-ref 2 'BvRef #f 0)
        (list 'not 1 'Not #f 0)
        (list 'null? 1 'IsNull #f 0)
        (list 'pair? 1 'IsPair #f 0)
        (list 'abs 1 'Abs #f 0)
        (list 'vector-length 1 'VecLen #f 0)
        (list 'zero? 1 'CmpZero #f 0)
        (list 'positive? 1 'CmpZero #f 1)
        (list 'negative? 1 'CmpZero #f 2)
        (list 'vector-set! 3 'VecSet #f 0)
        (list 'string-set! 3 'StrSet #f 0)
        (list 'bytevector-u8-set! 3 'BvSet #f 0)))

    (define (fp-name e) (car e))
    (define (fp-arity e) (cadr e))
    (define (fp-op e) (caddr e))
    (define (fp-return-op e) (cadddr e))
    (define (fp-extra e) (car (cddddr e)))

    (define (fused-prim-lookup name arity)
      (let loop ((entries fused-prim-table))
        (cond
          ((null? entries) #f)
          ((and (eq? (fp-name (car entries)) name) (= (fp-arity (car entries)) arity)) (car entries))
          (else (loop (cdr entries))))))

    ;; ---------------------------------------------------------------------
    ;; *Imm/*Up operand specializations -- mirror bytecode_compiler.cr's
    ;; imm_operand?/up_operand? gates (verified directly against opcode.cr's
    ;; comments and vm.cr's own exec code, not transcribed from memory):
    ;; none of these ever read a `d` operand (arithmetic/comparison/eq? Imm
    ;; and Up variants fold their overflow/tower fallback into a direct
    ;; num_add/num_sub/etc. call, no deopt-to-builtin needed; Vec/Str/Bv
    ;; Imm/Up variants likewise never touch `d` -- confirmed against
    ;; vm.cr:936-1233), EXCEPT VecSetUp/StrSetUp/BvSetUp, whose unusual
    ;; shape (a=upvalue-idx, b=index-reg, c=value-reg, d=dst) writes the
    ;; mutated object straight into `d` -- no trailing Move needed there,
    ;; unlike the base/Imm mutators.
    ;; ---------------------------------------------------------------------

    (define op-table
      (list
        (cons 'imm2 (list (cons 'Add 'AddImm) (cons 'Sub 'SubImm) (cons 'Mul 'MulImm)
                          (cons 'NumLt 'NumLtImm) (cons 'NumLe 'NumLeImm) (cons 'NumGt 'NumGtImm)
                          (cons 'NumGe 'NumGeImm) (cons 'NumEq 'NumEqImm) (cons 'IsEq 'IsEqImm)
                          (cons 'VecRef 'VecRefImm) (cons 'StrRef 'StrRefImm) (cons 'BvRef 'BvRefImm)
                          (cons 'VecSet 'VecSetImm) (cons 'StrSet 'StrSetImm) (cons 'BvSet 'BvSetImm)))
        (cons 'up2 (list (cons 'Add 'AddUp) (cons 'Sub 'SubUp) (cons 'Mul 'MulUp)
                         (cons 'NumLt 'NumLtUp) (cons 'NumLe 'NumLeUp) (cons 'NumGt 'NumGtUp)
                         (cons 'NumGe 'NumGeUp) (cons 'NumEq 'NumEqUp) (cons 'IsEq 'IsEqUp)))
        (cons 'up1 (list (cons 'VecRef 'VecRefUp) (cons 'StrRef 'StrRefUp) (cons 'BvRef 'BvRefUp)
                         (cons 'VecSet 'VecSetUp) (cons 'StrSet 'StrSetUp) (cons 'BvSet 'BvSetUp)
                         (cons 'VecLen 'VecLenUp)))
        ;; Fused compare-and-branch family (see compile-fused-test!): a=src1,
        ;; b=offset (patched via chunk-patch-jump-to-here!, same as
        ;; TestFalse), c=src2/literal/upvalue-idx -- genuinely ONE
        ;; instruction doing both the comparison and the conditional jump,
        ;; not a value-producing op followed by a separate TestFalse.
        (cons 'test-base (list (cons 'NumLt 'TestLt) (cons 'NumLe 'TestLe) (cons 'NumGt 'TestGt)
                               (cons 'NumGe 'TestGe) (cons 'NumEq 'TestEq) (cons 'IsEq 'TestIsEq)))
        (cons 'test-imm (list (cons 'NumLt 'TestLtImm) (cons 'NumLe 'TestLeImm) (cons 'NumGt 'TestGtImm)
                              (cons 'NumGe 'TestGeImm) (cons 'NumEq 'TestEqImm) (cons 'IsEq 'TestIsEqImm)))
        (cons 'test-up (list (cons 'NumLt 'TestLtUp) (cons 'NumLe 'TestLeUp) (cons 'NumGt 'TestGtUp)
                             (cons 'NumGe 'TestGeUp) (cons 'NumEq 'TestEqUp) (cons 'IsEq 'TestIsEqUp)))))

    (define (op-table-lookup which op)
      (let ((hit (assq op (cdr (assq which op-table)))))
        (if hit (cdr hit) #f)))

    ;; A literal exact integer fitting the VM's Int32 immediate-operand
    ;; range -- returns the integer itself (truthy) or #f, never resolves a
    ;; variable (mirrors imm_operand? only ever matching a LiteralNode).
    (define (imm-literal-int expr)
      (and (integer? expr) (exact? expr) (>= expr -2147483648) (<= expr 2147483647) expr))

    ;; Side-effect-free expression -- safe to evaluate anywhere relative
    ;; to another argument's own evaluation, with no observable reordering
    ;; effect. Mirrors bytecode_compiler.cr's own leaf_node? exactly,
    ;; including its recursive case: a bare variable reference or self-
    ;; evaluating literal, OR (recursively) a call to a known, un-shadowed
    ;; fusable primitive whose own arguments are ALL leaves too -- e.g.
    ;; (vector-length v) is a leaf whenever v is, since that call provably
    ;; only reads its own operands and writes its own destination
    ;; register, unlike an arbitrary function call (which might set!
    ;; something, invoke a captured continuation, etc). This distinction
    ;; is what let native's own compiler compare `i` directly against
    ;; `(vector-length v)` in a named-let's own termination test with no
    ;; register copy, while this compiler used to always copy `i` first
    ;; (treating ANY compound expression as unsafe to reorder around) --
    ;; found by diffing disassembled bytecode between the two compilers
    ;; for the exact same source.
    ;;
    ;; Needs `fc` (unlike a purely syntactic check) to confirm a
    ;; candidate primitive name isn't locally shadowed/redefined -- the
    ;; same three checks compile-fused-test!'s own fusion gate already
    ;; makes, factored out here (fusable-head?) so this predicate and
    ;; that gate always agree on what counts as fusable.
    (define (fusable-head? fc name arity)
      (and (symbol? name)
           (not (fcomp-lookup-local fc name))
           (not (fcomp-resolve-upvalue! fc name))
           (not (memq name redefined-fusable-globals))
           (fused-prim-lookup name arity)))

    (define (leaf-expr? fc expr)
      (or (symbol? expr)
          (number? expr) (string? expr) (char? expr) (boolean? expr) (vector? expr) (bytevector? expr)
          (and (pair? expr) (eq? (car expr) 'quote))
          (and (pair? expr)
               (fusable-head? fc (car expr) (length (cdr expr)))
               (leaf-args? fc (cdr expr)))))

    (define (leaf-args? fc exprs)
      (or (null? exprs) (and (leaf-expr? fc (car exprs)) (leaf-args? fc (cdr exprs)))))

    ;; A candidate operand resolves to an upvalue iff it's a bare symbol,
    ;; NOT shadowed by a local in the CURRENT function (checked first, same
    ;; order compile-var-ref! uses -- calling fcomp-resolve-upvalue!
    ;; directly without this check would incorrectly walk into an
    ;; enclosing function's scope for a name that's actually locally
    ;; shadowed here), and fcomp-resolve-upvalue! succeeds.
    (define (upvalue-operand fc expr)
      (and (symbol? expr) (not (fcomp-lookup-local fc expr)) (fcomp-resolve-upvalue! fc expr)))

    ;; ---------------------------------------------------------------------
    ;; Counted-loop recognizer helpers -- the raw-s-expression analogues of
    ;; bytecode_compiler.cr's contains_lambda?/references_name?/step_delta/
    ;; split_tail_self_call, backing try-compile-counted-loop! below. This
    ;; compiler has no typed Node AST to pattern-match against (unlike
    ;; native), so contains-lambda?/references-name? just walk the raw pair
    ;; structure directly -- deliberately NOT quote/quasiquote-aware,
    ;; treating ANY textual occurrence of `lambda`/`case-lambda` (or, for
    ;; references-name?, the given name) as a hit even inside quoted data.
    ;; That's a strict superset of the real "creates a closure"/"is
    ;; referenced" condition -- it only ever costs a missed optimization
    ;; (declining to lower a loop that was actually safe), never an unsafe
    ;; lowering, and sidesteps a whole class of quote-handling complexity
    ;; the native Node-based walk never needed either (see that file's own
    ;; contains_lambda? doc comment for the full rationale this mirrors).
    ;; ---------------------------------------------------------------------

    (define (contains-lambda? expr)
      (cond
        ((pair? expr) (or (eq? (car expr) 'lambda) (eq? (car expr) 'case-lambda)
                           (contains-lambda? (car expr)) (contains-lambda? (cdr expr))))
        (else #f)))

    (define (references-name? expr name)
      (cond
        ((eq? expr name) #t)
        ((pair? expr) (or (references-name? (car expr) name) (references-name? (cdr expr) name)))
        (else #f)))

    ;; The raw-sexpr analogue of comparison_op_of: test-expr a 2-arg call
    ;; resolving (via fusable-head?, the same shadow-check compile-fused-
    ;; test!'s own fusion gate uses) to one of the 5 numeric comparisons
    ;; (excluding eq?, not a counted-loop-shaped test) -> that PrimOp
    ;; symbol, else #f.
    (define (counted-loop-comparison-op fc test-expr)
      (and (pair? test-expr)
           (= (length (cdr test-expr)) 2)
           (let ((entry (fusable-head? fc (car test-expr) 2)))
             (and entry (memq (fp-op entry) '(NumLt NumLe NumGt NumGe NumEq)) (fp-op entry)))))

    ;; The raw-sexpr analogue of step_delta: step-expr is exactly
    ;; `(+ counter-name k)`/`(- counter-name k)` for a literal integer k (via
    ;; imm-literal-int) -> the signed step, else #f. Deliberately doesn't
    ;; gate on fusable-head? here (unlike counted-loop-comparison-op above)
    ;; -- a shadowed/redefined +/- just makes this a non-constant-step loop,
    ;; correctly declined by returning #f regardless.
    (define (counted-loop-step-delta step-expr counter-name)
      (and (pair? step-expr)
           (memq (car step-expr) '(+ -))
           (= (length (cdr step-expr)) 2)
           (eq? (cadr step-expr) counter-name)
           (let ((k (imm-literal-int (caddr step-expr))))
             (and k (if (eq? (car step-expr) '+) k (- k))))))

    ;; The raw-sexpr analogue of split_tail_self_call: if `branch` is (or,
    ;; via one top-level (begin ...), ends in) a call `(loop-name arg...)`
    ;; of exactly `arity` args, returns (cons prefix-forms call-form) --
    ;; else #f, the caller's cue to try the OTHER branch instead.
    (define (split-tail-self-call branch loop-name arity)
      (let* ((is-begin (and (pair? branch) (eq? (car branch) 'begin)))
             (body (and is-begin (cdr branch)))
             (prefix (cond ((not is-begin) '())
                           ((null? body) #f)
                           (else (reverse (cdr (reverse body))))))
             (last (cond ((not is-begin) branch)
                         ((null? body) #f)
                         (else (car (reverse body))))))
        (and prefix last
             (pair? last) (eq? (car last) loop-name) (= (length (cdr last)) arity)
             (cons prefix last))))

    ;; Leaf-argument register reuse (mirrors bytecode_compiler.cr's
    ;; local_register_of?/last_non_leaf): returns the register holding
    ;; expr's value. When reuse-ok? and expr is a bare LOCAL-variable
    ;; reference, that variable's own existing register is used directly
    ;; -- no fresh register, no Move, since a variable read has no
    ;; side effect to preserve ordering for. Otherwise allocates a fresh
    ;; register and compiles into it. `reuse-ok?` must be true only when
    ;; nothing evaluated AFTER this argument (within the same fused op's
    ;; own argument list) can still mutate it -- i.e. every argument from
    ;; this position onward is itself a leaf-expr? -- computed by each
    ;; caller from the concrete, fixed-arity argument list it already has.
    (define (compile-arg! fc expr reuse-ok?)
      (or (and reuse-ok? (symbol? expr) (fcomp-lookup-local fc expr))
          (let ((r (fcomp-alloc-reg! fc)))
            (compile-expr! fc expr r #f)
            r)))

    ;; car/cdr/caar/.../cddddr -- name-pattern recognition, same restriction
    ;; as the real analyzer's cxr_name? (single leading c, single trailing
    ;; r, only a/d letters in between, at least one such letter).
    (define (cxr-name? name)
      (let* ((s (symbol->string name)) (len (string-length s)))
        (and (> len 2)
             (char=? (string-ref s 0) #\c)
             (char=? (string-ref s (- len 1)) #\r)
             (let loop ((i 1))
               (or (= i (- len 1))
                   (and (memv (string-ref s i) (list #\a #\d)) (loop (+ i 1))))))))

    ;; Encode a cxr accessor name's car/cdr chain into Op::Cxr's `c` operand:
    ;; sentinel top bit 1, then per interior letter (between the leading c/
    ;; trailing r) shift left and OR in 1 for a(car)/0 for d(cdr) -- exact
    ;; port of bytecode_compiler.cr's cxr_code, using plain arithmetic
    ;; (code*2+bit) instead of bitwise ops to avoid a new dependency.
    (define (cxr-code name)
      (let* ((s (symbol->string name)) (len (string-length s)))
        (let loop ((i 1) (code 1))
          (if (= i (- len 1))
              code
              (loop (+ i 1) (+ (* code 2) (if (char=? (string-ref s i) #\a) 1 0)))))))

    ;; True for any name this fusion pass could ever act on, at ANY arity --
    ;; used only to decide whether a top-level redefinition needs tracking
    ;; (see redefined-fusable-globals below), not to decide whether a
    ;; SPECIFIC call site fuses.
    (define (fused-prim-name? name)
      (or (cxr-name? name)
          (let loop ((entries fused-prim-table))
            (cond
              ((null? entries) #f)
              ((eq? (fp-name (car entries)) name) #t)
              (else (loop (cdr entries)))))))

    ;; Persistent (process-wide, like macro-table) set of primitive names a
    ;; top-level (define ...)/(define-values ...)/(set! ...) has rebound --
    ;; the compile-time stand-in for the real analyzer's live `env.get?
    ;; (name).is_a?(Builtin)` check (see compile-define!/compile-define-
    ;; values!/compile-set!'s defglobal!/mark-redefined! calls). This
    ;; compiler compiles a whole batch of forms in one static pass with no
    ;; execution interleaved (only `import` runs early for real), so there's
    ;; no live env to consult -- tracking redefinitions textually, in
    ;; compile order, is the next best thing and correctly covers the
    ;; common case (a program shadowing +/cons/etc. at its own top level,
    ;; including across separate REPL inputs, since this persists the same
    ;; way macro-table does). A library import that happens to shadow a
    ;; core primitive globally is a narrower, deliberately-accepted gap:
    ;; the ordinary Call path already handles it correctly, fusion just
    ;; won't conservatively back off for it.
    (define redefined-fusable-globals '())
    (define (mark-redefined! name)
      (if (fused-prim-name? name) (set! redefined-fusable-globals (cons name redefined-fusable-globals))))

    ;; The inverse of mark-redefined! -- removes every occurrence of name
    ;; (mark-redefined! doesn't dedupe, so more than one may be present).
    ;; Exported (alongside mark-redefined! and fusable-prim-names below)
    ;; so `eval` (cvm/compiler-run.scm) can temporarily disable fusion for
    ;; exactly the fusable names a target `environment` excludes via its
    ;; own only/except import-set, for the duration of one compile, then
    ;; restore afterward -- see that function's own doc comment for why
    ;; fusion needs this at all (a fused opcode never consults ANY
    ;; environment, unlike an ordinary GetGlobal+Call).
    (define (unmark-redefined! name)
      (set! redefined-fusable-globals
        (let loop ((names redefined-fusable-globals))
          (cond
            ((null? names) '())
            ((eq? (car names) name) (loop (cdr names)))
            (else (cons (car names) (loop (cdr names))))))))

    ;; Every name fused-prim-table can ever act on (cxr names like `cadr`
    ;; are a separate, pattern-recognized family -- cxr-name? -- not
    ;; enumerable from a fixed table, and not covered by this list).
    (define fusable-prim-names (map fp-name fused-prim-table))

    (define (fusable-call? fc fn-expr nargs)
      (and (symbol? fn-expr)
           (not (fcomp-lookup-local fc fn-expr))
           (not (fcomp-resolve-upvalue! fc fn-expr))
           (not (memq fn-expr redefined-fusable-globals))
           (or (fused-prim-lookup fn-expr nargs)
               (and (= nargs 1) (cxr-name? fn-expr)))))

    ;; 2-arg value ops (a=dst, b=src1, c=src2, d=const-idx of the builtin's
    ;; own name -- always filled, feeds the VM's overflow/tower deopt
    ;; fallback for every one of these, not just the ones that visibly
    ;; need it). Tail position with a *Return variant emits that directly
    ;; (it already returns); otherwise the base op, then an explicit
    ;; Return -- free to do here since this is source-level codegen, not a
    ;; bytecode rewrite with no room to insert an instruction.
    ;;
    ;; Before the base path, try (in this order, matching
    ;; bytecode_compiler.cr's own precedence -- mutually exclusive by op
    ;; identity, so relative order between them never matters):
    ;; *Imm (2nd operand a literal fitting Int32 -- arithmetic/comparison/
    ;; eq? AND vector-ref/string-ref/bytevector-u8-ref all have one),
    ;; *Up on the 2nd operand (arithmetic/comparison/eq? only, gated on the
    ;; 1st operand being a leaf), *Up on the 1st/object operand
    ;; (vector-ref/string-ref/bytevector-u8-ref only, gated on the 2nd
    ;; operand being a leaf). None of the Imm/Up ops read a `d` operand at
    ;; all (verified directly against vm.cr) -- pass 0. No *Return-fused
    ;; counterpart exists for any Imm/Up op, so tail position is just the
    ;; op followed by an explicit Return, same as the 1-arg family below.
    (define (compile-fused-binary! fc entry arg-exprs dest tail?)
      (let ((mark (fcomp-next-reg fc)))
        (let* ((ch (fcomp-chunk fc))
               (op (fp-op entry))
               (arg1 (car arg-exprs))
               (arg2 (cadr arg-exprs))
               (imm-op (op-table-lookup 'imm2 op))
               (imm-val (and imm-op (imm-literal-int arg2)))
               (up2-op (and (not imm-val) (op-table-lookup 'up2 op)))
               (up2-idx (and up2-op (leaf-expr? fc arg1) (upvalue-operand fc arg2)))
               (up1-op (and (not imm-val) (not up2-idx) (op-table-lookup 'up1 op)))
               (up1-idx (and up1-op (leaf-expr? fc arg2) (upvalue-operand fc arg1))))
          (cond
            (imm-val
             (let ((r1 (compile-arg! fc arg1 #t)))
               (chunk-emit! ch imm-op dest r1 imm-val 0)
               (if tail? (chunk-emit! ch 'Return dest 0 0 0))))
            (up2-idx
             (let ((r1 (compile-arg! fc arg1 #t)))
               (chunk-emit! ch up2-op dest r1 up2-idx 0)
               (if tail? (chunk-emit! ch 'Return dest 0 0 0))))
            (up1-idx
             (let ((r2 (compile-arg! fc arg2 #t)))
               (chunk-emit! ch up1-op dest up1-idx r2 0)
               (if tail? (chunk-emit! ch 'Return dest 0 0 0))))
            (else
             (let* ((r1 (compile-arg! fc arg1 (leaf-expr? fc arg2)))
                    (r2 (compile-arg! fc arg2 #t))
                    (builtin-idx (chunk-add-const! ch (fp-name entry)))
                    (return-op (and tail? (fp-return-op entry))))
               (if return-op
                   (chunk-emit! ch return-op dest r1 r2 builtin-idx)
                   (begin
                     (chunk-emit! ch op dest r1 r2 builtin-idx)
                     (if tail? (chunk-emit! ch 'Return dest 0 0 0)))))))
          (fcomp-reclaim-to! fc mark))))

    ;; 1-arg ops (a=dst, b=src, d=const-idx of builtin); CmpZero additionally
    ;; uses c for its test selector (0/1/2), 0 (unused) for everything else.
    ;; No *Return variants exist for this family -- tail position always
    ;; means base op + explicit Return. vector-length has an *Up variant
    ;; (VecLenUp: a=dst, b=upvalue-idx, no c/d at all) when its sole
    ;; argument resolves to an upvalue; the other 1-arg ops (not/null?/
    ;; pair?/abs/zero?/positive?/negative?) have none.
    (define (compile-fused-unary! fc entry arg-exprs dest tail?)
      (let ((mark (fcomp-next-reg fc)))
        (let* ((ch (fcomp-chunk fc))
               (up-op (op-table-lookup 'up1 (fp-op entry)))
               (up-idx (and up-op (upvalue-operand fc (car arg-exprs)))))
          (if up-idx
              (begin
                (chunk-emit! ch up-op dest up-idx 0 0)
                (if tail? (chunk-emit! ch 'Return dest 0 0 0)))
              (let ((r (compile-arg! fc (car arg-exprs) #t)))
                (let ((builtin-idx (chunk-add-const! ch (fp-name entry))))
                  (chunk-emit! ch (fp-op entry) dest r (fp-extra entry) builtin-idx)
                  (if tail? (chunk-emit! ch 'Return dest 0 0 0))))))
        (fcomp-reclaim-to! fc mark)))

    ;; car/cdr/.../cddddr -- same op shape as compile-fused-unary! but with
    ;; the bitmap in c instead of a fixed extra, and the builtin const keyed
    ;; on the accessor's own name (not looked up in fused-prim-table).
    (define (compile-fused-cxr! fc fn-expr arg-expr dest tail?)
      (let ((mark (fcomp-next-reg fc)))
        (let* ((ch (fcomp-chunk fc))
               (r (compile-arg! fc arg-expr #t)))
          (let ((builtin-idx (chunk-add-const! ch fn-expr)))
            (chunk-emit! ch 'Cxr dest r (cxr-code fn-expr) builtin-idx)
            (if tail? (chunk-emit! ch 'Return dest 0 0 0))))
        (fcomp-reclaim-to! fc mark)))

    ;; vector-set!/string-set!/bytevector-u8-set! (a=object, b=index,
    ;; c=value, d=const-idx of builtin) -- R7RS return value is unspecified;
    ;; mirrors the real compiler's own convention (bytecode_compiler.cr) of
    ;; following with Move dest, object-reg (skipped when dest already IS
    ;; the object register) so `(begin (vector-set! v i x) v)`-style usage
    ;; still gets something sensible back.
    ;;
    ;; *Imm (index literal, a=obj-reg,b=literal,c=value-reg, no d, same
    ;; trailing-Move convention as the base op) and *Up (object is an
    ;; upvalue, gated on the index/value args being leaves) are tried
    ;; first. *Up's shape is genuinely different -- a=upvalue-idx,
    ;; b=index-reg, c=value-reg, d=dst -- the mutated object is written
    ;; straight into `d`, no separate Move at all.
    (define (compile-fused-mutate! fc entry arg-exprs dest tail?)
      (let ((mark (fcomp-next-reg fc)))
        (let* ((ch (fcomp-chunk fc))
               (op (fp-op entry))
               (obj-expr (car arg-exprs))
               (idx-expr (cadr arg-exprs))
               (val-expr (caddr arg-exprs))
               (imm-op (op-table-lookup 'imm2 op))
               (imm-val (and imm-op (imm-literal-int idx-expr)))
               (up-op (and (not imm-val) (op-table-lookup 'up1 op)))
               (up-idx (and up-op (leaf-expr? fc idx-expr) (leaf-expr? fc val-expr) (upvalue-operand fc obj-expr))))
          (cond
            (imm-val
             (let* ((obj-reg (compile-arg! fc obj-expr (leaf-expr? fc val-expr)))
                    (val-reg (compile-arg! fc val-expr #t)))
               (chunk-emit! ch imm-op obj-reg imm-val val-reg 0)
               (if (not (= dest obj-reg)) (chunk-emit! ch 'Move dest obj-reg 0 0))
               (if tail? (chunk-emit! ch 'Return dest 0 0 0))))
            (up-idx
             (let* ((idx-reg (compile-arg! fc idx-expr (leaf-expr? fc val-expr)))
                    (val-reg (compile-arg! fc val-expr #t)))
               (chunk-emit! ch up-op up-idx idx-reg val-reg dest)
               (if tail? (chunk-emit! ch 'Return dest 0 0 0))))
            (else
             (let* ((obj-reg (compile-arg! fc obj-expr (and (leaf-expr? fc idx-expr) (leaf-expr? fc val-expr))))
                    (idx-reg (compile-arg! fc idx-expr (leaf-expr? fc val-expr)))
                    (val-reg (compile-arg! fc val-expr #t))
                    (builtin-idx (chunk-add-const! ch (fp-name entry))))
               (chunk-emit! ch op obj-reg idx-reg val-reg builtin-idx)
               (if (not (= dest obj-reg)) (chunk-emit! ch 'Move dest obj-reg 0 0))
               (if tail? (chunk-emit! ch 'Return dest 0 0 0)))))
          (fcomp-reclaim-to! fc mark))))

    (define (compile-fused-prim! fc fn-expr arg-exprs dest tail?)
      (let ((entry (fused-prim-lookup fn-expr (length arg-exprs))))
        (cond
          ((not entry) (compile-fused-cxr! fc fn-expr (car arg-exprs) dest tail?))
          ((= (fp-arity entry) 2) (compile-fused-binary! fc entry arg-exprs dest tail?))
          ((= (fp-arity entry) 1) (compile-fused-unary! fc entry arg-exprs dest tail?))
          (else (compile-fused-mutate! fc entry arg-exprs dest tail?)))))

    ;; Direct call fusion (mirrors bytecode_compiler.cr's bare_callee_source/
    ;; compile_app): a call whose callee is a bare symbol resolves it exactly
    ;; like a variable reference -- local/upvalue/global, same order
    ;; compile-var-ref! uses -- and folds that resolution directly into the
    ;; call instruction's own d operand (register/upvalue-idx/const-idx)
    ;; instead of loading the callee into a dedicated register via a
    ;; preceding Move/GetUpval/GetGlobal. Unlike primitive fusion, this needs
    ;; NO redefinition/shadowing guard at all: CallGlobal still does the
    ;; SAME global lookup at runtime GetGlobal+Call would have, just folded
    ;; into one instruction -- fusing the lookup MECHANISM never bakes in a
    ;; stale meaning, so this applies even to calls that aren't (or fail to
    ;; be) primitive-fused (wrong arity, non-primitive name, shadowed
    ;; primitive name -- resolve-callee reflects whatever the real binding
    ;; is either way).
    (define (resolve-callee fc name)
      (let ((local (fcomp-lookup-local fc name)))
        (cond
          (local (cons 'local local))
          ((fcomp-resolve-upvalue! fc name) => (lambda (up) (cons 'upvalue up)))
          (else (cons 'global (chunk-add-const! (fcomp-chunk fc) (global-ref-name fc name)))))))

    (define (call-op-for kind tail?)
      (cond
        ((eq? kind 'local) (if tail? 'TailCallLocal 'CallLocal))
        ((eq? kind 'upvalue) (if tail? 'TailCallUpval 'CallUpval))
        (else (if tail? 'TailCallGlobal 'CallGlobal))))

    (define (every-leaf? fc exprs)
      (let loop ((es exprs)) (or (null? es) (and (leaf-expr? fc (car es)) (loop (cdr es))))))

    ;; Bumps fcomp-next-reg up to (at least) n WITHOUT touching any register
    ;; below it -- a no-op whenever this function already has n or more
    ;; registers in use (the common case: a recursive function's own tail
    ;; call typically has at least as many locals as it has arguments
    ;; already). Ensures any register allocated AFTER this call is
    ;; guaranteed >= n, so it can never alias target registers 0..n-1.
    (define (fcomp-ensure-next-reg! fc n)
      (let loop () (if (< (fcomp-next-reg fc) n) (begin (fcomp-alloc-reg! fc) (loop)))))

    ;; Does `expr` (already known to be a leaf-expr?, i.e. a symbol,
    ;; self-evaluating literal, quoted datum, or a fusable-prim-call whose
    ;; own arguments are all leaves too -- see every-leaf?'s own gate on
    ;; every caller of this function) read the CURRENT local register
    ;; `reg` anywhere in its own evaluation? A bare symbol reads it iff
    ;; that's its own register; a quoted datum never does (its contents
    ;; are literal data, not variable references, so this deliberately
    ;; does NOT recurse into a (quote ...) the way it does an ordinary
    ;; fusable-prim-call); a fusable-prim-call reads it iff any of its OWN
    ;; arguments (recursively) does -- e.g. (+ acc (vector-ref v i)) reads
    ;; i's register through vector-ref's own 2nd argument. Must stay
    ;; exactly as deep as leaf-expr?'s own recursion: this used to only
    ;; check the bare-symbol case, silently missing exactly this
    ;; compound-argument hazard once every-leaf?/leaf-expr? started
    ;; recognizing a fusable-prim-call as a leaf too.
    (define (arg-reads-register? fc expr reg)
      (or (and (symbol? expr) (eqv? (fcomp-lookup-local fc expr) reg))
          (and (pair? expr)
               (not (eq? (car expr) 'quote))
               (args-read-register? fc (cdr expr) reg))))

    (define (args-read-register? fc exprs reg)
      (and (pair? exprs)
           (or (arg-reads-register? fc (car exprs) reg)
               (args-read-register? fc (cdr exprs) reg))))

    ;; None of a tail call's own target registers 0..nargs-1 may be an open
    ;; upvalue some nested closure captured earlier in THIS function (see
    ;; fcomp-mark-captured!'s own doc comment for why this is required and
    ;; why checking it incrementally, in compile order, is sufficient).
    (define (fast-tail-args-safe? fc nargs)
      (let loop ((i 0))
        (or (= i nargs) (and (not (fcomp-captured? fc i)) (loop (+ i 1))))))

    ;; Compiles arg-exprs directly into registers 0..n-1 -- the tail call's
    ;; own frame-reuse binding positions, since a tail call reuses the
    ;; CURRENT frame's base rather than pushing a new one -- instead of a
    ;; floating anchor+1.. run. Mirrors compile_tail_call_args_in_place
    ;; (bytecode_compiler.cr:1417-1452): a later argument's expression
    ;; reading an EARLIER argument's own target register (only possible
    ;; here since every argument is already known to be a leaf -- i.e. a
    ;; bare local-variable reference or a self-evaluating literal) means
    ;; that earlier argument must be compiled into a scratch register
    ;; first, with its real write deferred (via `pending`) until every
    ;; argument has been read. Callers must already have ensured
    ;; fcomp-next-reg is >= n (fcomp-ensure-next-reg!) before calling this,
    ;; so scratch allocations can never land inside 0..n-1. Does NOT reset
    ;; next-reg itself -- the caller does that, back down to whatever it
    ;; was BEFORE this whole tail-call sequence started (not down to n --
    ;; the enclosing function typically already has more than n registers
    ;; in use for its own locals/temporaries, which must not be clobbered).
    (define (compile-tail-call-args-in-place! fc arg-exprs)
      (let* ((n (length arg-exprs))
             (arr (list->vector arg-exprs))
             (ch (fcomp-chunk fc))
             (pending '()))
        (let loop ((i 0))
          (if (< i n)
              (begin
                (let ((expr (vector-ref arr i)))
                  (if (let scan ((j (+ i 1)))
                        (and (< j n) (or (arg-reads-register? fc (vector-ref arr j) i) (scan (+ j 1)))))
                      (let ((scratch (fcomp-alloc-reg! fc)))
                        (compile-expr! fc expr scratch #f)
                        (set! pending (cons (cons scratch i) pending)))
                      (compile-expr! fc expr i #f)))
                (loop (+ i 1)))))
        (for-each
          (lambda (p) (if (not (= (car p) (cdr p))) (chunk-emit! ch 'Move (cdr p) (car p) 0 0)))
          (reverse pending))))

    ;; Call args are reserved contiguously (anchor/fn-reg, +1, ...) BEFORE any
    ;; of them are compiled, so a nested call inside one argument's own
    ;; expression can't allocate a temp register that lands inside this
    ;; block -- Call/TailCall (and the fused Call*/TailCall* family) require
    ;; the whole a+1..a+b window contiguous. The anchor register is still
    ;; allocated in the fused-callee case (so args land at anchor+1.., same
    ;; convention as the generic path) but nothing is ever written into it --
    ;; the fused op's own d operand says where to fetch the callee from
    ;; instead (see bytecode_compiler.cr:1845-1921, exec_call_* in vm.cr).
    ;;
    ;; A tail call with a bare-symbol callee whose arguments are all leaves,
    ;; none of which land on an already-captured register, instead takes
    ;; the fast in-place path above: anchor=-1 (args occupy 0..n-1 directly,
    ;; no wasted anchor register at all), and a :local callee whose own
    ;; register would fall inside 0..n-1 is copied to a scratch register
    ;; FIRST (unconditionally, not deferred -- the call instruction reads
    ;; its callee operand at its own execution time, strictly after every
    ;; argument write, so there is no later "safe" read point to defer to).
    (define (compile-ordinary-app! fc fn-expr arg-exprs dest tail?)
      (let ((ch (fcomp-chunk fc)))
        (if (symbol? fn-expr)
            (let* ((resolved (resolve-callee fc fn-expr))
                   (kind (car resolved))
                   (operand (cdr resolved))
                   (op (call-op-for kind tail?))
                   (nargs (length arg-exprs)))
              (if (and tail? (every-leaf? fc arg-exprs) (fast-tail-args-safe? fc nargs))
                  (let ((mark (fcomp-next-reg fc)))
                    (fcomp-ensure-next-reg! fc nargs)
                    (let ((safe-operand
                            (if (and (eq? kind 'local) (< operand nargs))
                                (let ((scratch (fcomp-alloc-reg! fc)))
                                  (chunk-emit! ch 'Move scratch operand 0 0)
                                  scratch)
                                operand)))
                      (compile-tail-call-args-in-place! fc arg-exprs)
                      (chunk-emit! ch op -1 nargs 0 safe-operand)
                      (fcomp-next-reg-set! fc (max mark nargs))))
                  (let ((mark (fcomp-next-reg fc)))
                    (let* ((anchor (fcomp-alloc-reg! fc))
                           (arg-regs (map (lambda (a) (fcomp-alloc-reg! fc)) arg-exprs)))
                      (for-each (lambda (a r) (compile-expr! fc a r #f)) arg-exprs arg-regs)
                      (if tail?
                          (chunk-emit! ch op anchor nargs 0 operand)
                          (chunk-emit! ch op anchor nargs dest operand)))
                    (fcomp-reclaim-to! fc mark))))
            (let ((mark (fcomp-next-reg fc)))
              (let* ((fn-reg (fcomp-alloc-reg! fc))
                     (arg-regs (map (lambda (a) (fcomp-alloc-reg! fc)) arg-exprs)))
                (compile-expr! fc fn-expr fn-reg #f)
                (for-each (lambda (a r) (compile-expr! fc a r #f)) arg-exprs arg-regs)
                (if tail?
                    (chunk-emit! ch 'TailCall fn-reg (length arg-exprs) 0 0)
                    (chunk-emit! ch 'Call fn-reg (length arg-exprs) dest 0)))
              (fcomp-reclaim-to! fc mark)))))

    (define (compile-app! fc expr dest tail?)
      (let* ((fn-expr (car expr))
             (arg-exprs (cdr expr)))
        (if (fusable-call? fc fn-expr (length arg-exprs))
            (compile-fused-prim! fc fn-expr arg-exprs dest tail?)
            (compile-ordinary-app! fc fn-expr arg-exprs dest tail?))))

    (define (compile-plain-let! fc bindings body dest tail?)
      (let* ((names (map car bindings))
             (val-exprs (map cadr bindings))
             (val-regs (map (lambda (v) (let ((r (fcomp-alloc-reg! fc))) (compile-expr! fc v r #f) r)) val-exprs)))
        (fcomp-push-scope! fc)
        (for-each (lambda (n r) (fcomp-declare-local! fc n r)) names val-regs)
        (compile-scoped-body! fc body dest tail?)
        (fcomp-pop-scope! fc)))

    ;; let* -- unlike plain let, each binding's value expression can see the
    ;; ones before it, so each name is declared into the (single, shared)
    ;; scope frame as soon as its own value is compiled, before the next
    ;; binding's value expression compiles.
    (define (compile-let-star! fc bindings body dest tail?)
      (fcomp-push-scope! fc)
      (for-each
        (lambda (binding)
          (let ((r (fcomp-alloc-reg! fc)))
            (compile-expr! fc (cadr binding) r #f)
            (fcomp-declare-local! fc (car binding) r)))
        bindings)
      (compile-scoped-body! fc body dest tail?)
      (fcomp-pop-scope! fc))

    ;; letrec/letrec* -- treated identically (sequential init evaluation),
    ;; a legal implementation of plain letrec too. Every name's register is
    ;; allocated and declared BEFORE any init expression compiles, so each
    ;; init (and the body) can reference any of the others, including itself
    ;; (e.g. a local recursive helper), as a local/upvalue from the start.
    (define (compile-letrec! fc bindings body dest tail?)
      (let* ((names (map car bindings))
             (val-exprs (map cadr bindings))
             (regs (map (lambda (n) (fcomp-alloc-reg! fc)) names)))
        (fcomp-push-scope! fc)
        (for-each (lambda (n r) (fcomp-declare-local! fc n r)) names regs)
        (for-each (lambda (v r) (compile-expr! fc v r #f)) val-exprs regs)
        (compile-scoped-body! fc body dest tail?)
        (fcomp-pop-scope! fc)))

    ;; let-values -- all binding expressions (each possibly a multi-value
    ;; producer, via ordinary `values`) evaluate and Destructure in the OUTER
    ;; scope first, same as plain let, so no binding can see another; only
    ;; then are all the destructured names declared together.
    (define (compile-let-values! fc bindings body dest tail?)
      (let ((all-info
              (map
                (lambda (binding)
                  (let* ((formals (car binding))
                         (val-expr (cadr binding))
                         (parsed (parse-formals formals))
                         (fixed (car parsed))
                         (rest (cdr parsed))
                         (count (length fixed))
                         (total (+ count (if rest 1 0)))
                         (src-reg (fcomp-alloc-reg! fc)))
                    (compile-expr! fc val-expr src-reg #f)
                    (let ((base-reg (fcomp-alloc-regs! fc total)))
                      (chunk-emit! (fcomp-chunk fc) 'Destructure src-reg base-reg count (if rest 1 0))
                      (list fixed rest base-reg))))
                bindings)))
        (fcomp-push-scope! fc)
        (for-each
          (lambda (info)
            (let loop ((names (car info)) (r (caddr info)))
              (if (pair? names)
                  (begin (fcomp-declare-local! fc (car names) r) (loop (cdr names) (+ r 1)))
                  (if (cadr info) (fcomp-declare-local! fc (cadr info) r)))))
          all-info)
        (compile-scoped-body! fc body dest tail?)
        (fcomp-pop-scope! fc)))

    ;; let*-values -- unlike plain let-values, each binding's own expression
    ;; can see the names bound by earlier ones (declared incrementally, same
    ;; shape as compile-let-star!).
    (define (compile-let-star-values! fc bindings body dest tail?)
      (fcomp-push-scope! fc)
      (for-each
        (lambda (binding)
          (let* ((formals (car binding))
                 (val-expr (cadr binding))
                 (parsed (parse-formals formals))
                 (fixed (car parsed))
                 (rest (cdr parsed))
                 (count (length fixed))
                 (total (+ count (if rest 1 0)))
                 (src-reg (fcomp-alloc-reg! fc)))
            (compile-expr! fc val-expr src-reg #f)
            (let ((base-reg (fcomp-alloc-regs! fc total)))
              (chunk-emit! (fcomp-chunk fc) 'Destructure src-reg base-reg count (if rest 1 0))
              (let loop ((names fixed) (r base-reg))
                (if (pair? names)
                    (begin (fcomp-declare-local! fc (car names) r) (loop (cdr names) (+ r 1)))
                    (if rest (fcomp-declare-local! fc rest r)))))))
        bindings)
      (compile-scoped-body! fc body dest tail?)
      (fcomp-pop-scope! fc))

    ;; Top level only -- internal define-values is expanded away before it
    ;; ever reaches here, see hoist-internal-defines/expand-definition-form/
    ;; define-values->define-forms (a different, list-based desugaring;
    ;; unrelated to this Destructure-based one, which stays the top-level
    ;; path since there's no local scope to bind into at the top level
    ;; anyway). This guard is a safety net for the rare non-body position,
    ;; same as compile-define!/compile-define-record-type!'s own. Destructures
    ;; into scratch registers, then DefGlobals
    ;; each name -- there's no local scope to bind into at the top level.
    (define (compile-define-values! fc expr dest tail?)
      (if (fcomp-parent fc)
          (error "bootstrap compiler: internal define-values is not yet supported" expr)
          (let* ((parsed (parse-formals (cadr expr)))
                 (fixed (car parsed))
                 (rest (cdr parsed))
                 (count (length fixed))
                 (total (+ count (if rest 1 0)))
                 (ch (fcomp-chunk fc))
                 (src-reg (fcomp-alloc-reg! fc)))
            (compile-expr! fc (caddr expr) src-reg #f)
            (let ((base-reg (fcomp-alloc-regs! fc total)))
              (chunk-emit! ch 'Destructure src-reg base-reg count (if rest 1 0))
              (let loop ((names fixed) (r base-reg))
                (if (pair? names)
                    (begin (defglobal! ch (car names) r) (loop (cdr names) (+ r 1)))
                    (if rest (defglobal! ch rest r))))
              (if tail? (compile-literal-datum! fc '() dest #t))))))

    ;; ---------------------------------------------------------------------
    ;; Counted-loop recognizer + lowering -- the self-hosted analogue of
    ;; bytecode_compiler.cr's try_compile_counted_loop (see that file's own
    ;; doc comment for the full rationale). Recognizes `(let loop ((p
    ;; init)...) (if test base-case (begin ...prefix... (loop step...))))`
    ;; -- or the equivalent shape `do` desugars into, see compile-do! above
    ;; -- as a "simple counted loop": one bound variable (the counter)
    ;; stepped by a compile-time-constant integer add/sub, tested against a
    ;; loop-invariant bound, with no lambda/case-lambda literal anywhere in
    ;; the body and loop-name referenced nowhere but that one recognized
    ;; tail call. When every condition holds, lowers directly to Op::
    ;; ForPrep/Op::ForLoop over plain mutable registers instead of a
    ;; closure+Call/TailCall. recognize-counted-loop returns #f (no side
    ;; effects at all) the instant any condition fails, so compile-named-
    ;; let! can try it first and fall back to its existing unconditional
    ;; body on #f.
    ;; ---------------------------------------------------------------------

    (define (index-of x lst)
      (let loop ((l lst) (i 0))
        (cond ((null? l) #f) ((eq? (car l) x) i) (else (loop (cdr l) (+ i 1))))))

    (define (any-pred? pred lst)
      (and (pair? lst) (or (pred (car lst)) (any-pred? pred (cdr lst)))))

    (define (all-pred? pred lst)
      (or (null? lst) (and (pred (car lst)) (all-pred? pred (cdr lst)))))

    ;; A local `filter` -- (scheme base) doesn't provide one and this
    ;; library's own import list has no library that does either (SRFI-1's
    ;; `filter`/`remove` aren't R7RS base), so this stays self-contained
    ;; rather than adding a new import for two small call sites.
    (define (filter-keep pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (filter-keep pred (cdr lst))))
            (else (filter-keep pred (cdr lst)))))

    (define (indices-below n)
      (let loop ((i (- n 1)) (acc '()))
        (if (< i 0) acc (loop (- i 1) (cons i acc)))))

    (define (escape-safe? expr loop-name)
      (and (not (contains-lambda? expr)) (not (references-name? expr loop-name))))

    ;; Parses `body` as exactly one (if test conseq [alt]) form, peeling a
    ;; leading (not ...) test the same way compile-if! does -- returns
    ;; (list test then-branch else-branch), or #f if body isn't this shape.
    ;; A missing alt means "evaluate to NIL", the common no-accumulator
    ;; "for-each"-style loop shape (e.g. `(let loop ((i 0)) (if (< i n)
    ;; (begin ...(loop (+ i 1))))))`) -- only ever reachable as the
    ;; non-recursive branch, since there's nowhere else for a recursive
    ;; call to appear with no alt at all.
    (define (counted-loop-if-shape body)
      (and (= (length body) 1)
           (pair? (car body))
           (eq? (caar body) 'if)
           (let* ((if-expr (car body))
                  (raw-test (cadr if-expr))
                  (raw-conseq (caddr if-expr))
                  (raw-alt (if (pair? (cdddr if-expr)) (cadddr if-expr) (list 'quote '())))
                  (peeled? (and (pair? raw-test) (eq? (car raw-test) 'not)
                                (pair? (cdr raw-test)) (null? (cddr raw-test)))))
             (list (if peeled? (cadr raw-test) raw-test)
                   (if peeled? raw-alt raw-conseq)
                   (if peeled? raw-conseq raw-alt)))))

    ;; Recognizes test's counter: a 2-arg comparison (via counted-loop-
    ;; comparison-op) whose first arg is one of the loop's own bound names.
    ;; Returns (list cmp-op counter-index counter-name bound-expr), or #f.
    (define (counted-loop-counter fc test names)
      (and (pair? test)
           (let ((cmp-op (counted-loop-comparison-op fc test)))
             (and cmp-op
                  (let* ((counter-candidate (cadr test))
                         (counter-name (and (symbol? counter-candidate) counter-candidate))
                         (counter-index (and counter-name (index-of counter-name names))))
                    (and counter-index (list cmp-op counter-index counter-name (caddr test))))))))

    ;; Translates whatever the source test means into Op::ForPrep/Op::
    ;; ForLoop's own INCLUSIVE-of-limit convention (opcode.cr's own doc
    ;; comment) -- the limit register always holds a value such that
    ;; "continue while step > 0 ? counter <= limit : counter >= limit"
    ;; reproduces the source's exact iteration count. #f for any (cmp-op,
    ;; step-direction, branch-position) combination this recognizer doesn't
    ;; confidently handle.
    (define (counted-loop-limit-delta recurse-in-conseq? cmp-op step)
      (if recurse-in-conseq?
          (cond ((and (eq? cmp-op 'NumLt) (> step 0)) -1)
                ((and (eq? cmp-op 'NumLe) (> step 0)) 0)
                ((and (eq? cmp-op 'NumGt) (< step 0)) 1)
                ((and (eq? cmp-op 'NumGe) (< step 0)) 0)
                (else #f))
          (cond ((and (eq? cmp-op 'NumGe) (> step 0)) -1)
                ((and (eq? cmp-op 'NumLe) (< step 0)) 1)
                ((and (eq? cmp-op 'NumEq) (or (= step 1) (= step -1))) (if (> step 0) -1 1))
                (else #f))))

    ;; The full recognizer -- returns #f the instant any condition fails
    ;; (no side effects, safe to call speculatively), or a bundle
    ;; (list names inits counter-index counter-name bound-expr limit-delta
    ;;       step prefix call-args base-branch)
    ;; for compile-counted-loop! to lower.
    (define (recognize-counted-loop fc loop-name bindings body)
      (let ((shape (counted-loop-if-shape body)))
        (and shape
             (let* ((test (car shape)) (then-branch (cadr shape)) (else-branch (caddr shape))
                    (names (map car bindings)) (inits (map cadr bindings)) (arity (length names))
                    (counter-info (counted-loop-counter fc test names)))
               (and counter-info
                    (let* ((cmp-op (car counter-info)) (counter-index (cadr counter-info))
                           (counter-name (caddr counter-info)) (bound-expr (cadddr counter-info)))
                      (and (all-pred? (lambda (p) (not (references-name? bound-expr p))) names)
                           (not (contains-lambda? bound-expr))
                           (let* ((then-split (split-tail-self-call then-branch loop-name arity))
                                  (recurse-in-conseq? (and then-split #t))
                                  (split (or then-split (split-tail-self-call else-branch loop-name arity))))
                             (and split
                                  (let* ((base-branch (if then-split else-branch then-branch))
                                         (prefix (car split))
                                         (call-args (cdr (cdr split))))
                                    (and (escape-safe? base-branch loop-name)
                                         (all-pred? (lambda (s) (escape-safe? s loop-name)) prefix)
                                         (all-pred? (lambda (a) (escape-safe? a loop-name)) call-args)
                                         (let ((step (counted-loop-step-delta (list-ref call-args counter-index) counter-name)))
                                           (and step (not (= step 0))
                                                (let ((limit-delta (counted-loop-limit-delta recurse-in-conseq? cmp-op step)))
                                                  (and limit-delta
                                                       (list names inits counter-index counter-name bound-expr
                                                             limit-delta step prefix call-args base-branch))))))))))))))))

    ;; Lowers a recognized shape (see recognize-counted-loop above) directly
    ;; to Op::ForPrep/Op::ForLoop over persistent registers -- reserves one
    ;; register per bound variable in the CURRENT fcomp (fcomp-declare-
    ;; local! directly onto the already-computed init register, exactly
    ;; compile-plain-let!'s own idiom -- no child closure, no Call/TailCall
    ;; at all), compiles the recurse-branch's prefix statements and the
    ;; non-counter carried variables' step expressions directly against
    ;; those same registers every iteration (applying the same direct-
    ;; write-when-nothing-else-reads-it optimization bytecode_compiler.cr's
    ;; own try_compile_counted_loop applies, computed inline here rather
    ;; than as a later pass), and compiles the base-branch as the loop's
    ;; result expression once it falls through.
    (define (compile-counted-loop! fc shape dest tail?)
      (let ((names (list-ref shape 0)) (inits (list-ref shape 1)) (counter-index (list-ref shape 2))
            (bound-expr (list-ref shape 4)) (limit-delta (list-ref shape 5)) (step (list-ref shape 6))
            (prefix (list-ref shape 7)) (call-args (list-ref shape 8)) (base-branch (list-ref shape 9)))
        (let* ((ch (fcomp-chunk fc))
               (init-regs (map (lambda (init) (let ((r (fcomp-alloc-reg! fc))) (compile-expr! fc init r #f) r)) inits)))
          (fcomp-push-scope! fc)
          (for-each (lambda (n r) (fcomp-declare-local! fc n r)) names init-regs)
          (let ((limit-reg (fcomp-alloc-reg! fc)))
            (compile-expr! fc bound-expr limit-reg #f)
            (fcomp-declare-local! fc (fresh-symbol! "for-limit-") limit-reg)
            (if (not (= limit-delta 0)) (chunk-emit! ch 'AddImm limit-reg limit-reg limit-delta 0))
            (let* ((counter-reg (list-ref init-regs counter-index))
                   (prep-instr (chunk-emit! ch 'ForPrep counter-reg 0 limit-reg step))
                   (body-start (length (chunk-instrs ch))))
              (for-each
                (lambda (stmt)
                  (let ((mark (fcomp-next-reg fc)) (r (fcomp-alloc-reg! fc)))
                    (compile-expr! fc stmt r #f)
                    (fcomp-reclaim-to! fc mark)))
                prefix)
              (let ((mark4 (fcomp-next-reg fc)))
                (let* ((other (filter-keep (lambda (i) (not (= i counter-index))) (indices-below (length names))))
                       (needs-temp
                         (filter-keep
                           (lambda (i)
                             (any-pred?
                               (lambda (j) (and (not (= j i)) (references-name? (list-ref call-args j) (list-ref names i))))
                               other))
                           other))
                       (direct (filter-keep (lambda (i) (not (memv i needs-temp))) other))
                       (temp-pairs
                         (map (lambda (i) (let ((r (fcomp-alloc-reg! fc))) (compile-expr! fc (list-ref call-args i) r #f) (cons i r)))
                              needs-temp)))
                  (for-each (lambda (i) (compile-expr! fc (list-ref call-args i) (list-ref init-regs i) #f)) direct)
                  (for-each
                    (lambda (p)
                      (let ((i (car p)) (r (cdr p)))
                        (if (not (= (list-ref init-regs i) r)) (chunk-emit! ch 'Move (list-ref init-regs i) r 0 0))))
                    temp-pairs))
                (fcomp-reclaim-to! fc mark4))
              (let ((loop-instr (chunk-emit! ch 'ForLoop counter-reg 0 limit-reg step)))
                (chunk-patch-jump-to! ch loop-instr body-start)
                (chunk-patch-jump-to-here! ch prep-instr)
                (compile-expr! fc base-branch dest tail?)
                (fcomp-pop-scope! fc)))))))

    ;; ---------------------------------------------------------------------
    ;; Extends the same counted-loop recognizer (recognize-counted-loop
    ;; above) to an ordinary self-recursive (define (f params...) body) --
    ;; mirrors bytecode_compiler.cr's try_compile_global_counted_loop
    ;; byte-for-byte; see its own doc comment for the full rationale.
    ;; Unlike a let-loop/do, f's own name is a mutable GLOBAL, so lowering
    ;; straight to registers the same way would silently stop honoring a
    ;; mid-loop (set! f ...)/re-`define`. Two extra hard requirements on
    ;; top of recognize-counted-loop's own make this safe: the step must
    ;; be exactly +-1 (Op::ForLoopGuardedInc/Dec only have room for a
    ;; global reference by dropping the plain loop's general step operand
    ;; -- see opcode.cr's own doc comment), and proc-name must resolve to
    ;; neither a local nor an upvalue from child-fc's own scope (i.e. it
    ;; would otherwise compile as a global call) -- an internal (define (f
    ;; ...) ...) or a named-let's own loop name never qualifies.
    ;;
    ;; child-fc already has `fixed` declared as its own param registers
    ;; (compile-lambda! calls this right after declaring them, before
    ;; falling back to compile-scoped-body!) -- unlike the let-loop/do
    ;; path, there's no inits/Move-in step at all: the loop's "initial
    ;; values" are simply the function's own incoming arguments, already
    ;; exactly where they need to be. Returns #t (having emitted the
    ;; child's whole body, tail position, into dest) or #f (having emitted
    ;; nothing at all, safe to fall back to compile-scoped-body!).
    ;;
    ;; When recognized: the counted loop still runs entirely in registers,
    ;; but every iteration re-checks (by pointer identity, not eqv?/
    ;; equal?) that the global is still bound to the exact closure that's
    ;; running, and deopts the instant it isn't -- falls through to a
    ;; REAL, ordinary (unfused) compilation of the original `if`, exactly
    ;; what would have run without this optimization at all.
    ;; ---------------------------------------------------------------------
    (define (compile-global-counted-loop! child-fc proc-name fixed shape body-forms dest)
      (let ((counter-index (list-ref shape 2)) (bound-expr (list-ref shape 4))
            (limit-delta (list-ref shape 5)) (step (list-ref shape 6))
            (prefix (list-ref shape 7)) (call-args (list-ref shape 8)) (base-branch (list-ref shape 9)))
        (let* ((ch (fcomp-chunk child-fc))
               (param-regs (map (lambda (p) (fcomp-lookup-local child-fc p)) fixed))
               (limit-reg (fcomp-alloc-reg! child-fc)))
          (compile-expr! child-fc bound-expr limit-reg #f)
          (fcomp-declare-local! child-fc (fresh-symbol! "for-limit-") limit-reg)
          (if (not (= limit-delta 0)) (chunk-emit! ch 'AddImm limit-reg limit-reg limit-delta 0))
          ;; ForPrep is unconditionally shared with the plain (let-loop/do)
          ;; lowering and ALWAYS reads its own 4th operand as the real step
          ;; for its zero-trip check (vm.cr/vm.c) -- it has no "guarded"
          ;; flavor of its own to imply the step from, so it must get the
          ;; genuine step here even though the terminal loop op below gets
          ;; a global const index in that same operand slot instead.
          (let* ((counter-reg (list-ref param-regs counter-index))
                 (prep-instr (chunk-emit! ch 'ForPrep counter-reg 0 limit-reg step))
                 (body-start (length (chunk-instrs ch))))
            (for-each
              (lambda (stmt)
                (let ((mark (fcomp-next-reg child-fc)) (r (fcomp-alloc-reg! child-fc)))
                  (compile-expr! child-fc stmt r #f)
                  (fcomp-reclaim-to! child-fc mark)))
              prefix)
            (let ((mark4 (fcomp-next-reg child-fc)))
              (let* ((other (filter-keep (lambda (i) (not (= i counter-index))) (indices-below (length fixed))))
                     (needs-temp
                       (filter-keep
                         (lambda (i)
                           (any-pred?
                             (lambda (j) (and (not (= j i)) (references-name? (list-ref call-args j) (list-ref fixed i))))
                             other))
                         other))
                     (direct (filter-keep (lambda (i) (not (memv i needs-temp))) other))
                     (temp-pairs
                       (map (lambda (i) (let ((r (fcomp-alloc-reg! child-fc))) (compile-expr! child-fc (list-ref call-args i) r #f) (cons i r)))
                            needs-temp)))
                (for-each (lambda (i) (compile-expr! child-fc (list-ref call-args i) (list-ref param-regs i) #f)) direct)
                (for-each
                  (lambda (p)
                    (let ((i (car p)) (r (cdr p)))
                      (if (not (= (list-ref param-regs i) r)) (chunk-emit! ch 'Move (list-ref param-regs i) r 0 0))))
                  temp-pairs))
              (fcomp-reclaim-to! child-fc mark4))
            (let* ((loop-op (if (> step 0) 'ForLoopGuardedInc 'ForLoopGuardedDec))
                   (name-const (chunk-add-const! ch proc-name))
                   (loop-instr (chunk-emit! ch loop-op counter-reg 0 limit-reg name-const)))
              (chunk-patch-jump-to! ch loop-instr body-start)
              (chunk-patch-jump-to-here! ch prep-instr)
              (let ((deopt-instr (chunk-emit! ch 'TestGlobalIdentity name-const 0 0 0)))
                (compile-expr! child-fc base-branch dest #t)
                ;; Deopt block -- reachable only via TestGlobalIdentity's
                ;; forward jump, the instant the global's been reassigned
                ;; mid-loop. Simply the ordinary, unfused compilation of the
                ;; whole original `if`, using the SAME param-regs (already
                ;; holding exactly what the next recursive call's arguments
                ;; would be) -- re-testing the base case fresh, or
                ;; tail-calling whatever proc-name is bound to NOW if it's
                ;; still recursing.
                (chunk-patch-jump-to-here! ch deopt-instr)
                (compile-expr! child-fc (car body-forms) dest #t)))))))

    (define (try-compile-global-counted-loop! child-fc proc-name fixed body-forms)
      (let ((shape (recognize-counted-loop child-fc proc-name (map (lambda (p) (list p #f)) fixed) body-forms)))
        (and shape
             (let ((step (list-ref shape 6)))
               (and (or (= step 1) (= step -1))
                    (not (fcomp-lookup-local child-fc proc-name))
                    (not (fcomp-resolve-upvalue! child-fc proc-name))
                    (begin
                      (compile-global-counted-loop! child-fc proc-name fixed shape body-forms (fcomp-alloc-reg! child-fc))
                      #t))))))

    ;; ---------------------------------------------------------------------
    ;; General (non-counted) loop closure elimination -- mirrors bytecode_
    ;; compiler.cr's detect_general_loop_shape/detect_general_cond_loop_
    ;; shape/emit_general_loop/emit_general_cond_loop/try_compile_general_
    ;; loop byte-for-byte, adapted to this compiler's own s-expression/
    ;; register-fcomp primitives. Generalizes recognize-counted-loop by
    ;; dropping the counter/step/limit requirements entirely (termination
    ;; isn't provable here, unlike a numeric range) -- covers a self-tail-
    ;; recursive named-let/do that walks something other than a counter
    ;; (e.g. `(cdr ...)`), the shape hashtable-test's own `scan` actually
    ;; uses via `cond`. Tried as a fallback in compile-named-let! right
    ;; after recognize-counted-loop declines -- `do` desugars to a named-
    ;; let in this compiler too, so this one wiring point covers both.
    ;; ---------------------------------------------------------------------

    ;; Recognizes a plain (if test recurse-branch base-branch) or (if test
    ;; base-branch recurse-branch) shape whose one branch self-tail-
    ;; recurses and the other doesn't. Returns (list test recurse-in-
    ;; conseq? prefix call-args base-branch), or #f.
    (define (general-if-loop-shape loop-name names body)
      (let ((shape (counted-loop-if-shape body)))
        (and shape
             (let* ((test (car shape)) (then-branch (cadr shape)) (else-branch (caddr shape))
                    (arity (length names)))
               (and (escape-safe? test loop-name)
                    (let* ((then-split (split-tail-self-call then-branch loop-name arity))
                           (recurse-in-conseq? (and then-split #t))
                           (split (or then-split (split-tail-self-call else-branch loop-name arity))))
                      (and split
                           (let* ((base-branch (if then-split else-branch then-branch))
                                  (prefix (car split))
                                  (call-args (cdr (cdr split))))
                             (and (escape-safe? base-branch loop-name)
                                  (all-pred? (lambda (s) (escape-safe? s loop-name)) prefix)
                                  (all-pred? (lambda (a) (escape-safe? a loop-name)) call-args)
                                  (list test recurse-in-conseq? prefix call-args base-branch))))))))))

    ;; Recognizes `(cond clause...)` bodies whose LAST clause self-tail-
    ;; recurses (unconditionally via `else`, or with its own real test) and
    ;; every earlier clause is an ordinary, non-recursive, lambda-free
    ;; guard (a plain (test body...) clause -- no else/=> before the last
    ;; position). Returns (list earlier-clauses recurse-test prefix call-
    ;; args), or #f. recurse-test is #f for an unconditional (else ...)
    ;; final clause.
    (define (general-cond-loop-shape loop-name names clauses)
      (and (pair? clauses)
           (let* ((arity (length names))
                  (earlier (reverse (cdr (reverse clauses))))
                  (last (car (reverse clauses)))
                  (last-test (car last))
                  (last-body (cdr last)))
             (and (pair? last-body)
                  (not (eq? (car last-body) '=>))
                  (all-pred? (lambda (c) (and (not (eq? (car c) 'else))
                                              (pair? (cdr c))
                                              (not (eq? (cadr c) '=>))))
                             earlier)
                  (let* ((last-branch (if (= (length last-body) 1) (car last-body) (cons 'begin last-body)))
                         (split (split-tail-self-call last-branch loop-name arity)))
                    (and split
                         (let ((prefix (car split)) (call-args (cdr (cdr split))))
                           (and (or (eq? last-test 'else) (escape-safe? last-test loop-name))
                                (all-pred? (lambda (s) (escape-safe? s loop-name)) prefix)
                                (all-pred? (lambda (a) (escape-safe? a loop-name)) call-args)
                                (all-pred?
                                  (lambda (c) (and (escape-safe? (car c) loop-name)
                                                    (all-pred? (lambda (f) (escape-safe? f loop-name)) (cdr c))))
                                  earlier)
                                (list earlier (if (eq? last-test 'else) #f last-test) prefix call-args)))))))))

    ;; Compiles the recurse-step shared by both emitters below: the
    ;; prefix statements, then every loop-carried parameter's new value --
    ;; direct-writing into its own register when nothing else reads it,
    ;; otherwise routing through a temp register first (needs-temp path,
    ;; same discipline as compile-counted-loop! above) -- then a backward
    ;; Jmp to loop-start.
    (define (emit-general-recurse-step! fc ch names param-regs prefix call-args loop-start)
      (for-each
        (lambda (stmt)
          (let ((mark (fcomp-next-reg fc)) (r (fcomp-alloc-reg! fc)))
            (compile-expr! fc stmt r #f)
            (fcomp-reclaim-to! fc mark)))
        prefix)
      (let ((mark2 (fcomp-next-reg fc)))
        (let* ((all (indices-below (length names)))
               (needs-temp
                 (filter-keep
                   (lambda (i)
                     (any-pred? (lambda (j) (and (not (= j i)) (references-name? (list-ref call-args j) (list-ref names i)))) all))
                   all))
               (direct (filter-keep (lambda (i) (not (memv i needs-temp))) all))
               (temp-pairs (map (lambda (i) (let ((r (fcomp-alloc-reg! fc))) (compile-expr! fc (list-ref call-args i) r #f) (cons i r))) needs-temp)))
          (for-each (lambda (i) (compile-expr! fc (list-ref call-args i) (list-ref param-regs i) #f)) direct)
          (for-each (lambda (p) (if (not (= (list-ref param-regs (car p)) (cdr p))) (chunk-emit! ch 'Move (list-ref param-regs (car p)) (cdr p) 0 0))) temp-pairs))
        (fcomp-reclaim-to! fc mark2))
      (let ((back-instr (chunk-emit! ch 'Jmp 0 0 0 0)))
        (chunk-patch-jump-to! ch back-instr loop-start)))

    ;; Lowers a recognized general-if-loop shape (see general-if-loop-shape
    ;; above) to plain mutable registers plus an ordinary per-iteration
    ;; test (compile-fused-test!/TestFalse, same as compile-if-branches!
    ;; uses) and a backward Jmp -- there's no numeric range to fuse into
    ;; Op::ForPrep/ForLoop here. param-regs are the loop-carried registers,
    ;; already declared/initialized by the caller.
    (define (emit-general-loop! fc shape names param-regs dest tail?)
      (let ((test (list-ref shape 0)) (recurse-in-conseq? (list-ref shape 1))
            (prefix (list-ref shape 2)) (call-args (list-ref shape 3)) (base-branch (list-ref shape 4)))
        (let* ((ch (fcomp-chunk fc))
               (loop-start (length (chunk-instrs ch)))
               (jmp-false (or (compile-fused-test! fc test)
                              (let ((mark (fcomp-next-reg fc)) (test-reg (fcomp-alloc-reg! fc)))
                                (compile-expr! fc test test-reg #f)
                                (let ((instr (chunk-emit! ch 'TestFalse test-reg 0 0 0)))
                                  (fcomp-reclaim-to! fc mark)
                                  instr)))))
          (if recurse-in-conseq?
              (begin
                (emit-general-recurse-step! fc ch names param-regs prefix call-args loop-start)
                (chunk-patch-jump-to-here! ch jmp-false)
                (compile-expr! fc base-branch dest tail?))
              (begin
                (compile-expr! fc base-branch dest tail?)
                (let ((jmp-end (if tail? #f (chunk-emit! ch 'Jmp 0 0 0 0))))
                  (chunk-patch-jump-to-here! ch jmp-false)
                  (emit-general-recurse-step! fc ch names param-regs prefix call-args loop-start)
                  (if jmp-end (chunk-patch-jump-to-here! ch jmp-end))))))))

    ;; Lowers a recognized general-cond-loop shape (see general-cond-loop-
    ;; shape above): every earlier clause compiles as an ordinary cond exit
    ;; (mirrors compile-cond!'s own per-clause pattern), threading a plain
    ;; list of pending "jump past the loop" instructions to patch once the
    ;; whole loop has been emitted; the final (possibly-guarded) clause
    ;; recurses via emit-general-recurse-step! back to loop-start.
    (define (emit-general-cond-loop! fc shape names param-regs dest tail?)
      (let ((earlier (list-ref shape 0)) (recurse-test (list-ref shape 1))
            (prefix (list-ref shape 2)) (call-args (list-ref shape 3)))
        (let* ((ch (fcomp-chunk fc))
               (loop-start (length (chunk-instrs ch))))
          (let emit-earlier ((clauses earlier) (end-jumps '()))
            (if (null? clauses)
                (begin
                  (if recurse-test
                      (let* ((mark (fcomp-next-reg fc)) (test-reg (fcomp-alloc-reg! fc)))
                        (compile-expr! fc recurse-test test-reg #f)
                        (fcomp-reclaim-to! fc mark)
                        (let ((jmp-false2 (chunk-emit! ch 'TestFalse test-reg 0 0 0)))
                          (emit-general-recurse-step! fc ch names param-regs prefix call-args loop-start)
                          (chunk-patch-jump-to-here! ch jmp-false2)
                          (compile-literal-datum! fc '() dest tail?)))
                      (emit-general-recurse-step! fc ch names param-regs prefix call-args loop-start))
                  (for-each (lambda (j) (chunk-patch-jump-to-here! ch j)) end-jumps))
                (let* ((clause (car clauses)) (test (car clause)) (body (cdr clause))
                       (mark (fcomp-next-reg fc)) (test-reg (fcomp-alloc-reg! fc)))
                  (compile-expr! fc test test-reg #f)
                  (fcomp-reclaim-to! fc mark)
                  (let ((jmp-false (chunk-emit! ch 'TestFalse test-reg 0 0 0)))
                    (compile-scoped-body! fc body dest tail?)
                    (let ((jmp-end (if tail? #f (chunk-emit! ch 'Jmp 0 0 0 0))))
                      (chunk-patch-jump-to-here! ch jmp-false)
                      (emit-earlier (cdr clauses) (if jmp-end (cons jmp-end end-jumps) end-jumps))))))))))

    ;; Shared init-register setup for both general-loop shapes -- mirrors
    ;; compile-counted-loop!'s own opening (fcomp-declare-local! directly
    ;; onto the already-computed init register, no child closure at all).
    (define (compile-general-loop-init! fc names inits shape dest tail? emitter)
      (let* ((init-regs (map (lambda (init) (let ((r (fcomp-alloc-reg! fc))) (compile-expr! fc init r #f) r)) inits)))
        (fcomp-push-scope! fc)
        (for-each (lambda (n r) (fcomp-declare-local! fc n r)) names init-regs)
        (emitter fc shape names init-regs dest tail?)
        (fcomp-pop-scope! fc)))

    ;; Tries general-if-loop-shape first, then general-cond-loop-shape
    ;; (mirrors try_compile_general_loop's own dispatch order) -- #f the
    ;; instant neither matches (no side effects), so compile-named-let!
    ;; can fall back to its existing closure-based path unconditionally.
    (define (try-compile-general-loop! fc loop-name bindings body dest tail?)
      (let* ((names (map car bindings)) (inits (map cadr bindings))
             (if-shape (general-if-loop-shape loop-name names body)))
        (cond
          (if-shape
           (compile-general-loop-init! fc names inits if-shape dest tail? emit-general-loop!)
           #t)
          ((and (= (length body) 1) (pair? (car body)) (eq? (caar body) 'cond))
           (let ((cond-shape (general-cond-loop-shape loop-name names (cdr (car body)))))
             (and cond-shape
                  (begin
                    (compile-general-loop-init! fc names inits cond-shape dest tail? emit-general-cond-loop!)
                    #t))))
          (else #f))))

    ;; (let loop ((n v) ...) body...) -- loop's OWN register is declared
    ;; before its lambda body is compiled, so the lambda can resolve it as an
    ;; upvalue capturing itself (ordinary letrec-style self-reference), then
    ;; it's called immediately with the initial values. Tries the counted-
    ;; loop fast path first (see recognize-counted-loop/compile-counted-
    ;; loop! above), then the general (non-counted) loop fast path (see
    ;; try-compile-general-loop! above) -- falls back unconditionally to the
    ;; closure-based path below the moment both decline.
    (define (compile-named-let! fc loop-name bindings body dest tail?)
      (let ((shape (recognize-counted-loop fc loop-name bindings body)))
        (cond
          (shape (compile-counted-loop! fc shape dest tail?))
          ((try-compile-general-loop! fc loop-name bindings body dest tail?) #t)
          (else
           (let* ((names (map car bindings))
                  (val-exprs (map cadr bindings))
                  (loop-reg (fcomp-alloc-reg! fc)))
             (fcomp-push-scope! fc)
             (fcomp-declare-local! fc loop-name loop-reg)
             (compile-lambda! fc names body loop-reg #f "named-let")
             (let ((arg-regs (map (lambda (v) (fcomp-alloc-reg! fc)) val-exprs)))
               (for-each (lambda (v r) (compile-expr! fc v r #f)) val-exprs arg-regs)
               (fcomp-pop-scope! fc)
               (if tail?
                   (chunk-emit! (fcomp-chunk fc) 'TailCall loop-reg (length val-exprs) 0 0)
                   (chunk-emit! (fcomp-chunk fc) 'Call loop-reg (length val-exprs) dest 0))))))))

    (define (compile-let! fc expr dest tail?)
      (let ((second (cadr expr)))
        (if (symbol? second)
            (compile-named-let! fc second (caddr expr) (cdddr expr) dest tail?)
            (compile-plain-let! fc second (cddr expr) dest tail?))))

    ;; ---------------------------------------------------------------------
    ;; Self-hosted library loader -- needed because `import!` (creme
    ;; bootstrap) is a real, full R7RS loader ONLY under the real Crystal
    ;; interpreter; under cvm it's a permanent no-op (cvm's global table is
    ;; unconditionally flat and everything Crystal/cvm-native is already
    ;; baked into it, per that builtin's own doc comment -- but a PURE-
    ;; SCHEME file-based library like (creme dao)/(creme sxql)/(creme
    ;; html)/etc, never compiled into cvm's own image, genuinely has
    ;; nothing defined for it at all under cvm without this). Implemented
    ;; entirely with primitives this compiler already has (read-whole-
    ;; file, read-program, compile-program, chunk->bytes, load-chunk-
    ;; bytes) rather than any new builtin -- works identically under
    ;; either backend (redundant-but-harmless under Crystal, where
    ;; import! already did the real work; load-bearing under cvm, where it
    ;; does the only real work). Mirrors import.cr's own recursive
    ;; resolve_library/build_library shape (verified against that file
    ;; this session), deliberately narrowed to what a flat-global-
    ;; namespace runtime like cvm needs:
    ;; - only/except don't restrict VISIBILITY -- every top-level binding
    ;;   a library defines (exported or not) still lands in the same flat
    ;;   global table, exactly matching cvm's own already-accepted "no
    ;;   per-import scoping" design; only/except are accepted as a no-op
    ;;   beyond that (confirmed safe for this project's own pure-Scheme
    ;;   libraries -- checked every one app.scm transitively depends on).
    ;;   prefix/rename, though, DO now work: apply-import-set-aliases!
    ;;   (below) additionally defines the prefixed/renamed name as a real
    ;;   alias for the library's own internal binding (resolved against
    ;;   its (export ...) clause, via library-export-alist), so code that
    ;;   uses the name the importer actually asked for isn't left with an
    ;;   unbound-variable error under cvm -- the ORIGINAL unprefixed/
    ;;   un-renamed name also stays visible, for the same flat-namespace
    ;;   reason only/except can't hide anything either.
    ;; - cond-expand/include/include-ci inside a .sld file are NOT
    ;;   supported (none of this project's own pure-Scheme libraries use
    ;;   them in a way this loader would ever see -- checked this session).
    ;; - A library with no .sld file on disk (an ordinary Crystal/cvm-
    ;;   native library, e.g. (creme sql)/(scheme base)) is silently
    ;;   treated as already available -- exactly import!'s own existing
    ;;   assumption for a cvm-native name.
    ;; ---------------------------------------------------------------------

    ;; Process-wide (like macro-table): library names (each a list like
    ;; (creme dao)) this process has already self-host-LOADED (a .sld file
    ;; genuinely existed and its body ran) -- marked before recursing into
    ;; that library's own imports, so a circular import can't loop forever
    ;; (mirrors import.cr's own @libraries_loading guard, just accepting
    ;; silently rather than raising). Deliberately NOT marked for a
    ;; library with no .sld file found (see ensure-library-loaded! below):
    ;; marking unconditionally here used to permanently "poison" a
    ;; library name the first time it was ever seen, even when that
    ;; attempt found nothing -- fatal specifically for a library a
    ;; program GENERATES at run time (e.g. via file-write) and then
    ;; imports: compile-program's own eager, compile-time-only import
    ;; attempt (compile-import!'s own doc comment) necessarily finds
    ;; nothing (the file doesn't exist until an EARLIER form actually
    ;; RUNS), and marking it loaded anyway made the LATER, correctly-
    ;; timed runtime attempt skip loading it for real. Harmless under
    ;; native Crystal (whose own real import! -- unlike cvm's permanent
    ;; no-op -- already does the genuine work independently, making this
    ;; tracking redundant there), but a real, silent failure under cvm,
    ;; where this self-hosted loader is the ONLY mechanism -- confirmed
    ;; by tracing spec/creme/compiler_libraries_spec.scm's own "imports a
    ;; library file written by an earlier form" case failing under `cvm`
    ;; only, never under `--self-hosted`.
    ;;
    ;; mark-self-hosted-library-loaded! is EXPORTED (unlike the other two
    ;; names here) specifically so cvm/compiler-run.scm can pre-seed this
    ;; state for every file-based library IT ITSELF already bundles
    ;; natively (via --emit-cvm, which never touches this tracking at
    ;; all -- it's Crystal's own import machinery, not this self-hosted
    ;; loader). Without that, a target script reentrant-compiled under
    ;; cvm that ALSO imports e.g. (creme compiler compiler)/(creme
    ;; bytecode) -- exactly what every spec/creme/*.scm file does via
    ;; (creme compiler spec-helper) -- would have ensure-library-loaded!
    ;; re-read and re-run those libraries' own source a second time,
    ;; re-executing their define-record-type forms (bytecode.sld's
    ;; <chunk>, this file's own <fcomp>) and creating a NOMINALLY NEW
    ;; record type each time -- corrupting any chunk/fcomp object the
    ;; OUTER, still-in-progress compile-program call (compiling the
    ;; target script itself) was already holding from the ORIGINAL,
    ;; pre-baked generation. Confirmed empirically: this is exactly what
    ;; produced "record accessor: expected a <chunk> record" before this
    ;; export existed.
    (define self-hosted-loaded-libraries '())
    (define (self-hosted-library-loaded? name) (member name self-hosted-loaded-libraries equal?))
    (define (mark-self-hosted-library-loaded! name)
      (set! self-hosted-loaded-libraries (cons name self-hosted-loaded-libraries)))

    ;; Mirrors cvm_emitter.cr's own required_families computation (the
    ;; native --emit-cvm path), just reimplemented here for THIS compiler's
    ;; own self-hosted programs: every library name of the exact shape
    ;; (creme builtin <family>) ever reached by ensure-library-loaded!
    ;; below (which only gets here for a library with no .sld file on
    ;; disk -- i.e. a native/builtin one, see that function's own doc
    ;; comment) is a real, native builtin family the compiled program
    ;; transitively depends on, and is recorded here (deduped) so
    ;; compile-source-to-bytes/compiler-run.scm can pass a REAL required-
    ;; families list into chunk->bytes instead of an empty/hardcoded one --
    ;; letting cvm's own import-gated native builtin registration (main.c)
    ;; work correctly even for a program compiled entirely by THIS
    ;; self-hosted compiler (cvm's "compiler mode"), not just one compiled
    ;; natively via --emit-cvm.
    (define required-native-families '())
    (define (record-required-native-family! name)
      (if (and (= (length name) 3) (eq? (car name) 'creme) (eq? (cadr name) 'builtin))
          (let ((fam (symbol->string (caddr name))))
            (if (not (member fam required-native-families string=?))
                (set! required-native-families (cons fam required-native-families))))))
    (define (required-native-families-list) required-native-families)

    ;; Strips only/except/prefix/rename wrapping down to the bare
    ;; library-name import-set underneath (these all nest one <import-set>
    ;; inside another, per R7RS's own grammar).
    (define (import-set-library-name spec)
      (if (memq (car spec) '(only except prefix rename))
          (import-set-library-name (cadr spec))
          spec))

    ;; name -> ((external . internal) ...), one pair per <export spec> in
    ;; the library's own (export ...) clause (a bare identifier exports
    ;; itself under its own name; (rename internal external) exports
    ;; internal under a different external name) -- used by
    ;; apply-import-set-aliases! below to resolve prefix/rename against
    ;; the names the library ACTUALLY declares exported, not just
    ;; whatever it happens to `define` internally.
    ;;
    ;; For a library with no .sld file on disk (ordinary Crystal/cvm-
    ;; native), falls back to library-exports ((creme introspection)) --
    ;; native Crystal already tracks every registered library's own
    ;; exports internally (SchemeLibrary#exports) regardless of whether
    ;; it came from a .sld file or a Crystal-native installer, so this
    ;; fallback covers a native library too, PROVIDED it's already been
    ;; imported/registered by the time this runs (an as-yet-unimported
    ;; native library has no exports to report any more than an
    ;; unimported file-based one would -- same restriction, just a
    ;; different reason). cvm has its own, much narrower library-exports
    ;; (cvm/bootstrap.c) -- a small hardcoded table, since cvm has no
    ;; per-library grouping of its own flat global table the way native
    ;; Crystal's SchemeLibrary does; see that file's own comment for
    ;; which libraries it actually covers.
    (define (library-export-alist name)
      (let ((src (try-read-whole-file (library-name->path name))))
        (if (not src)
            (guard (e (#t #f)) (library-exports name))
            (let* ((forms (read-program src))
                   (lib-form (car forms))
                   (clauses (cddr lib-form)))
              (let loop ((cs clauses))
                (cond
                  ((null? cs) '())
                  ((and (pair? (car cs)) (eq? (car (car cs)) 'export))
                   (map (lambda (spec)
                          (if (and (pair? spec) (eq? (car spec) 'rename))
                              (cons (caddr spec) (cadr spec))
                              (cons spec spec)))
                        (cdr (car cs))))
                  (else (loop (cdr cs)))))))))

    ;; The FULL (external . internal) binding list a given import-set
    ;; contributes -- unlike import-set-alias-defines above (which only
    ;; computes the handful of EXTRA aliases a prefix/rename import-set
    ;; needs beyond what a plain top-level `(import ...)` already brings
    ;; in via native import!/ensure-libraries-loaded!), this is a
    ;; complete, from-scratch resolution used by `environment`
    ;; (cvm/compiler-run.scm) to populate a genuinely fresh, otherwise-
    ;; empty environment -- there is no ambient "already imported"
    ;; baseline to lean on there, so only/except need REAL filtering
    ;; here (not the no-op passthrough import-set-alias-defines's own
    ;; only/except cases use, which rely on native import! having
    ;; already applied the filter for real at the top level).
    (define (import-set-resolved-bindings spec)
      (cond
        ((eq? (car spec) 'only)
         (let ((inner (import-set-resolved-bindings (cadr spec)))
               (names (cddr spec)))
           (filter (lambda (pair) (memq (car pair) names)) inner)))
        ((eq? (car spec) 'except)
         (let ((inner (import-set-resolved-bindings (cadr spec)))
               (names (cddr spec)))
           (filter (lambda (pair) (not (memq (car pair) names))) inner)))
        ((eq? (car spec) 'prefix)
         (let* ((inner (import-set-resolved-bindings (cadr spec)))
                (prefix-str (symbol->string (caddr spec))))
           (map (lambda (pair)
                  (cons (string->symbol (string-append prefix-str (symbol->string (car pair)))) (cdr pair)))
                inner)))
        ((eq? (car spec) 'rename)
         (let* ((inner (import-set-resolved-bindings (cadr spec)))
                (renames (cddr spec)))
           (map (lambda (pair)
                  (let ((hit (assq (car pair) renames)))
                    (if hit (cons (cadr hit) (cdr pair)) pair)))
                inner)))
        (else (or (library-export-alist spec) '()))))

    ;; #t if `name` already resolves as a global RIGHT NOW (called only at
    ;; compile time, directly from import-set-alias-defines below -- never
    ;; through a native higher-order-procedure callback, see that
    ;; function's own doc comment on why that distinction matters here).
    ;; Used to detect when Crystal's OWN real `import!` (already run for
    ;; real by the time compile-import! gets here) has ALREADY correctly
    ;; bound the requested prefix/rename name -- true for every library
    ;; Crystal can see directly, whether native or file-based, since its
    ;; apply_import_set (library.cr) is a full, correct implementation;
    ;; only a pure-Scheme library loaded SOLELY through this file's own
    ;; self-hosted loader (the cvm case, where import! is a no-op) needs
    ;; import-set-alias-defines to actually generate anything.
    (define (global-bound? name)
      (guard (e (#t #f)) (eval name) #t))

    ;; Returns the list of ordinary (define new old) forms needed to make
    ;; a prefix/rename import-set's requested names resolve to real
    ;; bindings (only/except recurse through with no forms of their own --
    ;; see this section's header comment for why they can't restrict
    ;; visibility in this flat-global-namespace design). Pure data, no
    ;; execution here -- compile-import! below compiles+emits each
    ;; returned form via the EXISTING compile-define!, so the alias
    ;; becomes ordinary compiled bytecode (DefGlobal off an ordinary
    ;; variable-reference read of the original name) running at PROGRAM
    ;; EXECUTION time, same as any other top-level define in the compiled
    ;; chunk. global-bound? (above) still needs a live `eval` to check
    ;; each candidate name at COMPILE time, which only resolves because
    ;; this library's own (import ...) clause now lists (scheme eval) --
    ;; every helper in this section (compile-import!, ensure-library-
    ;; loaded!, etc) runs with root_env = THIS LIBRARY's own private env
    ;; (Crystal's real library system is NOT the flat global namespace
    ;; the self-hosted loader below provides; that flatness is this
    ;; loader's OWN design for cvm, not how Crystal loads (creme compiler
    ;; compiler) itself) -- so any global this file's own procedures call
    ;; must be in ITS OWN import clause, not just the caller's.
    (define (import-set-alias-defines spec)
      (cond
        ((eq? (car spec) 'only) (import-set-alias-defines (cadr spec)))
        ((eq? (car spec) 'except) (import-set-alias-defines (cadr spec)))
        ((eq? (car spec) 'prefix)
         (let* ((inner (cadr spec))
                (prefix-sym (caddr spec))
                (exports (library-export-alist (import-set-library-name inner))))
           (append
             (import-set-alias-defines inner)
             (if exports
                 (let loop ((es exports))
                   (cond
                     ((null? es) '())
                     (else
                      (let ((prefixed (string->symbol (string-append (symbol->string prefix-sym) (symbol->string (car (car es)))))))
                        (if (global-bound? prefixed)
                            (loop (cdr es))
                            (cons (list 'define prefixed (cdr (car es))) (loop (cdr es))))))))
                 '()))))
        ((eq? (car spec) 'rename)
         (let* ((inner (cadr spec))
                (renames (cddr spec))
                (exports (library-export-alist (import-set-library-name inner))))
           (append
             (import-set-alias-defines inner)
             (let loop ((rs renames))
               (cond
                 ((null? rs) '())
                 ((global-bound? (cadr (car rs))) (loop (cdr rs)))
                 (else
                  (let* ((from (car (car rs))) (to (cadr (car rs)))
                         (hit (and exports (assq from exports))))
                    (cons (list 'define to (if hit (cdr hit) from))
                          (loop (cdr rs))))))))))
        ;; A bare library-name import-set (no only/except/prefix/rename
        ;; filter at all) -- e.g. plain `(import (some-lib))`. Genuinely
        ;; distinct gap from the prefix/rename cases above: those exist
        ;; to alias a name the IMPORT-SET itself renames/prefixes, but a
        ;; library can ALSO rename its own export internally (`(export
        ;; (rename internal-add public-add))`), and nothing consumed
        ;; library-export-alist's already-correct (external . internal)
        ;; parsing of that for a bare import at all before this -- so
        ;; `public-add` was never actually bound as a global under cvm's
        ;; self-hosted-loader-only path (native Crystal's own real
        ;; import! already handles this correctly, via global-bound?'s
        ;; same "already handled natively" skip below, which is why this
        ;; gap was invisible under plain ./bin/creme/--self-hosted). Only
        ;; the genuinely-renamed exports need a define here -- a plain
        ;; (name . name) entry needs no alias at all.
        (else
         (let ((exports (library-export-alist spec)))
           (if exports
               (let loop ((es exports))
                 (cond
                   ((null? es) '())
                   ((eq? (car (car es)) (cdr (car es))) (loop (cdr es)))
                   ((global-bound? (car (car es))) (loop (cdr es)))
                   (else (cons (list 'define (car (car es)) (cdr (car es))) (loop (cdr es))))))
               '())))))

    ;; (creme dao) -> "modules/creme/dao.sld" -- mirrors import.cr's own
    ;; File.join(dir, "a/b/c.sld") convention, just against this project's
    ;; one actual search-path entry ("modules") rather than a general list.
    (define (library-name->path name)
      (let loop ((parts name) (acc "modules"))
        (if (null? parts)
            (string-append acc ".sld")
            (loop (cdr parts) (string-append acc "/" (symbol->string (car parts)))))))

    ;; dirname/path-join -- mirrors cvm/compiler-run.scm's own pair
    ;; exactly (that file's own copy resolves the TARGET SCRIPT's own
    ;; top-level `include` forms; this one resolves an `include`/
    ;; `include-ci` declaration nested inside a separately-loaded
    ;; library's own body, see ensure-library-loaded! below -- kept as a
    ;; small separate copy here rather than shared, since the two run in
    ;; different contexts (this compiler vs. that file's own driver) and
    ;; the logic is a few lines either way).
    (define (dirname path)
      (let loop ((i (- (string-length path) 1)))
        (cond
          ((< i 0) "")
          ((char=? (string-ref path i) #\/) (substring path 0 i))
          (else (loop (- i 1))))))

    (define (path-join dir name)
      (if (string=? dir "") name (string-append dir "/" name)))

    (define (library-dirname name) (dirname (library-name->path name)))

    ;; include-ci's own `#!fold-case` contract -- ASCII-only ("(scheme
    ;; char)" isn't imported here, so no string-foldcase to reach for;
    ;; char->integer/integer->char are plain (scheme base)), and folds
    ;; the WHOLE source blindly rather than identifiers only (a real
    ;; #!fold-case reader wouldn't touch a string/char literal's own
    ;; contents) -- an honest simplification, not attempted precisely,
    ;; matching this project's existing house style of narrower-but-
    ;; documented scope cuts elsewhere in this same file.
    (define (ascii-foldcase-string s)
      (list->string
        (map (lambda (c)
               (let ((n (char->integer c)))
                 (if (and (>= n 65) (<= n 90)) (integer->char (+ n 32)) c)))
             (string->list s))))

    ;; #f (rather than letting a missing file abort the whole process --
    ;; cvm_abort/an uncaught SchemeRuntimeError with no active guard here
    ;; would kill the entire run, not just fail this one lookup) when the
    ;; file can't be read -- the signal that `name` is an ordinary
    ;; Crystal/cvm-native library instead, with nothing further to do.
    ;; Deliberately uses read-whole-file (a cvm-only native builtin), NOT
    ;; the genuinely-portable file-read from (creme file) -- under cvm this
    ;; really reads the file, so ensure-library-loaded! actually reentrant-
    ;; compiles a library's own .sld source there (as it always has); under
    ;; native/--self-hosted, read-whole-file is unbound, so the guard below
    ;; always catches that and returns #f, meaning ensure-library-loaded!
    ;; falls back to record-required-native-family! and NEVER reentrant-
    ;; recompiles a library's body there -- relying instead on native's own
    ;; real import having already defined everything for real. That fallback
    ;; is load-bearing: switching this to file-read (which DOES work under
    ;; native/self-hosted once (creme file) is imported) makes self-hosted
    ;; actually attempt to recompile foundational libraries like (scheme
    ;; base) from source for the first time ever -- a previously totally
    ;; unexercised path that breaks even a bare (display ...) call, plus
    ;; corrupts libraries like (creme sxql) whose defmacro transformers
    ;; run at compile time and don't tolerate a second, independent
    ;; reentrant definition of their own helpers. See expand-include-form
    ;; and process-library-clause!'s own include branch below for the
    ;; narrow, deliberate uses of file-read instead.
    (define (try-read-whole-file path)
      (guard (e (#t #f)) (read-whole-file path)))

    (define (ensure-libraries-loaded! import-sets)
      (for-each (lambda (spec) (ensure-library-loaded! (import-set-library-name spec))) import-sets))

    ;; The recursive step: load whatever THIS library itself imports
    ;; first (a library's own top-level body can reference its own
    ;; dependencies' bindings, so those must already exist), then compile
    ;; +run its own (begin ...) body via run-compiled-forms! -- which,
    ;; being just an ordinary call into THIS SAME compiler, registers any
    ;; define-syntax/defmacro the body contains into macro-table exactly
    ;; the same way a textually-local one would (compile-form!'s own
    ;; dispatch does that automatically while compiling the body -- no
    ;; separate pre-scan needed) and defines its ordinary procedures as
    ;; real globals via the usual DefGlobal path. Multiple import/begin
    ;; clauses in one file (R7RS allows repeating either) are handled
    ;; correctly for free -- every clause is processed, in the file's own
    ;; order, by this same for-each.
    ;; One library declaration -- import/begin (as before), plus include/
    ;; include-ci (splices the named file's own top-level forms in,
    ;; treated exactly like a begin clause's own body -- R7RS's own
    ;; wording, "as if they appeared inline in a begin declaration";
    ;; include-ci additionally fold-cases the source first, see ascii-
    ;; foldcase-string's own doc comment) and cond-expand (picks the
    ;; first satisfied clause the SAME way compile-cond-expand! does at
    ;; the expression level, feature-satisfied?, then re-dispatches its
    ;; own declarations through this SAME function -- so a cond-expand
    ;; clause containing import/begin/include/a further nested
    ;; cond-expand all just work, matching R7RS's "splices ... in place"
    ;; wording literally rather than only handling one declaration kind
    ;; inside it). `name` is threaded through only so include/include-ci
    ;; can resolve a relative path against THIS library's own directory.
    (define (process-library-clause! name clause)
      (cond
        ((eq? (car clause) 'import) (ensure-libraries-loaded! (cdr clause)))
        ((eq? (car clause) 'begin) (run-compiled-forms! (cdr clause)))
        ((or (eq? (car clause) 'include) (eq? (car clause) 'include-ci))
         (let ((fold-case? (eq? (car clause) 'include-ci)))
           (for-each
             (lambda (relpath)
               (let ((src (file-read (path-join (library-dirname name) relpath))))
                 (run-compiled-forms! (read-program (if fold-case? (ascii-foldcase-string src) src)))))
             (cdr clause))))
        ((eq? (car clause) 'cond-expand)
         (let loop ((cx-clauses (cdr clause)))
           (if (pair? cx-clauses)
               (if (feature-satisfied? (car (car cx-clauses)))
                   (for-each (lambda (c) (process-library-clause! name c)) (cdr (car cx-clauses)))
                   (loop (cdr cx-clauses))))))
        (else #f)))

    ;; Walks a library's own declarations the SAME way process-library-
    ;; clause! does (import/begin/include/include-ci/cond-expand, cond-
    ;; expand recursing through matched clauses the identical way), but
    ;; purely to COLLECT rather than compile+run: returns (cons specs
    ;; body-forms) -- `specs` the full list of import-sets this library's
    ;; own `import` clauses mention (in file order), `body-forms` its own
    ;; begin-clause forms plus (still-unexpanded) include/include-ci
    ;; clauses, later fully spliced via flatten-begins (which already
    ;; knows how to expand both) once current-compiling-file is pointed
    ;; at this library's own file -- see library-visible-names below, the
    ;; only caller. A parallel traversal (not process-library-clause!
    ;; itself) since that function has side effects (real compiling) this
    ;; one must not trigger a second time.
    (define (library-clause-specs&forms clauses)
      (let loop ((clauses clauses) (specs '()) (forms '()))
        (if (null? clauses)
            (cons (reverse specs) (reverse forms))
            (let ((clause (car clauses)))
              (cond
                ((eq? (car clause) 'import) (loop (cdr clauses) (append (reverse (cdr clause)) specs) forms))
                ((eq? (car clause) 'begin) (loop (cdr clauses) specs (append (reverse (cdr clause)) forms)))
                ((or (eq? (car clause) 'include) (eq? (car clause) 'include-ci))
                 (loop (cdr clauses) specs (cons clause forms)))
                ((eq? (car clause) 'cond-expand)
                 (let scan ((cx-clauses (cdr clause)))
                   (if (pair? cx-clauses)
                       (if (feature-satisfied? (car (car cx-clauses)))
                           (let ((nested (library-clause-specs&forms (cdr (car cx-clauses)))))
                             (loop (cdr clauses) (append (reverse (car nested)) specs) (append (reverse (cdr nested)) forms)))
                           (scan (cdr cx-clauses)))
                       (loop (cdr clauses) specs forms))))
                (else (loop (cdr clauses) specs forms)))))))

    ;; Every name ONE top-level form itself binds as a real global, if
    ;; any -- a dedicated, minimal recognizer (NOT expand-definition-
    ;; form/record-type->define-forms, which desugar define-record-type/
    ;; define-values into an INTERNAL, vector-based fake-record shape for
    ;; hoist-internal-defines' own letrec* folding, and critically don't
    ;; generate a binding for the type name itself -- top-level define-
    ;; record-type genuinely binds ALL of type-name/ctor/pred/accessors/
    ;; mutators as real globals, per cvm/vm.c's build_record_bindings
    ;; "bindings, in the same order: type, ctor, pred, then per field").
    ;; define-syntax/defmacro names are included defensively too (a
    ;; top-level define-syntax genuinely binds a real T_MACRO global,
    ;; per Op::HelperForm kind 3) -- over-including a name here only
    ;; makes this library's own visibility restriction slightly less
    ;; strict, never wrong in the other direction, so when in doubt this
    ;; leans toward including rather than mangling a legitimate own name.
    (define (top-level-form-names form)
      (if (not (pair? form))
          '()
          (cond
            ((eq? (car form) 'define)
             (let ((sig (cadr form))) (list (if (pair? sig) (car sig) sig))))
            ((eq? (car form) 'define-values)
             (let ((parsed (parse-formals (cadr form))))
               (if (cdr parsed) (append (car parsed) (list (cdr parsed))) (car parsed))))
            ((eq? (car form) 'define-record-type)
             (let* ((type-name (cadr form))
                    (ctor-spec (caddr form))
                    (ctor-name (car ctor-spec))
                    (pred-name (cadddr form))
                    (field-specs (cddddr form)))
               (append
                 (list type-name ctor-name pred-name)
                 (apply append
                   (map (lambda (spec) (if (pair? (cddr spec)) (list (cadr spec) (caddr spec)) (list (cadr spec))))
                        field-specs)))))
            ((or (eq? (car form) 'define-syntax) (eq? (car form) 'defmacro))
             (list (cadr form)))
            (else '()))))

    ;; The full (own top-level defines UNION resolved-import external
    ;; names) set current-library-visible-names is bound to while
    ;; compiling `name`'s own body -- see that variable's own doc
    ;; comment, and compile-var-ref!'s global-ref-name, for how it's
    ;; used. Imported names reuse import-set-resolved-bindings (already
    ;; real only/except/prefix/rename resolution, proven by
    ;; `environment`'s own use of it) -- note this only needs each
    ;; dependency's DECLARED export list (library-export-alist, which
    ;; just re-reads a .sld's own `export` clause / the native fallback
    ;; table), not for it to already be loaded, so this can run
    ;; independently of/before ensure-libraries-loaded! actually loads
    ;; any of them.
    (define (library-visible-names name clauses)
      (let* ((collected (library-clause-specs&forms clauses))
             (specs (car collected))
             (saved-file current-compiling-file)
             (own-forms (begin
                          (set! current-compiling-file (library-name->path name))
                          (let ((r (flatten-begins (cdr collected))))
                            (set! current-compiling-file saved-file)
                            r)))
             (own-names (apply append (map top-level-form-names own-forms)))
             (imported-names
               (apply append
                 (map (lambda (spec) (map car (import-set-resolved-bindings spec))) specs))))
        (append own-names imported-names)))

    ;; The recursive step: load whatever THIS library itself imports
    ;; first (a library's own top-level body can reference its own
    ;; dependencies' bindings, so those must already exist), then compile
    ;; +run its own (begin ...) body via run-compiled-forms! -- which,
    ;; being just an ordinary call into THIS SAME compiler, registers any
    ;; define-syntax/defmacro the body contains into macro-table exactly
    ;; the same way a textually-local one would (compile-form!'s own
    ;; dispatch does that automatically while compiling the body -- no
    ;; separate pre-scan needed) and defines its ordinary procedures as
    ;; real globals via the usual DefGlobal path. Multiple import/begin
    ;; clauses in one file (R7RS allows repeating either) are handled
    ;; correctly for free -- every clause is processed, in the file's own
    ;; order, by this same for-each.
    ;; A name with no .sld file on disk is only ever legitimate here as a
    ;; native-builtin pseudo-library of the (creme builtin <family>)
    ;; shape (every real (scheme ...)/(creme ...) library this project
    ;; ships DOES have a real .sld wrapper file -- these innermost names
    ;; are what such a wrapper itself imports, see record-required-
    ;; native-family!'s own matching shape check above). Deliberately NOT
    ;; using library-export-alist's native fallback to decide "is this
    ;; real" here -- cvm's own library-exports builtin (cvm/bootstrap.c)
    ;; is a small, hand-maintained table covering only the one native
    ;; library a spec actually needs only/except/prefix/rename against
    ;; ((creme regex) today), NOT a general "does this native family
    ;; exist" oracle -- treating its #f as "unknown" would wrongly reject
    ;; almost every real (creme builtin <family>) name.
    ;; Only meaningful under cvm, where read-whole-file (try-read-whole-
    ;; file's own probe) is a genuine builtin -- there, "no src" reliably
    ;; means "no .sld file exists on disk for this name" (global-bound?
    ;; 'read-whole-file is how we tell we're actually running there).
    ;; Under native/--self-hosted, read-whole-file is ALWAYS unbound
    ;; regardless of whether a real .sld exists (that's the whole point
    ;; of the try-read-whole-file/file-read split above) -- so "no src"
    ;; there carries no information about whether `name` is real, and
    ;; this check must never fire, or it would reject perfectly ordinary
    ;; libraries like (scheme base) that should-match-native?/differential
    ;; specs compile reentrant under native (e.g. compiler_libraries_spec.scm).
    (define (unknown-native-library-name? name)
      (and (global-bound? 'read-whole-file)
           (not (and (pair? name) (= (length name) 3) (eq? (car name) 'creme) (eq? (cadr name) 'builtin)))))

    (define (ensure-library-loaded! name)
      (if (not (self-hosted-library-loaded? name))
          (let ((src (try-read-whole-file (library-name->path name))))
            (if src
                (begin
                  ;; Marked here, AFTER confirming real source exists but
                  ;; BEFORE recursing into ITS OWN imports below -- still
                  ;; prevents infinite recursion on a genuine circular
                  ;; import, without poisoning a name whose file didn't
                  ;; exist yet (see this variable's own doc comment above).
                  (mark-self-hosted-library-loaded! name)
                  (let* ((forms (read-program src))
                         (lib-form (car forms))
                         (clauses (cddr lib-form)))
                    ;; current-library-visible-names/mangle-prefix and the
                    ;; fused-prim exclusion (mark-redefined!, the same
                    ;; mechanism eval's own except/only fix uses) are all
                    ;; scoped to compiling THIS library's own clauses --
                    ;; dynamic-wind-protected so a mid-library compile
                    ;; error can't leave fusion permanently disabled for
                    ;; names this library merely happened to exclude.
                    (let* ((visible (library-visible-names name clauses))
                           (excluded-fusable
                             (let loop ((ns fusable-prim-names))
                               (cond
                                 ((null? ns) '())
                                 ((memq (car ns) visible) (loop (cdr ns)))
                                 (else (cons (car ns) (loop (cdr ns)))))))
                           (saved-visible current-library-visible-names)
                           (saved-prefix current-library-mangle-prefix))
                      (dynamic-wind
                        (lambda ()
                          (set! current-library-visible-names visible)
                          (set! current-library-mangle-prefix (library-name->path name))
                          (for-each mark-redefined! excluded-fusable))
                        (lambda ()
                          (for-each (lambda (clause) (process-library-clause! name clause)) clauses))
                        (lambda ()
                          (set! current-library-visible-names saved-visible)
                          (set! current-library-mangle-prefix saved-prefix)
                          (for-each unmark-redefined! excluded-fusable))))))
                (if (unknown-native-library-name? name)
                    (error "import: unknown library" name)
                    (record-required-native-family! name))))))

    ;; (import spec ...) -- top level only, same restriction the real
    ;; compiler enforces. Desugars into an ordinary call to (creme
    ;; bootstrap)'s `import!` builtin (added specifically for this),
    ;; quoting the import-sets as literal data -- (creme bytecode)'s
    ;; write-datum! already serializes arbitrary symbol/pair/nil
    ;; structure, so no new bytecode logic is needed here, matching the
    ;; desugaring pattern case/do/define-record-type already use.
    ;;
    ;; ALSO runs the import for real, immediately, right here at compile
    ;; time (matching what the real compiler must do for exactly this
    ;; reason) -- the whole program is compiled in one static pass
    ;; before any of it runs, so a later form's target-env-macro-expand
    ;; check (compile-form! above) can only see an imported library's
    ;; Macro/SchemeSyntaxRules exports if the import already actually
    ;; happened against the SAME env that check consults (interp.global
    ;; -- see (creme bootstrap)'s expand-if-macro). ALSO runs the
    ;; self-hosted loader above, for the same reason -- load-bearing
    ;; under cvm (see this section's own header comment), redundant but
    ;; harmless under Crystal (import! already did the real work there).
    ;; Both emitted runtime calls are still there too, so a separately
    ;; reloaded chunk still works standalone without needing to be
    ;; recompiled in the same process that originally compiled it --
    ;; PROVIDED that process still has this same compiler's own
    ;; ensure-libraries-loaded! defined as a global (true for cvm's own
    ;; compiler-mode/REPL images, which always bundle this whole file).
    ;; import-set-alias-defines for every spec in one (import ...) form,
    ;; in order -- manual recursion (not map), matching this section's own
    ;; care about avoiding any reentrant-native-higher-order-procedure call
    ;; path here (see import-set-alias-defines's own doc comment); this
    ;; one is a perfectly ordinary compile-time helper call, not itself
    ;; suspected of the same issue, but there's no reason to take the risk
    ;; over a rarely-hot loop like this.
    (define (alias-defines-for-specs specs)
      (if (null? specs)
          '()
          (append (import-set-alias-defines (car specs)) (alias-defines-for-specs (cdr specs)))))

    ;; Runtime counterpart of alias-defines-for-specs above, for `import!`
    ;; called as a BARE PROCEDURE (e.g. `(import! '((prefix (creme regex)
    ;; rx:)))` directly in a test, not through the `(import ...)` special
    ;; form compile-import! below handles) -- cvm/bootstrap.c's bi_import_
    ;; bang bridges here (same pattern as expand-if-macro bridging to
    ;; defmacro-expand-form/define-syntax-expand-form) since cvm's own
    ;; import! has no compiler context of its own to emit bytecode from.
    ;; Reuses alias-defines-for-specs' pure computation of the `(define
    ;; new old)` forms needed, then genuinely executes each one via `eval`
    ;; (this library's own top-level (import (scheme eval)) makes that
    ;; resolve; under cvm, whatever global `eval` compiler-run.scm itself
    ;; defines) -- safe to do here specifically because bi_import_bang is
    ;; ONLY ever reached for a bare runtime call, never for the special-
    ;; form path below (compile-import! never emits a call to THIS
    ;; procedure), so there's no risk of the ordering bug that caused this
    ;; same idea to be reverted before compile-import!'s own emission
    ;; order was fixed (see that function's own comment).
    (define (import!-apply-aliases! import-sets)
      (for-each eval (alias-defines-for-specs import-sets)))

    ;; The eager compile-time ensure-libraries-loaded! + import! calls
    ;; below exist ONLY so a LATER top-level form's macro use (via
    ;; target-env-macro-expand) can already see this import's exports --
    ;; this compiler compiles a whole program in one pass before any of
    ;; it runs (see compile-source-to-bytes), so without this, an import
    ;; textually followed by a macro use from it would never resolve. But
    ;; that means a program which WRITES a library file at run time (an
    ;; earlier ordinary form, e.g. file-write) and then imports it can
    ;; never satisfy this eager check -- the file genuinely doesn't exist
    ;; yet at COMPILE time, since the form that creates it hasn't RUN yet.
    ;; Rather than aborting the whole compile over that (a real bug this
    ;; project's own Phase C differential sweep against 26-import-
    ;; generated-library.scm found), swallow the failure here: the
    ;; runtime call to the SAME two procedures, already unconditionally
    ;; emitted below into the compiled program itself, still runs the
    ;; real import at the CORRECT time (after every earlier form has
    ;; actually executed, exactly like native Crystal's own per-form
    ;; analyze-compile-run loop achieves for free) -- this just means an
    ;; import of a not-yet-existing library can't ALSO satisfy a later
    ;; macro use in the same program (an edge case rare enough, and
    ;; already unusual enough -- generating a LIBRARY that exports a
    ;; MACRO at run time and using it in the same program -- to accept).
    ;;
    ;; ensure-libraries-loaded! now runs BEFORE import! (both here and in
    ;; the emitted runtime sequence below) -- ordering that USED to not
    ;; matter (native Crystal's own import! is fully independent of this
    ;; self-hosted loader), but does now that cvm's own import! (bi_
    ;; import_bang, cvm/bootstrap.c) bridges to import!-apply-aliases!
    ;; above: a pure-Scheme library's exports (e.g. (creme extra)'s
    ;; `filter`, aliased via a prefix import-set) must already be real
    ;; globals -- which only ensure-libraries-loaded! (not import!, a
    ;; permanent no-op at cvm's OWN runtime level) establishes -- before
    ;; the alias-generation bridge tries to resolve them. Getting this
    ;; backwards previously broke compiler_libraries_spec.scm's prefix-
    ;; import case ("unbound variable: any") when this bridge was first
    ;; attempted; this reordering is the fix that makes it safe.
    (define (compile-import! fc expr dest tail?)
      (if (fcomp-parent fc)
          (error "bootstrap compiler: import is only supported at the top level" expr)
          (begin
            (guard (e (#t #f)) (ensure-libraries-loaded! (cdr expr)) (import! (cdr expr)))
            (compile-expr! fc
              (cons 'begin
                    (append
                      (list
                        (list 'ensure-libraries-loaded! (list 'quote (cdr expr)))
                        (list 'import! (list 'quote (cdr expr))))
                      (alias-defines-for-specs (cdr expr))))
              dest tail?))))

    ;; Shared by compile-define!/compile-define-values! -- emits DefGlobal
    ;; and records the redefinition for the primitive-fusion gate (see
    ;; mark-redefined!, defined alongside the fusion machinery further down;
    ;; forward reference is fine, nothing here runs until the whole library
    ;; body has finished loading).
    (define (defglobal! ch name reg)
      (chunk-emit! ch 'DefGlobal (chunk-add-const! ch name) reg 0 0)
      (mark-redefined! name))

    ;; Top level only -- (define name val) and (define (f . params) body...)
    ;; sugar. Internal (nested) defines are hoisted before they ever reach
    ;; here (see compile-scoped-body!); this errors loudly instead of
    ;; silently miscompiling one if it's ever encountered directly.
    ;; (define ...)'s own "value" is the defined NAME (as a symbol), not
    ;; whatever it was defined to -- mirrors bytecode_compiler.cr's own
    ;; DefineNode handling exactly (emit_load_literal(fc, dst, SchemeSym.
    ;; of(node.name)) unconditionally after the DefGlobal/Move, regardless
    ;; of top-level vs internal or tail vs non-tail). Only actually
    ;; observable when a define is used in a position whose value is read
    ;; -- e.g. the last top-level form of a program -- but must still
    ;; match: previously this loaded val-reg (the defined VALUE) into
    ;; dest instead, a real divergence from native caught by comparing
    ;; disassembled bytecode for the same source against both compilers.
    (define (compile-define! fc expr dest tail?)
      (if (fcomp-parent fc)
          (error "bootstrap compiler: internal (define ...) is not yet supported" expr)
          (let* ((sig (cadr expr))
                 (name (if (pair? sig) (car sig) sig))
                 (val-expr (if (pair? sig) (cons 'lambda (cons (cdr sig) (cddr expr))) (caddr expr)))
                 (ch (fcomp-chunk fc))
                 (val-reg (fcomp-alloc-reg! fc)))
            ;; (define f (lambda ...)) / (define (f ...) ...) sugar -- name
            ;; the closure after its own binding (mirrors bytecode_
            ;; compiler.cr's analyzer.cr renaming an anonymous LambdaNode
            ;; to its define target's name), calling compile-lambda!
            ;; directly rather than through the generic compile-expr!
            ;; 'lambda dispatch, which always hardcodes "lambda" as the
            ;; proc-name -- try-compile-global-counted-loop! needs the REAL
            ;; name to recognize a self-recursive tail call back to it.
            (if (and (pair? val-expr) (eq? (car val-expr) 'lambda))
                (compile-lambda! fc (cadr val-expr) (cddr val-expr) val-reg #f (symbol->string name))
                (compile-expr! fc val-expr val-reg #f))
            (defglobal! ch name val-reg)
            (compile-literal-datum! fc name dest tail?))))

    (define (list-index-of lst x)
      (let loop ((l lst) (i 0))
        (cond
          ((null? l) (error "bootstrap compiler: define-record-type field not found" x))
          ((eq? (car l) x) i)
          (else (loop (cdr l) (+ i 1))))))

    ;; Used ONLY by the internal-define hoisting expansion below (hoist-
    ;; internal-defines/expand-definition-form) for an INTERNAL (non-top-
    ;; level) define-record-type -- top-level define-record-type instead
    ;; produces a genuine record now (see compile-define-record-type!
    ;; below), but a record introduced this way still needs to become a
    ;; letrec* BINDING (a simple name/init-expr pair), which a real
    ;; SchemeRecordType/SchemeRecord's own runtime construction has no
    ;; equivalent for in this compiler's letrec* machinery -- so this is a
    ;; real, narrower remaining gap: an internal define-record-type's
    ;; "record" is still just a vector tagged with the type name symbol at
    ;; index 0, fields at 1.. in the order their (field accessor
    ;; [mutator]) specs appear in the form (NOT necessarily the
    ;; constructor's own parameter order, which R7RS allows to be any
    ;; subset/order of the declared fields) -- vector? on it wrongly
    ;; returns #t, and it won't equal?/display like a top-level record of
    ;; the same shape would. Returns a list of ordinary (define ...)
    ;; forms, folded into the enclosing letrec* the same as any other
    ;; internal define.
    (define (record-type->define-forms expr)
      (let* ((tag (cadr expr))
             (ctor-spec (caddr expr))
             (ctor-name (car ctor-spec))
             (ctor-fields (cdr ctor-spec))
             (pred-name (cadddr expr))
             (field-specs (cddddr expr))
             (all-fields (map car field-specs))
             (total-size (+ 1 (length all-fields)))
             (field-index (lambda (name) (+ 1 (list-index-of all-fields name)))))
        (append
          (list
            (list 'define (cons ctor-name ctor-fields)
                  (append
                    (list 'let (list (list 'r (list 'make-vector total-size #f))))
                    (list (list 'vector-set! 'r 0 (list 'quote tag)))
                    (map (lambda (f) (list 'vector-set! 'r (field-index f) f)) ctor-fields)
                    (list 'r)))
            (list 'define (list pred-name 'v)
                  (list 'and (list 'vector? 'v) (list '= (list 'vector-length 'v) total-size) (list 'eq? (list 'vector-ref 'v 0) (list 'quote tag)))))
          (apply append
            (map
              (lambda (spec)
                (let* ((name (car spec))
                       (idx (field-index name))
                       (accessor (cadr spec))
                       (mutator (if (pair? (cddr spec)) (caddr spec) #f)))
                  (if mutator
                      (list (list 'define (list accessor 'v) (list 'vector-ref 'v idx))
                            (list 'define (list mutator 'v 'val) (list 'vector-set! 'v idx 'val)))
                      (list (list 'define (list accessor 'v) (list 'vector-ref 'v idx))))))
              field-specs)))))

    ;; Top level only -- internal define-record-type is expanded away
    ;; before it ever reaches here into record-type->define-forms's
    ;; tagged-vector desugaring above, see hoist-internal-defines/expand-
    ;; definition-form; this guard is a safety net for the rare non-body
    ;; position (e.g. inside an expression-level begin) that also isn't
    ;; hoisted, matching plain (define ...)'s own compile-define! guard.
    ;;
    ;; Emits Op::HelperForm (kind 2), the SAME opcode Crystal's own
    ;; bytecode_compiler.cr emits for a top-level define-record-type
    ;; (compile_helper_form's DefineRecordType branch, HelperForm::
    ;; DefineRecordType -> kind 2) -- the raw form is stored as a chunk
    ;; constant and handed to Interpreter#eval_define_record_type at run
    ;; time (src/creme/eval/record.cr), which defines a genuine
    ;; SchemeRecordType/SchemeRecord directly into the global env: real
    ;; record identity (vector? is #f, equal?/display match a type/field
    ;; shape rather than a vector's), identical to what Crystal's own
    ;; compiler produces for the same source -- no bespoke vector-based
    ;; desugaring needed for this, the common, case at all.
    (define (compile-define-record-type! fc expr dest tail?)
      (if (fcomp-parent fc)
          (error "bootstrap compiler: internal define-record-type is not yet supported" expr)
          (let* ((ch (fcomp-chunk fc))
                 (form-idx (chunk-add-const! ch expr)))
            (chunk-emit! ch 'HelperForm dest form-idx 2 0)
            (if tail? (chunk-emit! ch 'Return dest 0 0 0)))))

    ;; Optional 2nd argument: the file `forms` was read from, letting a
    ;; NESTED `(include ...)` inside a body (flatten-begins/expand-
    ;; include-form, above) resolve a relative path against ITS own
    ;; directory. Saved/restored around the whole compile (not just set
    ;; unconditionally) since compile-program can be called reentrantly
    ;; while an OUTER compile-program call is still in progress
    ;; (ensure-library-loaded!'s own run-compiled-forms!, triggered from
    ;; compile-import!'s eager compile-time execution of an `(import
    ;; ...)` form partway through the outer program's own body) -- without
    ;; the restore, the OUTER file's own current-compiling-file would
    ;; stay clobbered with the library's path for the rest of that outer
    ;; compile. Omitting the argument entirely (existing 1-arg callers,
    ;; e.g. `eval`'s one-off single-form compiles) leaves whatever
    ;; current-compiling-file already was untouched.
    (define (compile-program forms . file)
      (let* ((saved current-compiling-file)
             (ch (make-chunk "program"))
             (fc (make-fcomp ch #f)))
        (if (not (null? file)) (set! current-compiling-file (car file)))
        (compile-body! fc forms (fcomp-alloc-reg! fc) #t)
        (set! current-compiling-file saved)
        ch))

    ;; Public entry point: compiles every top-level form in `source` (via
    ;; (creme compiler reader)'s read-program) into SCB1 bytes -- a
    ;; bytevector ready for (creme bootstrap)'s load-chunk-bytes. Optional
    ;; 2nd argument: see compile-program's own doc comment.
    (define (compile-source-to-bytes source . file)
      (chunk->bytes
        (if (null? file)
            (compile-program (read-program source))
            (compile-program (read-program source) (car file)))
        (required-native-families-list)))))
