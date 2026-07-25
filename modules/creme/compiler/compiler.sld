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
;; Scope: unlike the real BytecodeCompiler (src/scheme/compile/
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
  (export compile-source-to-bytes compile-program ensure-libraries-loaded!)
  (import (scheme base) (scheme cxr) (scheme inexact) (scheme complex) (scheme eval)
          (creme bytecode) (creme bootstrap) (creme compiler reader))
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
         (let ((rest (parse-formals (cdr formals))))
           (cons (cons (car formals) (car rest)) (cdr rest))))
        (else (error "bootstrap compiler: bad formals" formals))))

    (define (finish-tail! fc dest tail?)
      (if tail? (chunk-emit! (fcomp-chunk fc) 'Return dest 0 0 0))
      dest)

    (define (compile-literal-datum! fc datum dest tail?)
      (chunk-emit! (fcomp-chunk fc) 'LoadK dest (chunk-add-const! (fcomp-chunk fc) datum) 0 0)
      (finish-tail! fc dest tail?))

    (define (compile-var-ref! fc name dest tail?)
      (let ((local (fcomp-lookup-local fc name)))
        (cond
          (local
           (chunk-emit! (fcomp-chunk fc) 'Move dest local 0 0)
           (finish-tail! fc dest tail?))
          (else
           (let ((up (fcomp-resolve-upvalue! fc name)))
             (cond
               (up
                (chunk-emit! (fcomp-chunk fc) 'GetUpval dest up 0 0)
                (finish-tail! fc dest tail?))
               (else
                (chunk-emit! (fcomp-chunk fc) 'GetGlobal dest (chunk-add-const! (fcomp-chunk fc) name) 0 0)
                (finish-tail! fc dest tail?))))))))

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
    (define (run-compiled-forms! forms)
      (load-chunk-bytes (chunk->bytes (compile-program forms))))

    ;; define-syntax's own "value" is unspecified, same convention as
    ;; define/set!: nothing reads a non-tail define-syntax's dest.
    (define (compile-define-syntax! fc expr dest tail?)
      (let* ((name (cadr expr))
             (sr-form (caddr expr)))
        (if (not (eq? (car sr-form) 'syntax-rules))
            (error "bootstrap compiler: only (syntax-rules ...) transformers are supported in define-syntax" expr)
            (macro-register! name (sr-make-transformer (cadr sr-form) (cddr sr-form))))
        (if tail? (compile-literal-datum! fc '() dest #t))))

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
    (define (compile-defmacro! fc expr dest tail?)
      (let* ((name (cadr expr))
             (parsed (parse-formals (caddr expr)))
             (fixed (car parsed))
             (rest (cdr parsed))
             (body (cdddr expr)))
        (macro-register! name
          (lambda (form)
            (let* ((args (cdr form))
                   (n (length fixed))
                   (fixed-args (sr-list-take args n))
                   (rest-args (sr-list-drop args n))
                   (fixed-bindings (map (lambda (p a) (list p (list 'quote a))) fixed fixed-args))
                   (rest-binding (if rest (list (list rest (list 'quote rest-args))) '())))
              (run-compiled-forms! (list (cons 'let (cons (append fixed-bindings rest-binding) body)))))))
        (if tail? (compile-literal-datum! fc '() dest #t))))

    ;; let-syntax/letrec-syntax -- treated identically (macro-table lookup
    ;; is global regardless of registration order, so there's no observable
    ;; difference between "these macros can see each other" and "they
    ;; can't" the way there would be for letrec vs let with real values).
    ;; Scoped by saving/restoring the WHOLE macro-table snapshot around the
    ;; body, rather than un-registering just these names afterward, so
    ;; shadowing an outer macro of the same name also un-shadows correctly
    ;; once the body's done. Simplification: a define-syntax textually
    ;; nested inside the body that's meant to escape this scope (unusual)
    ;; would also get discarded by the restore -- rare enough to accept.
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

    (define (compile-form! fc expr dest tail?)
      (let ((head (car expr)))
        (cond
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
          ((macro-lookup head) => (lambda (transformer) (compile-expr! fc (transformer expr) dest tail?)))
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
    (define (flatten-begins forms)
      (cond
        ((null? forms) '())
        ((and (pair? (car forms)) (eq? (car (car forms)) 'begin))
         (append (flatten-begins (cdr (car forms))) (flatten-begins (cdr forms))))
        (else (cons (car forms) (flatten-begins (cdr forms))))))

    (define (partition-defines forms)
      (if (null? forms)
          (cons '() '())
          (let ((rest (partition-defines (cdr forms))))
            (if (and (pair? (car forms)) (eq? (car (car forms)) 'define))
                (cons (cons (car forms) (car rest)) (cdr rest))
                (cons (car rest) (cons (car forms) (cdr rest)))))))

    (define (define-form->letrec-binding d)
      (let* ((sig (cadr d))
             (name (if (pair? sig) (car sig) sig))
             (val-expr (if (pair? sig) (cons 'lambda (cons (cdr sig) (cddr d))) (caddr d))))
        (list name val-expr)))

    ;; Internal define-values desugars into a hidden temp holding the
    ;; multi-value result as a list (call-with-values + the `list`
    ;; procedure), followed by one ordinary (define name (list-ref/-tail
    ;; tmp i)) per formal -- reusing the exact plain-define shape
    ;; hoist-internal-defines/define-form->letrec-binding already knows how
    ;; to fold into a letrec* binding (whose sequential-evaluation
    ;; semantics, see compile-letrec!, guarantee the temp is assigned
    ;; before any derived binding reads it). Top-level define-values keeps
    ;; its own existing Destructure-based compile-define-values! --
    ;; unrelated to this, only used for the internal/hoisted case.
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

    (define (hoist-internal-defines forms)
      (let* ((flat (flatten-begins (map expand-definition-form (flatten-begins forms))))
             (parts (partition-defines flat))
             (defines (car parts))
             (rest (cdr parts)))
        (if (null? defines)
            forms
            (list (cons 'letrec* (cons (map define-form->letrec-binding defines)
                                        (if (null? rest) (list (list 'quote '())) rest)))))))

    (define (compile-scoped-body! fc forms dest tail?)
      (compile-body! fc (hoist-internal-defines forms) dest tail?))

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
                         (up-idx (and up-op (leaf-expr? arg1) (upvalue-operand fc arg2)))
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
                              (let* ((r1 (compile-arg! fc arg1 (leaf-expr? arg2)))
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

    ;; case -- desugars into (let ((k key-expr)) (cond ((memv k '(d ...)) body...) ... (else body...))),
    ;; compiled via the EXISTING compile-let!/compile-cond!, not new bytecode logic.
    (define (case-clause->cond-clause k-sym clause)
      (if (eq? (car clause) 'else)
          clause
          (cons (list 'memv k-sym (list 'quote (car clause))) (cdr clause))))

    (define (compile-case! fc expr dest tail?)
      (let* ((key-expr (cadr expr))
             (clauses (cddr expr))
             (k-sym (fresh-symbol! "case-key-"))
             (cond-clauses (map (lambda (c) (case-clause->cond-clause k-sym c)) clauses)))
        (compile-expr! fc (list 'let (list (list k-sym key-expr)) (cons 'cond cond-clauses)) dest tail?)))

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
    ;; small, honestly-hardcoded feature set is recognized (this compiler
    ;; has no library registry to query the way the real analyzer does) --
    ;; (library ...) requirements are conservatively treated as unsatisfied
    ;; rather than guessed at.
    (define cond-expand-known-features (list 'else 'r7rs 'creme 'creme.cr))

    (define (feature-satisfied? req)
      (cond
        ((symbol? req) (and (memq req cond-expand-known-features) #t))
        ((eq? (car req) 'and) (sr-all? feature-satisfied? (cdr req)))
        ((eq? (car req) 'or) (sr-any? feature-satisfied? (cdr req)))
        ((eq? (car req) 'not) (not (feature-satisfied? (cadr req))))
        ((eq? (car req) 'library) #f)
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
        (compile-scoped-body! child-fc body-forms (fcomp-alloc-reg! child-fc) #t)
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
    ;; table (src/scheme/compile/ast.cr) and its analyze_app fusion gate
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

    ;; Side-effect-free expression -- bare variable reference or
    ;; self-evaluating literal (mirrors leaf_node?'s base cases; recursing
    ;; into a nested fusable-prim-call the way the real leaf_node? does for
    ;; PrimCallNode is an optional refinement not needed for the core win).
    (define (leaf-expr? expr)
      (or (symbol? expr)
          (number? expr) (string? expr) (char? expr) (boolean? expr) (vector? expr) (bytevector? expr)
          (and (pair? expr) (eq? (car expr) 'quote))))

    ;; A candidate operand resolves to an upvalue iff it's a bare symbol,
    ;; NOT shadowed by a local in the CURRENT function (checked first, same
    ;; order compile-var-ref! uses -- calling fcomp-resolve-upvalue!
    ;; directly without this check would incorrectly walk into an
    ;; enclosing function's scope for a name that's actually locally
    ;; shadowed here), and fcomp-resolve-upvalue! succeeds.
    (define (upvalue-operand fc expr)
      (and (symbol? expr) (not (fcomp-lookup-local fc expr)) (fcomp-resolve-upvalue! fc expr)))

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
               (up2-idx (and up2-op (leaf-expr? arg1) (upvalue-operand fc arg2)))
               (up1-op (and (not imm-val) (not up2-idx) (op-table-lookup 'up1 op)))
               (up1-idx (and up1-op (leaf-expr? arg2) (upvalue-operand fc arg1))))
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
             (let* ((r1 (compile-arg! fc arg1 (leaf-expr? arg2)))
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
               (up-idx (and up-op (leaf-expr? idx-expr) (leaf-expr? val-expr) (upvalue-operand fc obj-expr))))
          (cond
            (imm-val
             (let* ((obj-reg (compile-arg! fc obj-expr (leaf-expr? val-expr)))
                    (val-reg (compile-arg! fc val-expr #t)))
               (chunk-emit! ch imm-op obj-reg imm-val val-reg 0)
               (if (not (= dest obj-reg)) (chunk-emit! ch 'Move dest obj-reg 0 0))
               (if tail? (chunk-emit! ch 'Return dest 0 0 0))))
            (up-idx
             (let* ((idx-reg (compile-arg! fc idx-expr (leaf-expr? val-expr)))
                    (val-reg (compile-arg! fc val-expr #t)))
               (chunk-emit! ch up-op up-idx idx-reg val-reg dest)
               (if tail? (chunk-emit! ch 'Return dest 0 0 0))))
            (else
             (let* ((obj-reg (compile-arg! fc obj-expr (and (leaf-expr? idx-expr) (leaf-expr? val-expr))))
                    (idx-reg (compile-arg! fc idx-expr (leaf-expr? val-expr)))
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
          (else (cons 'global (chunk-add-const! (fcomp-chunk fc) name))))))

    (define (call-op-for kind tail?)
      (cond
        ((eq? kind 'local) (if tail? 'TailCallLocal 'CallLocal))
        ((eq? kind 'upvalue) (if tail? 'TailCallUpval 'CallUpval))
        (else (if tail? 'TailCallGlobal 'CallGlobal))))

    (define (every-leaf? exprs)
      (let loop ((es exprs)) (or (null? es) (and (leaf-expr? (car es)) (loop (cdr es))))))

    ;; Bumps fcomp-next-reg up to (at least) n WITHOUT touching any register
    ;; below it -- a no-op whenever this function already has n or more
    ;; registers in use (the common case: a recursive function's own tail
    ;; call typically has at least as many locals as it has arguments
    ;; already). Ensures any register allocated AFTER this call is
    ;; guaranteed >= n, so it can never alias target registers 0..n-1.
    (define (fcomp-ensure-next-reg! fc n)
      (let loop () (if (< (fcomp-next-reg fc) n) (begin (fcomp-alloc-reg! fc) (loop)))))

    ;; Is `expr` a bare symbol whose CURRENT local register is exactly
    ;; `reg`? The only way a leaf argument's own expression can "read"
    ;; a specific register -- a self-evaluating literal never does.
    (define (arg-reads-register? fc expr reg)
      (and (symbol? expr) (eqv? (fcomp-lookup-local fc expr) reg)))

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
              (if (and tail? (every-leaf? arg-exprs) (fast-tail-args-safe? fc nargs))
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

    ;; (let loop ((n v) ...) body...) -- loop's OWN register is declared
    ;; before its lambda body is compiled, so the lambda can resolve it as an
    ;; upvalue capturing itself (ordinary letrec-style self-reference), then
    ;; it's called immediately with the initial values.
    (define (compile-named-let! fc loop-name bindings body dest tail?)
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
              (chunk-emit! (fcomp-chunk fc) 'Call loop-reg (length val-exprs) dest 0)))))

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
    ;; (creme dao)) this process has already attempted to self-host-load,
    ;; whether or not a .sld file actually existed for it -- marked BEFORE
    ;; recursing into that library's own imports, so a circular import
    ;; can't loop forever (mirrors import.cr's own @libraries_loading
    ;; guard, just accepting silently rather than raising).
    (define self-hosted-loaded-libraries '())
    (define (self-hosted-library-loaded? name) (member name self-hosted-loaded-libraries equal?))
    (define (mark-self-hosted-library-loaded! name)
      (set! self-hosted-loaded-libraries (cons name self-hosted-loaded-libraries)))

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
    ;; whatever it happens to `define` internally. #f for a library with
    ;; no .sld file on disk (ordinary Crystal/cvm-native, no export list
    ;; this Scheme-level code can see -- same restriction as everywhere
    ;; else in this section).
    (define (library-export-alist name)
      (let ((src (try-read-whole-file (library-name->path name))))
        (if (not src)
            #f
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
        (else '())))

    ;; (creme dao) -> "modules/creme/dao.sld" -- mirrors import.cr's own
    ;; File.join(dir, "a/b/c.sld") convention, just against this project's
    ;; one actual search-path entry ("modules") rather than a general list.
    (define (library-name->path name)
      (let loop ((parts name) (acc "modules"))
        (if (null? parts)
            (string-append acc ".sld")
            (loop (cdr parts) (string-append acc "/" (symbol->string (car parts)))))))

    ;; #f (rather than letting a missing file abort the whole process --
    ;; cvm_abort/an uncaught SchemeRuntimeError with no active guard here
    ;; would kill the entire run, not just fail this one lookup) when the
    ;; file can't be read -- the signal that `name` is an ordinary
    ;; Crystal/cvm-native library instead, with nothing further to do.
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
    (define (ensure-library-loaded! name)
      (if (not (self-hosted-library-loaded? name))
          (begin
            (mark-self-hosted-library-loaded! name)
            (let ((src (try-read-whole-file (library-name->path name))))
              (if src
                  (let* ((forms (read-program src))
                         (lib-form (car forms))
                         (clauses (cddr lib-form)))
                    (for-each
                      (lambda (clause)
                        (cond
                          ((eq? (car clause) 'import) (ensure-libraries-loaded! (cdr clause)))
                          ((eq? (car clause) 'begin) (run-compiled-forms! (cdr clause)))
                          (else #f)))
                      clauses))
                  #f)))))

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

    (define (compile-import! fc expr dest tail?)
      (if (fcomp-parent fc)
          (error "bootstrap compiler: import is only supported at the top level" expr)
          (begin
            (import! (cdr expr))
            (ensure-libraries-loaded! (cdr expr))
            (compile-expr! fc
              (cons 'begin
                    (append
                      (list
                        (list 'import! (list 'quote (cdr expr)))
                        (list 'ensure-libraries-loaded! (list 'quote (cdr expr))))
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
    (define (compile-define! fc expr dest tail?)
      (if (fcomp-parent fc)
          (error "bootstrap compiler: internal (define ...) is not yet supported" expr)
          (let* ((sig (cadr expr))
                 (name (if (pair? sig) (car sig) sig))
                 (val-expr (if (pair? sig) (cons 'lambda (cons (cdr sig) (cddr expr))) (caddr expr)))
                 (ch (fcomp-chunk fc))
                 (val-reg (fcomp-alloc-reg! fc)))
            (compile-expr! fc val-expr val-reg #f)
            (defglobal! ch name val-reg)
            (if tail? (chunk-emit! ch 'Return val-reg 0 0 0)))))

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
    ;; time (src/scheme/eval/record.cr), which defines a genuine
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

    (define (compile-program forms)
      (let* ((ch (make-chunk "program"))
             (fc (make-fcomp ch #f)))
        (compile-body! fc forms (fcomp-alloc-reg! fc) #t)
        ch))

    ;; Public entry point: compiles every top-level form in `source` (via
    ;; (creme compiler reader)'s read-program) into SCB1 bytes -- a
    ;; bytevector ready for (creme bootstrap)'s load-chunk-bytes.
    (define (compile-source-to-bytes source)
      (chunk->bytes (compile-program (read-program source))))))
