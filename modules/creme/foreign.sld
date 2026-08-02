;; ===========================================================================
;; (creme foreign): Scheme-native declarative sugar over (creme ffi)
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme memoize)/(creme raft-machine) use) -- pure R7RS syntax-rules layered
;; on (creme ffi)'s eight primitives, no FFI/opaque object of its own. Turns
;; the raw call sequence every (creme ffi) use otherwise repeats --
;;   (define fn (ffi-function lib "sqrt" 'double '(double)))
;;   (ffi-call fn (list 2.0))
;; -- into ordinary-looking Scheme definitions and calls. This codebase's own
;; define-syntax/syntax-rules is UNHYGIENIC for free references (see
;; modules/creme/match.sld's header comment: a macro's expansion resolves
;; free identifiers against the CALLING site, not the defining library), and
;; -- confirmed directly against this interpreter, not merely assumed from
;; R7RS -- introduced BINDING identifiers are not renamed apart between
;; separate top-level uses of the same macro either (two top-level
;; (define-foreign-record ...) forms sharing one fixed internal helper name
;; would silently rebind and corrupt each other). So every macro below keeps
;; its own internal helper names confined to a private (let () ...) or a
;; per-field (lambda ...) closure -- genuine lexical scoping, never a shared
;; top-level define -- rather than relying on macro hygiene for correctness.
;; Only the names a caller supplies (which are unique by construction, same
;; as define-record-type's own field/constructor/predicate names) ever
;; become top-level bindings.
;;
;;   (define-foreign-function name lib c-name ret-type (arg-type ...))
;;     -> (define name ...): after this, (name arg ...) calls straight
;;     through to the C function named c-name in lib (an already ffi-open'd
;;     handle), with no visible ffi-function/ffi-call boilerplate at the
;;     call site. Argument-count mismatches still surface via ffi-call's own
;;     existing error message -- this only removes boilerplate, it doesn't
;;     change what's checked or when.
;;
;;   (define-foreign-struct type-name
;;     (accessor-name mutator-name field-type byte-offset) ...)
;;     -> per field: (define (accessor-name ptr) ...) reads field-type at
;;     byte-offset bytes into whatever pointer ptr is, (define (mutator-name
;;     ptr v) ...) writes it -- thin sugar over ffi-pointer-ref/
;;     ffi-pointer-set!. type-name is never used in the expansion (there's
;;     no derived-identifier facility in syntax-rules to build e.g.
;;     "type-name-field" from parts) -- it's purely a label for the reader,
;;     the same role define-record-type's own <name> argument plays for
;;     something with no meaningful runtime existence, and every generated
;;     name is instead spelled out explicitly per field, same as
;;     define-record-type's own field/accessor/mutator triples. This macro
;;     does NOT allocate a struct or compute layout -- ptr must already
;;     point at real memory of the right size, and byte-offset must be the
;;     REAL offset for the C ABI being targeted (e.g. from a C `offsetof`
;;     reference) -- see (creme ffi)'s own header comment: alignment/
;;     padding is never computed for you. A field with no mutator use
;;     still needs one named here (this macro always generates both);
;;     simply never call it if the field is meant to be read-only.
;;     For the buffer itself: if it's scratch memory the script owns
;;     outright (not a handle a C API allocated and expects back through
;;     its own matching free function), (creme ffi)'s ffi-gc-malloc is the
;;     recommended source -- backed by this process's own Boehm GC heap,
;;     so there's no matching free to remember, unlike a
;;     define-foreign-function-wrapped libc malloc. An out-parameter
;;     another C function already filled in (e.g. gettimeofday's `struct
;;     timeval *`) works exactly the same either way, from either source.
;;
;;   (define-foreign-record type-name
;;     (ctor-name lib c-name ret-type (arg-type ...))
;;     pred-name
;;     (accessor-name lib c-name ret-type (arg-type ...)) ...)
;;     -> the complementary shape for an "opaque handle, no visible fields"
;;     C API (stdio's FILE*, sqlite3*, and similar: a pointer you only ever
;;     pass BACK into further calls on the same library, never peek inside
;;     yourself). Wraps the raw pointer in a genuine, distinct Scheme record
;;     type (built on this interpreter's own define-record-type special
;;     form -- a real per-type predicate, not just the generic ffi-pointer?
;;     every wrapped pointer would otherwise share):
;;       - ctor-name calls its ffi-function and wraps a non-#f (non-NULL)
;;         result; a NULL/#f native return (e.g. a failed fopen) propagates
;;         as plain #f, exactly like the underlying ffi-call already would,
;;         never as an error.
;;       - each accessor-name unwraps the record's own pointer and passes it
;;         as the underlying C function's FIRST ffi-call argument, with any
;;         further Scheme-supplied arguments after it -- so ret-type's own
;;         arg-type list must include the pointer's OWN type (almost always
;;         'pointer) as its first entry, matching the real C signature, even
;;         though callers never pass it explicitly: (file-tell f) reads as
;;         an ordinary one-argument method call, not (ffi-call ... (list
;;         (unwrap f))). This only fits APIs where the handle IS that
;;         function's first C argument (the common "object-style" case,
;;         e.g. every stdio FILE* function below) -- one needing the
;;         pointer elsewhere (e.g. strftime's trailing struct tm*) still
;;         needs define-foreign-function directly, unwrapped.
;;
;; Example (mirrors examples/39-ffi-libm-caller.scm,
;; examples/40-ffi-struct-pointer-clock.scm, and
;; examples/41-ffi-record-file-handle.scm):
;;
;;   (define libm (ffi-open "libm.so.6"))
;;   (define-foreign-function sqrt libm "sqrt" double (double))
;;   (sqrt 2.0)                                     ; => 1.4142135623730951
;;
;;   (define-foreign-struct timeval
;;     (timeval-tv-sec  timeval-tv-sec-set!  int64 0)
;;     (timeval-tv-usec timeval-tv-usec-set! int64 8))
;;   (define tv (malloc 16))
;;   (gettimeofday tv #f)
;;   (timeval-tv-sec tv)                            ; => real epoch seconds
;;
;;   (define-foreign-record <file>
;;     (open-file libc "fopen" pointer (string string))
;;     file?
;;     (file-close  libc "fclose" int32 (pointer))
;;     (file-tell   libc "ftell"  int64 (pointer)))
;;   (define f (open-file "/etc/hostname" "r"))
;;   (file-tell f)                                  ; => 0
;;   (file-close f)
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme foreign)) explicitly, same as any other file-based
;; library. See (creme ffi)'s own header comment for the SECURITY caveat
;; every macro here inherits unchanged (genuine native code execution, no
;; memory safety once you're inside ffi-pointer-ref/-set!'s reach) --
;; an embedder MUST exclude "creme foreign" from any allowed_libraries
;; allowlist for untrusted guest scripts, exactly like (creme ffi) itself.
;; ===========================================================================

(define-library (creme foreign)
  (export define-foreign-function define-foreign-struct define-foreign-record)
  (import (scheme base) (creme ffi))
  (begin
    (define-syntax define-foreign-function
      (syntax-rules ()
        ((_ name lib c-name ret-type (arg-type ...))
         (define name
           (let ((%fn (ffi-function lib c-name 'ret-type '(arg-type ...))))
             (lambda args (ffi-call %fn args)))))))

    (define-syntax define-foreign-struct
      (syntax-rules ()
        ((_ type-name (accessor-name mutator-name field-type byte-offset) ...)
         (begin
           (begin
             (define (accessor-name ptr) (ffi-pointer-ref ptr byte-offset 'field-type))
             (define (mutator-name ptr v) (ffi-pointer-set! ptr byte-offset 'field-type v)))
           ...))))

    (define-syntax define-foreign-record
      (syntax-rules ()
        ((_ type-name
            (ctor-name ctor-lib ctor-c-name ctor-ret (ctor-arg-type ...))
            pred-name
            (accessor-name acc-lib acc-c-name acc-ret (acc-arg-type ...)) ...)
         (begin
           (define ctor-name #f)
           (define pred-name #f)
           (define accessor-name #f)
           ...
           (let ()
             (define-record-type type-name (%foreign-wrap %foreign-ptr) %foreign-pred (%foreign-ptr %foreign-unwrap))
             (set! pred-name %foreign-pred)
             (set! ctor-name
               (let ((%fn (ffi-function ctor-lib ctor-c-name 'ctor-ret '(ctor-arg-type ...))))
                 (lambda args
                   (let ((%raw (ffi-call %fn args)))
                     (if %raw (%foreign-wrap %raw) #f)))))
             (set! accessor-name
               (let ((%fn (ffi-function acc-lib acc-c-name 'acc-ret '(acc-arg-type ...))))
                 (lambda (%instance . %rest)
                   (ffi-call %fn (cons (%foreign-unwrap %instance) %rest)))))
             ...)))))))
