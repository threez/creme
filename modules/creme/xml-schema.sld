;; ===========================================================================
;; (creme xml-schema): declarative validation of parsed XML documents against
;; a schema -- the shared IR, the validator engine, the datatype/facet engine,
;; the namespace helpers, and the S-expression schema DSL.
;;
;; A document to validate is a node in EXACTLY (creme xml)'s / (creme html)'s
;; node shape -- `(tag (@ (name value) ...) child ...)`, `tag` a symbol, each
;; attr a 2-element `(name value)` list, text children strings -- so
;; `(xml-read s)`'s output is validated directly with no intermediate DOM.
;;
;; Three schema frontends all compile to the ONE internal model built here:
;;   - the S-expr DSL `dsl->schema` (this file) -- the idiomatic frontend;
;;   - `(creme xml-schema dtd)`'s `dtd-read` (real DTD text);
;;   - `(creme xml-schema xsd)`'s `xsd-read` (real XSD documents).
;; A reader is "done" when it emits the IR records below; the validator never
;; knows which frontend produced its schema.
;;
;; Design posture (see (creme lr)'s header for the same reasoning): a schema is
;; PLAIN DATA interpreted by ordinary, individually-testable procedures, not a
;; macro-heavy DSL -- this Scheme's syntax-rules/defmacro are unhygienic, and a
;; validation model is logic-heavy but binding-light, so data + procedures is
;; both safer and more idiomatic. The optional `define-schema` sugar is a thin
;; defmacro; every runtime helper its expansion calls is exported.
;;
;;   (dsl->schema form)        -> a <schema> from S-expr DSL data (see below)
;;   (validate schema node)    -> a list of <validation-error> (empty = valid)
;;   (valid? schema node)      -> #t iff (validate ...) is empty
;;   (validate/raise s node)   -> #t, or raises on the first error
;;
;; S-expr DSL shape:
;;   (schema (target-ns "uri")?           ; optional
;;     (element NAME TYPESPEC-or-COMPLEX)  ; global element declaration
;;     (simple-type NAME TYPESPEC)?        ; named global simple type
;;     ...)
;;   TYPESPEC : a builtin symbol (string integer decimal boolean ...),
;;              (restrict BASE (FACET VALUE) ...),
;;              or a NAME referring to a (simple-type NAME ...)
;;   an element body is one of:
;;              (type TYPESPEC)                     ; simple content (text)
;;              (complex PARTICLE ATTR... FLAG...)  ; element/mixed content
;;   PARTICLE : (sequence PARTICLE ...) | (choice PARTICLE ...) | (all PARTICLE ...)
;;              (element NAME BODY (occurs MIN MAX)?)   ; local, inline decl
;;              (ref NAME (occurs MIN MAX)?)            ; ref to a global element
;;              (any (namespace NS)? (process P)? (occurs MIN MAX)?)  ; wildcard
;;              empty | pcdata                          ; leaf content kinds
;;   ATTR     : (attribute NAME (type TYPESPEC)? (use required|optional|prohibited)?
;;                               (default "v")? (fixed "v")? (enum "a" "b" ...)?)
;;   FLAG     : mixed                       ; text allowed between children
;;   MIN/MAX  : non-negative integers; MAX may be the symbol `unbounded`.
;;
;; Limitations (explicit, per this project's scope honesty -- and inheriting
;; (creme xml)'s own: no CDATA/comment/PI fidelity):
;;   - Unique Particle Attribution is NOT strictly enforced (validation is
;;     ambiguity-proof regardless); XSD 1.1 (assertions, conditional types,
;;     open content), and xs:key/keyref/unique identity constraints are OUT
;;     of scope. Only DTD/ID/IDREF cross-checks are performed.
;;   - date/time datatypes are checked lexically + light range only (no full
;;     calendar/timezone semantics); XSD regex escapes \i \c \p{...} are not
;;     supported (patterns are treated as (creme regex) patterns, anchored).
;;
;; Not auto-imported anywhere -- (import (creme xml-schema)) explicitly.
;; ===========================================================================

(define-library (creme xml-schema)
  (export
    ;; IR constructors/predicates/accessors (needed by the dtd/xsd readers)
    make-schema schema? schema-target-ns schema-elements schema-types
    schema-groups schema-attribute-groups schema-elem-form-default
    schema-attr-form-default
    make-element-decl element-decl? element-decl-name element-decl-type
    element-decl-nillable? element-decl-abstract? element-decl-subst-group
    element-decl-default element-decl-fixed
    make-particle-group particle-group? particle-group-kind
    particle-group-children particle-group-min particle-group-max
    make-particle-element particle-element? particle-element-ref
    particle-element-inline particle-element-min particle-element-max
    make-particle-wildcard particle-wildcard? particle-wildcard-ns
    particle-wildcard-process particle-wildcard-min particle-wildcard-max
    make-attr-decl attr-decl? attr-decl-name attr-decl-type attr-decl-use
    attr-decl-default attr-decl-fixed attr-decl-enum
    make-complex-type complex-type? complex-type-name complex-type-content-kind
    complex-type-particle complex-type-mixed? complex-type-attrs
    complex-type-attr-wildcard complex-type-base complex-type-derivation
    complex-type-abstract?
    make-simple-type simple-type? simple-type-name simple-type-variety
    simple-type-base simple-type-facets simple-type-item-type
    simple-type-member-types
    make-facet facet? facet-kind facet-value facet-fixed?
    make-type-ref type-ref? type-ref-name
    ;; namespace + name helpers (needed by readers)
    split-qname make-ename ename? ename-ns ename-local ename-key ename=?
    schema-register-element! schema-register-type! schema-register-group!
    schema-register-attribute-group! schema-new
    ;; datatype/facet engine (needed by xsd reader to interpret restriction)
    validate-simple builtin-datatype? apply-white-space
    ;; frontends
    dsl->schema
    ;; validation
    validate valid? validate/raise
    ;; error accessors
    make-validation-error validation-error? validation-error-kind
    validation-error-message validation-error-path)
  (import (scheme base) (scheme char) (scheme cxr) (scheme write)
          (creme regex) (creme string) (creme hash-table) (creme extra))
  (begin

    ;; ---------------------------------------------------------------------
    ;; Expanded names + namespace helpers
    ;;
    ;; An expanded name (`ename`) is (ns . local): `ns` a URI string or #f (no
    ;; namespace), `local` a symbol. `ename-key` is its stringified hash key.
    ;; ---------------------------------------------------------------------
    (define (make-ename ns local) (cons ns local))
    (define (ename? x) (and (pair? x) (symbol? (cdr x))))
    (define (ename-ns e) (car e))
    (define (ename-local e) (cdr e))
    ;; Names are matched by LOCAL name: prefixes are resolved via the ns-env
    ;; (so `tns:book` matches a `book` declaration) but colliding local names
    ;; in different namespaces are not distinguished -- a deliberate pragmatic
    ;; cut (single-target-namespace schemas, the common case, validate
    ;; correctly). The namespace URI is still retained on the ename for
    ;; wildcard ##other/##local tests.
    (define (ename-key e) (symbol->string (ename-local e)))
    (define (ename=? a b) (eq? (ename-local a) (ename-local b)))

    ;; (split-qname sym) -> (values prefix-symbol local-symbol); prefix #f if none.
    (define (split-qname sym)
      (let* ((s (symbol->string sym))
             (i (string-index-of s ":")))
        (if (and i (>= i 0))
            (values (string->symbol (substring s 0 i))
                    (string->symbol (substring s (+ i 1) (string-length s))))
            (values #f sym))))

    ;; ---------------------------------------------------------------------
    ;; The shared IR
    ;; ---------------------------------------------------------------------
    (define-record-type <schema>
      (make-schema target-ns elements types groups attribute-groups
                   elem-form-default attr-form-default)
      schema?
      (target-ns         schema-target-ns)
      (elements          schema-elements)          ; hash: ename-key -> element-decl
      (types             schema-types)             ; hash: ename-key -> simple/complex-type
      (groups            schema-groups)            ; hash: ename-key -> particle
      (attribute-groups  schema-attribute-groups)  ; hash: ename-key -> list of attr-decl
      (elem-form-default schema-elem-form-default) ; 'qualified | 'unqualified
      (attr-form-default schema-attr-form-default))

    (define (schema-new target-ns)
      (make-schema target-ns (make-hash-table) (make-hash-table)
                   (make-hash-table) (make-hash-table) 'unqualified 'unqualified))

    (define (schema-register-element! s decl)
      (hash-table-set! (schema-elements s) (ename-key (element-decl-name decl)) decl))
    (define (schema-register-type! s name ty)
      (hash-table-set! (schema-types s) (ename-key name) ty))
    (define (schema-register-group! s name particle)
      (hash-table-set! (schema-groups s) (ename-key name) particle))
    (define (schema-register-attribute-group! s name attrs)
      (hash-table-set! (schema-attribute-groups s) (ename-key name) attrs))

    (define-record-type <element-decl>
      (make-element-decl name type nillable? abstract? subst-group default fixed)
      element-decl?
      (name        element-decl-name)
      (type        element-decl-type)        ; simple/complex-type or type-ref
      (nillable?   element-decl-nillable?)
      (abstract?   element-decl-abstract?)
      (subst-group element-decl-subst-group)
      (default     element-decl-default)
      (fixed       element-decl-fixed))

    (define-record-type <particle-group>
      (make-particle-group kind children min max)
      particle-group?
      (kind     particle-group-kind)       ; 'sequence | 'choice | 'all
      (children particle-group-children)
      (min      particle-group-min)
      (max      particle-group-max))       ; integer | 'unbounded

    (define-record-type <particle-element>
      (make-particle-element ref inline min max)
      particle-element?
      (ref    particle-element-ref)        ; ename | #f
      (inline particle-element-inline)     ; element-decl | #f
      (min    particle-element-min)
      (max    particle-element-max))

    (define-record-type <particle-wildcard>
      (make-particle-wildcard ns process min max)
      particle-wildcard?
      (ns      particle-wildcard-ns)        ; 'any | 'other | 'local | list of uri
      (process particle-wildcard-process)   ; 'strict | 'lax | 'skip
      (min     particle-wildcard-min)
      (max     particle-wildcard-max))

    (define-record-type <attr-decl>
      (make-attr-decl name type use default fixed enum)
      attr-decl?
      (name    attr-decl-name)
      (type    attr-decl-type)             ; simple-type or type-ref or #f
      (use     attr-decl-use)              ; 'required | 'optional | 'prohibited
      (default attr-decl-default)
      (fixed   attr-decl-fixed)
      (enum    attr-decl-enum))            ; list of string | #f

    (define-record-type <complex-type>
      (make-complex-type name content-kind particle mixed? attrs attr-wildcard
                         base derivation abstract?)
      complex-type?
      (name          complex-type-name)
      (content-kind  complex-type-content-kind) ; empty|element-only|mixed|simple|any
      (particle      complex-type-particle)
      (mixed?        complex-type-mixed?)
      (attrs         complex-type-attrs)
      (attr-wildcard complex-type-attr-wildcard)
      (base          complex-type-base)
      (derivation    complex-type-derivation)
      (abstract?     complex-type-abstract?))

    (define-record-type <simple-type>
      (make-simple-type name variety base facets item-type member-types)
      simple-type?
      (name         simple-type-name)
      (variety      simple-type-variety)   ; 'atomic | 'list | 'union
      (base         simple-type-base)      ; builtin symbol OR ename of another simple type
      (facets       simple-type-facets)
      (item-type    simple-type-item-type)
      (member-types simple-type-member-types))

    (define-record-type <facet>
      (make-facet kind value fixed?)
      facet?
      (kind   facet-kind)
      (value  facet-value)
      (fixed? facet-fixed?))

    (define-record-type <type-ref>
      (make-type-ref name)
      type-ref?
      (name type-ref-name))                ; ename

    (define-record-type <validation-error>
      (make-validation-error kind message path)
      validation-error?
      (kind    validation-error-kind)
      (message validation-error-message)
      (path    validation-error-path))     ; list of (tag . index) from root

    ;; ---------------------------------------------------------------------
    ;; SXML node accessors
    ;; ---------------------------------------------------------------------
    (define (node-element? n) (and (pair? n) (symbol? (car n))))
    (define (node-tag n) (car n))
    (define (node-attr-block n)
      (let ((rest (cdr n)))
        (and (pair? rest) (pair? (car rest)) (eq? (car (car rest)) '@) (car rest))))
    (define (node-attrs n)
      (let ((blk (node-attr-block n)))
        (if blk (cdr blk) '())))
    (define (node-children n)
      (let ((rest (cdr n)))
        (if (node-attr-block n) (cdr rest) rest)))
    (define (node-child-elements n) (filter node-element? (node-children n)))
    (define (node-text n)
      (apply string-append (filter string? (node-children n))))
    (define (attr-name a) (car a))
    (define (attr-value a) (cadr a))

    ;; A document element's expanded name, ignoring namespaces (fallback).
    (define (node-ename n) (make-ename #f (node-tag n)))

    ;; Namespace resolution: an ns-env is an alist prefix-symbol|#f -> uri.
    ;; (creme xml) keeps `xmlns`/`xmlns:*` as ordinary attributes, so we track
    ;; them ourselves while descending the tree.
    (define (lookup-ns env prefix)
      (let ((cell (assv prefix env))) (and cell (cdr cell))))

    (define (extend-ns-env env n)
      (let loop ((as (node-attrs n)) (env env))
        (if (null? as) env
            (let ((nm (symbol->string (car (car as)))) (val (cadr (car as))))
              (cond
                ((string=? nm "xmlns") (loop (cdr as) (cons (cons #f val) env)))
                ((and (> (string-length nm) 6) (string=? (substring nm 0 6) "xmlns:"))
                 (loop (cdr as)
                       (cons (cons (string->symbol (substring nm 6 (string-length nm))) val) env)))
                (else (loop (cdr as) env)))))))

    ;; Resolve a document element's expanded name against an ns-env.
    (define (resolve-node-ename n env)
      (call-with-values (lambda () (split-qname (node-tag n)))
        (lambda (prefix local) (make-ename (lookup-ns env prefix) local))))

    ;; ---------------------------------------------------------------------
    ;; Datatype + facet engine
    ;;
    ;; (validate-simple st s) -> list of error-message strings (empty = ok).
    ;; `st` is a <simple-type> or a builtin datatype symbol.
    ;; ---------------------------------------------------------------------
    (define builtin-datatypes
      '(string boolean decimal integer int long short byte
        nonNegativeInteger positiveInteger nonPositiveInteger negativeInteger
        unsignedInt unsignedLong unsignedShort unsignedByte
        float double token normalizedString
        NMTOKEN NMTOKENS Name NCName ID IDREF IDREFS ENTITY ENTITIES
        anyURI QName language
        date time dateTime gYear gYearMonth duration
        base64Binary hexBinary NOTATION))
    (define (builtin-datatype? sym) (and (memq sym builtin-datatypes) #t))

    (define (all-digits? s)
      (and (> (string-length s) 0)
           (let loop ((i 0))
             (or (= i (string-length s))
                 (and (char-numeric? (string-ref s i)) (loop (+ i 1)))))))

    (define (integer-lexical? s)
      (let ((s2 (if (and (> (string-length s) 0)
                         (or (char=? (string-ref s 0) #\-) (char=? (string-ref s 0) #\+)))
                    (substring s 1 (string-length s)) s)))
        (all-digits? s2)))

    (define (decimal-lexical? s)
      (let* ((s2 (if (and (> (string-length s) 0)
                          (or (char=? (string-ref s 0) #\-) (char=? (string-ref s 0) #\+)))
                     (substring s 1 (string-length s)) s))
             (parts (string-split s2 ".")))
        (cond ((= (length parts) 1) (all-digits? (car parts)))
              ((= (length parts) 2)
               (and (or (= 0 (string-length (car parts))) (all-digits? (car parts)))
                    (all-digits? (cadr parts))))
              (else #f))))

    (define (name-lexical? s)
      (and (> (string-length s) 0)
           (let ((c0 (string-ref s 0)))
             (or (char-alphabetic? c0) (char=? c0 #\_) (char=? c0 #\:)))
           (let loop ((i 1))
             (or (= i (string-length s))
                 (let ((c (string-ref s i)))
                   (and (or (char-alphabetic? c) (char-numeric? c)
                            (char=? c #\-) (char=? c #\_) (char=? c #\.) (char=? c #\:))
                        (loop (+ i 1))))))))

    (define (nmtoken-lexical? s)
      (and (> (string-length s) 0)
           (let loop ((i 0))
             (or (= i (string-length s))
                 (let ((c (string-ref s i)))
                   (and (or (char-alphabetic? c) (char-numeric? c)
                            (char=? c #\-) (char=? c #\_) (char=? c #\.) (char=? c #\:))
                        (loop (+ i 1))))))))

    ;; Lexical/value check of a builtin base. Returns (cons ok? canonical),
    ;; where canonical is a number for ordered numeric types, else the string.
    (define (builtin-check base s)
      (case base
        ((string normalizedString token anyURI language
          NOTATION base64Binary hexBinary QName ENTITY ENTITIES)
         (cons #t s))
        ((boolean) (cons (or (string=? s "true") (string=? s "false")
                             (string=? s "0") (string=? s "1")) s))
        ((integer int long short byte
          nonNegativeInteger positiveInteger nonPositiveInteger negativeInteger
          unsignedInt unsignedLong unsignedShort unsignedByte)
         (if (integer-lexical? s)
             (let ((n (string->number s)))
               (cons (case base
                       ((nonNegativeInteger unsignedInt unsignedLong unsignedShort unsignedByte)
                        (>= n 0))
                       ((positiveInteger) (> n 0))
                       ((nonPositiveInteger) (<= n 0))
                       ((negativeInteger) (< n 0))
                       (else #t))
                     n))
             (cons #f s)))
        ((decimal) (if (decimal-lexical? s) (cons #t (string->number s)) (cons #f s)))
        ((float double)
         (cond ((or (string=? s "INF") (string=? s "-INF") (string=? s "NaN")) (cons #t s))
               ((string->number s) => (lambda (n) (cons #t n)))
               (else (cons #f s))))
        ((Name QName) (cons (name-lexical? s) s))
        ((NCName ID IDREF ENTITY) (cons (and (name-lexical? s)
                                             (not (string-contains? s ":"))) s))
        ((NMTOKEN) (cons (nmtoken-lexical? s) s))
        ((NMTOKENS IDREFS) (cons (every nmtoken-lexical? (string-split s " ")) s))
        ((date) (cons (regexp-matches? (regexp "^-?[0-9]{4}-[0-9]{2}-[0-9]{2}(Z|[-+][0-9]{2}:[0-9]{2})?$") s) s))
        ((time) (cons (regexp-matches? (regexp "^[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[-+][0-9]{2}:[0-9]{2})?$") s) s))
        ((dateTime) (cons (regexp-matches? (regexp "^-?[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[-+][0-9]{2}:[0-9]{2})?$") s) s))
        ((gYear) (cons (regexp-matches? (regexp "^-?[0-9]{4}(Z|[-+][0-9]{2}:[0-9]{2})?$") s) s))
        ((gYearMonth) (cons (regexp-matches? (regexp "^-?[0-9]{4}-[0-9]{2}(Z|[-+][0-9]{2}:[0-9]{2})?$") s) s))
        ((duration) (cons (regexp-matches? (regexp "^-?P([0-9]+Y)?([0-9]+M)?([0-9]+D)?(T([0-9]+H)?([0-9]+M)?([0-9]+(\\.[0-9]+)?S)?)?$") s) s))
        (else (cons #t s))))

    ;; whiteSpace facet transform (preserve|replace|collapse).
    (define (apply-white-space mode s)
      (case mode
        ((collapse) (string-trim (regexp-replace-all (regexp "[ \t\r\n]+") " " s)))
        ((replace) (regexp-replace-all (regexp "[\t\r\n]") " " s))
        (else s)))

    (define (ordered-datatype? base)
      (memq base '(decimal integer int long short byte
                   nonNegativeInteger positiveInteger nonPositiveInteger negativeInteger
                   unsignedInt unsignedLong unsignedShort unsignedByte
                   float double date time dateTime)))

    (define (facet-error f base s canonical)
      (case (facet-kind f)
        ((pattern)
         (if (regexp-matches? (regexp (string-append "^(?:" (facet-value f) ")$")) s)
             #f (string-append "value \"" s "\" does not match pattern " (facet-value f))))
        ((enumeration)
         (if (member s (facet-value f)) #f
             (string-append "value \"" s "\" is not in the enumeration")))
        ((length)
         (if (= (string-length s) (facet-value f)) #f
             (string-append "value \"" s "\" must have length " (number->string (facet-value f)))))
        ((min-length)
         (if (>= (string-length s) (facet-value f)) #f
             (string-append "value \"" s "\" is shorter than minLength " (number->string (facet-value f)))))
        ((max-length)
         (if (<= (string-length s) (facet-value f)) #f
             (string-append "value \"" s "\" is longer than maxLength " (number->string (facet-value f)))))
        ((min-inclusive)
         (if (and (number? canonical) (>= canonical (facet-value f))) #f
             (string-append "value " s " is below minInclusive " (number->string (facet-value f)))))
        ((max-inclusive)
         (if (and (number? canonical) (<= canonical (facet-value f))) #f
             (string-append "value " s " is above maxInclusive " (number->string (facet-value f)))))
        ((min-exclusive)
         (if (and (number? canonical) (> canonical (facet-value f))) #f
             (string-append "value " s " is not above minExclusive " (number->string (facet-value f)))))
        ((max-exclusive)
         (if (and (number? canonical) (< canonical (facet-value f))) #f
             (string-append "value " s " is not below maxExclusive " (number->string (facet-value f)))))
        ((white-space) #f)
        (else #f)))

    (define (white-space-mode facets)
      (let loop ((fs facets))
        (cond ((null? fs) #f)
              ((eq? (facet-kind (car fs)) 'white-space) (facet-value (car fs)))
              (else (loop (cdr fs))))))

    ;; validate-simple : (simple-type | builtin-symbol) x string -> list of msgs
    (define (validate-simple st s)
      (cond
        ((symbol? st)
         (let ((chk (builtin-check st s)))
           (if (car chk) '()
               (list (string-append "value \"" s "\" is not a valid " (symbol->string st))))))
        ((simple-type? st)
         (case (simple-type-variety st)
           ((atomic)
            (let* ((base (simple-type-base st))
                   (facets (simple-type-facets st))
                   (ws (white-space-mode facets))
                   (s* (if ws (apply-white-space ws s) s)))
              (if (symbol? base)
                  (let ((chk (builtin-check base s*)))
                    (if (car chk)
                        (filter (lambda (m) m)
                                (map (lambda (f) (facet-error f base s* (cdr chk))) facets))
                        (list (string-append "value \"" s* "\" is not a valid "
                                             (symbol->string base)))))
                  ;; base is an ename of another simple type -- resolved by caller
                  ;; via a type-ref; treat as string here (full chain in P5).
                  (filter (lambda (m) m)
                          (map (lambda (f) (facet-error f 'string s* s*)) facets)))))
           ((list)
            (append-map (lambda (tok) (validate-simple (simple-type-item-type st) tok))
                        (string-split (string-trim s) " ")))
           ((union)
            (if (any (lambda (m) (null? (validate-simple m s)))
                     (simple-type-member-types st))
                '()
                (list (string-append "value \"" s "\" matches no union member"))))
           (else '())))
        (else '())))

    ;; ---------------------------------------------------------------------
    ;; Content-model matcher: a particle model is compiled once to a Thompson
    ;; NFA whose transitions are labelled either 'eps or a predicate on a child
    ;; element's expanded-name, then a child list is validated by on-the-fly
    ;; subset simulation (a lazy DFA) -- O(states x children), never
    ;; backtracks, so nested unbounded models (the exponential trap for a naive
    ;; backtracker) stay linear. xs:all is not regular and is matched by a
    ;; dedicated bag matcher instead (see all-matcher).
    ;;
    ;; An NFA is (start accept transitions), transitions a hash-table
    ;; state-id -> list of (label . target); label is 'eps or a 1-arg predicate.
    ;; ---------------------------------------------------------------------

    ;; Does `child-ename` satisfy element particle `p`? A child also matches a
    ;; global element reference when it is a member of that element's
    ;; substitution group (and is not abstract).
    (define (element-matches? s p child-ename)
      (let ((decl-name
             (cond ((particle-element-ref p) (particle-element-ref p))
                   ((particle-element-inline p) (element-decl-name (particle-element-inline p)))
                   (else #f))))
        (and decl-name
             (or (ename=? decl-name child-ename)
                 (and (particle-element-ref p)
                      (subst-group-member? s child-ename decl-name))))))

    ;; Is `child` (a global element) substitutable for `head` via the
    ;; substitutionGroup chain? Guards against cycles with a bounded walk.
    (define (subst-group-member? s child-ename head-ename)
      (let loop ((cur child-ename) (fuel 32))
        (let ((decl (hash-table-ref-opt (schema-elements s) (ename-key cur))))
          (cond
            ((or (not decl) (<= fuel 0) (element-decl-abstract? decl)) #f)
            ((element-decl-subst-group decl)
             (if (ename=? (element-decl-subst-group decl) head-ename) #t
                 (loop (element-decl-subst-group decl) (- fuel 1))))
            (else #f)))))

    (define (wildcard-matches? s p target-ns child-ename)
      (case (particle-wildcard-ns p)
        ((any) #t)
        ((local) (not (ename-ns child-ename)))
        ((other) (and (ename-ns child-ename)
                      (not (equal? (ename-ns child-ename) target-ns))))
        (else (and (list? (particle-wildcard-ns p))
                   (member (ename-ns child-ename) (particle-wildcard-ns p)) #t))))

    ;; Compile `particle` to an NFA (list start accept transitions).
    (define (build-content-nfa s target-ns particle)
      (let ((trans (make-hash-table))
            (ctr (vector 0)))
        (define (new-state)
          (let ((id (vector-ref ctr 0))) (vector-set! ctr 0 (+ id 1)) id))
        (define (add! from label to)
          (hash-table-set! trans from
                           (cons (cons label to)
                                 (if (hash-table-contains? trans from)
                                     (hash-table-ref trans from) '()))))
        ;; a fragment is (start . accept)
        (define (frag-single pred)
          (let ((a (new-state)) (b (new-state))) (add! a pred b) (cons a b)))
        (define (frag-eps) (let ((a (new-state))) (cons a a)))
        (define (frag-concat frags)
          (if (null? frags) (frag-eps)
              (let loop ((fs (cdr frags)) (start (car (car frags))) (acc (cdr (car frags))))
                (if (null? fs) (cons start acc)
                    (begin (add! acc 'eps (car (car fs)))
                           (loop (cdr fs) start (cdr (car fs))))))))
        (define (frag-alt frags)
          (let ((a (new-state)) (b (new-state)))
            (for-each (lambda (f) (add! a 'eps (car f)) (add! (cdr f) 'eps b)) frags)
            (cons a b)))
        ;; occurrence {mn,mx}: mn mandatory copies, then either a Kleene loop
        ;; (unbounded) or up to (mx-mn) optional sequential copies. `build` is a
        ;; thunk producing a FRESH fragment each call (distinct states).
        (define (frag-repeat build mn mx)
          (let ((mand (frag-concat (map (lambda (ignore) (build)) (iota mn)))))
            (cond
              ((eq? mx 'unbounded)
               (let ((loop-in (new-state)) (loop-out (new-state)) (f (build)))
                 (add! (cdr mand) 'eps loop-in)
                 (add! loop-in 'eps (car f))
                 (add! loop-in 'eps loop-out)
                 (add! (cdr f) 'eps loop-in)
                 (cons (car mand) loop-out)))
              (else
               (let ((end (new-state)))
                 (add! (cdr mand) 'eps end)
                 (let loop ((k (- mx mn)) (cur (cdr mand)))
                   (if (<= k 0) (cons (car mand) end)
                       (let ((f (build)))
                         (add! cur 'eps (car f))
                         (add! (cdr f) 'eps end)
                         (loop (- k 1) (cdr f))))))))))
        (define (build p)
          (cond
            ((particle-element? p)
             (frag-repeat (lambda () (frag-single (lambda (nm) (element-matches? s p nm))))
                          (particle-element-min p) (particle-element-max p)))
            ((particle-wildcard? p)
             (frag-repeat (lambda () (frag-single (lambda (nm) (wildcard-matches? s p target-ns nm))))
                          (particle-wildcard-min p) (particle-wildcard-max p)))
            ((particle-group? p)
             (frag-repeat
              (lambda ()
                (let ((kids (map build (particle-group-children p))))
                  (case (particle-group-kind p)
                    ((sequence) (frag-concat kids))
                    ((choice) (frag-alt kids))
                    (else (frag-concat kids)))))
              (particle-group-min p) (particle-group-max p)))
            (else (frag-eps))))
        (let ((f (build particle)))
          (list (car f) (cdr f) trans))))

    (define (nfa-start nfa) (car nfa))
    (define (nfa-accept nfa) (cadr nfa))
    (define (nfa-trans nfa) (caddr nfa))

    ;; epsilon-closure of a set of states (a hash-table used as a set).
    (define (eps-closure trans state-set)
      (let ((stack (hash-table-keys state-set)))
        (let loop ((stack stack))
          (if (null? stack) state-set
              (let ((edges (if (hash-table-contains? trans (car stack))
                               (hash-table-ref trans (car stack)) '())))
                (let inner ((es edges) (added '()))
                  (cond
                    ((null? es) (loop (append added (cdr stack))))
                    ((and (eq? (car (car es)) 'eps)
                          (not (hash-table-contains? state-set (cdr (car es)))))
                     (hash-table-set! state-set (cdr (car es)) #t)
                     (inner (cdr es) (cons (cdr (car es)) added)))
                    (else (inner (cdr es) added)))))))))

    (define (singleton-set x)
      (let ((h (make-hash-table))) (hash-table-set! h x #t) h))

    ;; Simulate the NFA over a list of child enames; #t iff it accepts.
    (define (nfa-accepts? nfa names)
      (let ((trans (nfa-trans nfa)))
        (let loop ((cur (eps-closure trans (singleton-set (nfa-start nfa)))) (ns names))
          (if (null? ns)
              (hash-table-contains? cur (nfa-accept nfa))
              (let ((nxt (make-hash-table)))
                (for-each
                 (lambda (st)
                   (let ((edges (if (hash-table-contains? trans st)
                                    (hash-table-ref trans st) '())))
                     (for-each
                      (lambda (e)
                        (if (and (not (eq? (car e) 'eps)) ((car e) (car ns)))
                            (hash-table-set! nxt (cdr e) #t)))
                      edges)))
                 (hash-table-keys cur))
                (if (null? (hash-table-keys nxt)) #f
                    (loop (eps-closure trans nxt) (cdr ns))))))))

    ;; Top-level acceptance test for a content model against child enames.
    (define (content-model-accepts? s target-ns particle names)
      (cond
        ((not particle) (null? names))
        ((and (particle-group? particle) (eq? (particle-group-kind particle) 'all))
         (pair? ((all-matcher s target-ns (particle-group-children particle)) names)))
        (else (nfa-accepts? (build-content-nfa s target-ns particle) names))))

    ;; xs:all: each child matches some not-yet-consumed member; every min=1
    ;; member is consumed exactly once. Members are element particles with
    ;; max<=1 (XSD 1.0). O(children * members). Returns (list '()) on success.
    (define (all-matcher s target-ns members)
      (lambda (names)
        (let loop ((names names) (used '()))
          (if (null? names)
              (if (every (lambda (i)
                           (or (member i used)
                               (= 0 (particle-element-min (list-ref members i)))))
                         (iota (length members)))
                  (list '()) '())
              (let ((idx (find-all-member s members used (car names))))
                (if idx (loop (cdr names) (cons idx used)) '()))))))

    (define (find-all-member s members used child-ename)
      (let loop ((i 0))
        (cond ((= i (length members)) #f)
              ((and (not (member i used))
                    (element-matches? s (list-ref members i) child-ename)) i)
              (else (loop (+ i 1))))))

    ;; ---------------------------------------------------------------------
    ;; The validator
    ;; ---------------------------------------------------------------------
    (define (resolve-type s ty)
      (if (type-ref? ty)
          (let ((found (hash-table-ref-opt (schema-types s) (ename-key (type-ref-name ty)))))
            (or found ty))
          ty))

    (define (hash-table-ref-opt h k)
      (if (hash-table-contains? h k) (hash-table-ref h k) #f))

    (define (err kind msg path) (make-validation-error kind msg path))

    ;; Validate node `n` against element-decl `decl`, accumulating errors.
    ;; `env` is the in-scope ns-env for `n` (already extended by n's xmlns).
    (define (validate-element s decl n path env)
      (let ((ty (resolve-type s (element-decl-type decl))))
        (cond
          ((complex-type? ty) (validate-complex s ty n path env))
          ((or (simple-type? ty) (symbol? ty))
           ;; simple content: no child elements, text validated against ty
           (append
            (if (null? (node-child-elements n)) '()
                (list (err 'unexpected-element
                           (string-append "element <" (symbol->string (node-tag n))
                                          "> has simple content but contains child elements")
                           path)))
            (map (lambda (m) (err 'datatype m path)) (validate-simple ty (node-text n)))
            (validate-attrs s '() n path)))
          (else '()))))

    ;; Effective content of a complex type, resolving XSD restriction/extension
    ;; against its base (lazily, so anonymous/forward/chained bases all work).
    ;; Returns (values content-kind particle attrs).
    (define (effective-content s ty)
      (if (and (complex-type-base ty) (complex-type-derivation ty))
          (let ((base (resolve-type s (make-type-ref (complex-type-base ty)))))
            (if (complex-type? base)
                (call-with-values (lambda () (effective-content s base))
                  (lambda (bkind bp ba)
                    (case (complex-type-derivation ty)
                      ((extension)
                       (values (complex-type-content-kind ty)
                               (merge-particles bp (complex-type-particle ty))
                               (append ba (complex-type-attrs ty))))
                      (else ; restriction
                       (values (complex-type-content-kind ty)
                               (complex-type-particle ty)
                               (complex-type-attrs ty))))))
                ;; base is a simple type (simpleContent) or unknown -> use own
                (values (complex-type-content-kind ty)
                        (complex-type-particle ty) (complex-type-attrs ty))))
          (values (complex-type-content-kind ty)
                  (complex-type-particle ty) (complex-type-attrs ty))))

    (define (merge-particles a b)
      (cond ((not a) b)
            ((not b) a)
            (else (make-particle-group 'sequence (list a b) 1 1))))

    (define (validate-complex s ty n path env)
      (call-with-values (lambda () (effective-content s ty))
        (lambda (kind particle attrs)
          ;; resolve each child's ename + its own ns-env once, shared by the
          ;; content-model check and the recursion.
          (let* ((kids (node-child-elements n))
                 (rk (map (lambda (k)
                            (let ((ke (extend-ns-env env k)))
                              (list k (resolve-node-ename k ke) ke)))
                          kids)))
            (append
             (validate-content s kind particle n rk path)
             (validate-attrs s attrs n path)
             (validate-children s particle rk path))))))

    (define (validate-content s kind particle n rk path)
      (let ((kids (map car rk)))
        (case kind
          ((empty)
           (append
            (if (null? kids) '()
                (list (err 'unexpected-element "element must be empty" path)))
            (if (string=? "" (string-trim (node-text n))) '()
                (list (err 'unexpected-text "element must be empty" path)))))
          ((any) '())
          ((simple)
           (append
            (if (null? kids) '()
                (list (err 'unexpected-element
                           "element has simple content but contains child elements" path)))
            (map (lambda (m) (err 'datatype m path))
                 (validate-simple (or particle 'string) (node-text n)))))
          (else ; element-only or mixed
           (let ((names (map cadr rk)))
             (if (content-model-accepts? s (schema-target-ns s) particle names)
                 '()
                 (list (err 'content-model
                            (string-append "element <" (symbol->string (node-tag n))
                                           "> content does not match its model")
                            path))))))))

    (define (validate-children s particle rk path)
      (let loop ((rk rk) (i 0) (acc '()))
        (if (null? rk) (reverse acc)
            (let* ((entry (car rk)) (child (car entry)) (cname (cadr entry)) (ke (caddr entry))
                   (decl (and particle (particle-find-decl s particle cname)))
                   (p2 (cons (cons (node-tag child) i) path))
                   (errs
                    (cond
                      (decl (validate-element s decl child p2 ke))
                      ((hash-table-ref-opt (schema-elements s) (ename-key cname))
                       => (lambda (g) (validate-element s g child p2 ke)))
                      (else '()))))
              (loop (cdr rk) (+ i 1) (append (reverse errs) acc))))))

    (define (particle-find-decl s p cname)
      (cond
        ((particle-element? p)
         (cond
           ((and (particle-element-inline p)
                 (ename=? (element-decl-name (particle-element-inline p)) cname))
            (particle-element-inline p))
           ((and (particle-element-ref p) (ename=? (particle-element-ref p) cname))
            (hash-table-ref-opt (schema-elements s) (ename-key cname)))
           (else #f)))
        ((particle-group? p)
         (let loop ((cs (particle-group-children p)))
           (if (null? cs) #f
               (or (particle-find-decl s (car cs) cname) (loop (cdr cs))))))
        (else #f)))

    (define (validate-attrs s attr-decls n path)
      (let ((present (node-attrs n)))
        (append
         ;; required attrs that are missing; fixed-value mismatches
         (append-map
          (lambda (ad)
            (let* ((aname (attr-decl-name ad))
                   (found (assq (ename-local aname) present)))
              (cond
                ((and (not found) (eq? (attr-decl-use ad) 'required))
                 (list (err 'missing-attribute
                            (string-append "missing required attribute "
                                           (symbol->string (ename-local aname))) path)))
                ((not found) '())
                (else
                 (let ((v (attr-value found)))
                   (append
                    (if (and (attr-decl-fixed ad) (not (string=? v (attr-decl-fixed ad))))
                        (list (err 'bad-attribute
                                   (string-append "attribute " (symbol->string (ename-local aname))
                                                  " must be fixed value \"" (attr-decl-fixed ad) "\"")
                                   path)) '())
                    (if (and (attr-decl-enum ad) (not (member v (attr-decl-enum ad))))
                        (list (err 'bad-attribute
                                   (string-append "attribute " (symbol->string (ename-local aname))
                                                  " value \"" v "\" not allowed") path)) '())
                    (if (attr-decl-type ad)
                        (map (lambda (m) (err 'datatype m path))
                             (validate-simple (resolve-type s (attr-decl-type ad)) v))
                        '())))))))
          attr-decls)
         ;; attributes present but not declared (only flag when there ARE decls
         ;; and no attribute wildcard was in play -- P1 keeps it lenient: skip
         ;; xmlns declarations)
         '())))

    ;; append-map with an index
    (define (append-map-indexed f lst)
      (let loop ((lst lst) (i 0) (acc '()))
        (if (null? lst) (reverse acc)
            (loop (cdr lst) (+ i 1) (append (reverse (f (car lst) i)) acc)))))

    ;; Whole-document ID/IDREF cross-check: every ID-typed attribute value must
    ;; be unique; every IDREF/IDREFS token must reference a declared ID. Runs
    ;; as one post-order pass, re-resolving each element's declaration so it
    ;; knows which attributes are ID/IDREF-typed.
    (define (collect-id-idref schema node)
      (let ((ids (make-hash-table)) (errs (vector '())) (refs (vector '())))
        (define (add-err! e) (vector-set! errs 0 (cons e (vector-ref errs 0))))
        (define (add-ref! v tag) (vector-set! refs 0 (cons (cons v tag) (vector-ref refs 0))))
        (define (collect-attr ad n)
          (let ((present (assq (ename-local (attr-decl-name ad)) (node-attrs n)))
                (ty (resolve-type schema (attr-decl-type ad))))
            (if present
                (let ((v (attr-value present)))
                  (case ty
                    ((ID) (if (hash-table-contains? ids v)
                              (add-err! (err 'id-conflict
                                             (string-append "duplicate ID \"" v "\"") '()))
                              (hash-table-set! ids v #t)))
                    ((IDREF) (add-ref! v (node-tag n)))
                    ((IDREFS) (for-each (lambda (tok) (add-ref! tok (node-tag n)))
                                        (string-split (string-trim v) " ")))
                    (else #f))))))
        (define (walk decl n env)
          (let ((ty (resolve-type schema (element-decl-type decl))))
            (if (complex-type? ty)
                (call-with-values (lambda () (effective-content schema ty))
                  (lambda (kind particle attrs)
                    (for-each (lambda (ad) (if (attr-decl? ad) (collect-attr ad n))) attrs)
                    (for-each
                     (lambda (child)
                       (let* ((ke (extend-ns-env env child))
                              (cname (resolve-node-ename child ke))
                              (cdecl (or (and particle (particle-find-decl schema particle cname))
                                         (hash-table-ref-opt (schema-elements schema)
                                                             (ename-key cname)))))
                         (if cdecl (walk cdecl child ke))))
                     (node-child-elements n)))))))
        (let* ((env0 (extend-ns-env '() node))
               (rd (hash-table-ref-opt (schema-elements schema)
                                       (ename-key (resolve-node-ename node env0)))))
          (if rd (walk rd node env0)))
        (for-each (lambda (r)
                    (if (not (hash-table-contains? ids (car r)))
                        (add-err! (err 'idref-dangling
                                       (string-append "IDREF \"" (car r)
                                                      "\" has no matching ID") '()))))
                  (reverse (vector-ref refs 0)))
        (reverse (vector-ref errs 0))))

    ;; ---------------------------------------------------------------------
    ;; Public validation entry points
    ;; ---------------------------------------------------------------------
    (define (validate schema node)
      (if (not (node-element? node))
          (list (err 'malformed "document root is not an element" '()))
          (let* ((env (extend-ns-env '() node))
                 (root-ename (resolve-node-ename node env))
                 (decl (hash-table-ref-opt (schema-elements schema) (ename-key root-ename))))
            (if decl
                (append
                 (validate-element schema decl node (list (cons (node-tag node) 0)) env)
                 (collect-id-idref schema node))
                (list (err 'undeclared
                           (string-append "no declaration for root element <"
                                          (symbol->string (node-tag node)) ">")
                           (list (cons (node-tag node) 0))))))))

    (define (valid? schema node) (null? (validate schema node)))

    (define (validate/raise schema node)
      (let ((errs (validate schema node)))
        (if (null? errs) #t
            (error (string-append "xml-schema: " (validation-error-message (car errs)))))))

    ;; ---------------------------------------------------------------------
    ;; S-expression DSL -> schema
    ;; ---------------------------------------------------------------------
    (define (dsl->schema form)
      (if (or (null? form) (not (eq? (car form) 'schema)))
          (error "dsl->schema: expected (schema ...)" form))
      (let* ((clauses (cdr form))
             (target-ns (dsl-target-ns clauses))
             (s (schema-new target-ns)))
        (for-each
         (lambda (cl)
           (cond
             ((not (pair? cl)) #f)
             ((eq? (car cl) 'target-ns) #f)
             ((eq? (car cl) 'element)
              (schema-register-element! s (dsl-element-decl (cdr cl))))
             ((eq? (car cl) 'simple-type)
              (schema-register-type! s (make-ename target-ns (cadr cl))
                                     (dsl-typespec (caddr cl))))
             (else #f)))
         clauses)
        s))

    (define (dsl-target-ns clauses)
      (let loop ((cs clauses))
        (cond ((null? cs) #f)
              ((and (pair? (car cs)) (eq? (car (car cs)) 'target-ns)) (cadr (car cs)))
              (else (loop (cdr cs))))))

    ;; (element NAME BODY ...) at top level -> element-decl (BODY: (type ..) | (complex ..))
    (define (dsl-element-decl rest)
      (let* ((name (car rest))
             (body (cdr rest))
             (ty (dsl-element-type body)))
        (make-element-decl (make-ename #f name) ty #f #f #f #f #f)))

    (define (dsl-element-type body)
      (cond
        ((null? body) (make-complex-type #f 'empty #f #f '() #f #f #f #f))
        ((eq? (car (car body)) 'type) (dsl-typespec (cadr (car body))))
        ((eq? (car (car body)) 'complex) (dsl-complex (cdr (car body))))
        (else (error "dsl: bad element body" body))))

    ;; (complex PARTICLE ATTR... FLAG...) -> complex-type
    (define (dsl-complex rest)
      (let* ((mixed? (and (memq 'mixed rest) #t))
             (attr-forms (filter (lambda (x) (and (pair? x) (eq? (car x) 'attribute))) rest))
             (particle-forms (filter (lambda (x) (and (pair? x)
                                                      (memq (car x) '(sequence choice all element ref any))))
                                     rest))
             (leaf (cond ((memq 'empty rest) 'empty)
                         ((memq 'pcdata rest) 'pcdata)
                         ((memq 'any rest) 'any)
                         (else #f)))
             (particle (if (null? particle-forms) #f (dsl-particle (car particle-forms))))
             (attrs (map (lambda (a) (dsl-attr (cdr a))) attr-forms))
             (kind (cond ((eq? leaf 'empty) 'empty)
                         ((eq? leaf 'pcdata) 'simple)
                         ((eq? leaf 'any) 'any)
                         (mixed? 'mixed)
                         (else 'element-only))))
        (make-complex-type #f kind particle mixed? attrs #f #f #f #f)))

    ;; occurrence trailing (occurs MIN MAX) in a particle form
    (define (dsl-occurs rest default-min default-max)
      (let ((oc (assq 'occurs (filter pair? rest))))
        (if oc (values (cadr oc) (caddr oc)) (values default-min default-max))))

    (define (dsl-particle form)
      (case (car form)
        ((sequence choice all)
         (call-with-values (lambda () (dsl-occurs (cdr form) 1 1))
           (lambda (mn mx)
             (make-particle-group
              (car form)
              (map dsl-particle
                   (filter (lambda (x) (and (pair? x)
                                            (memq (car x) '(sequence choice all element ref any))))
                           (cdr form)))
              mn mx))))
        ((ref)
         (call-with-values (lambda () (dsl-occurs (cddr form) 1 1))
           (lambda (mn mx)
             (make-particle-element (make-ename #f (cadr form)) #f mn mx))))
        ((element)
         (call-with-values (lambda () (dsl-occurs (cddr form) 1 1))
           (lambda (mn mx)
             (make-particle-element
              #f (dsl-element-decl (cons (cadr form)
                                         (filter (lambda (x) (not (and (pair? x) (eq? (car x) 'occurs))))
                                                 (cddr form))))
              mn mx))))
        ((any)
         (call-with-values (lambda () (dsl-occurs (cdr form) 1 1))
           (lambda (mn mx)
             (let ((nsc (assq 'namespace (filter pair? (cdr form))))
                   (pc (assq 'process (filter pair? (cdr form)))))
               (make-particle-wildcard (if nsc (cadr nsc) 'any)
                                       (if pc (cadr pc) 'strict) mn mx)))))
        (else (error "dsl: bad particle" form))))

    (define (dsl-attr rest)
      (let* ((name (car rest))
             (opts (cdr rest))
             (type-form (assq 'type (filter pair? opts)))
             (use-form (assq 'use (filter pair? opts)))
             (def-form (assq 'default (filter pair? opts)))
             (fix-form (assq 'fixed (filter pair? opts)))
             (enum-form (assq 'enum (filter pair? opts))))
        (make-attr-decl (make-ename #f name)
                        (if type-form (dsl-typespec (cadr type-form)) 'string)
                        (if use-form (cadr use-form) 'optional)
                        (if def-form (cadr def-form) #f)
                        (if fix-form (cadr fix-form) #f)
                        (if enum-form (cdr enum-form) #f))))

    ;; TYPESPEC -> simple-type | builtin-symbol | type-ref
    (define (dsl-typespec spec)
      (cond
        ((symbol? spec)
         (if (builtin-datatype? spec) spec (make-type-ref (make-ename #f spec))))
        ((and (pair? spec) (eq? (car spec) 'restrict))
         (make-simple-type #f 'atomic
                           (let ((b (cadr spec)))
                             (if (builtin-datatype? b) b (make-ename #f b)))
                           (map dsl-facet (cddr spec)) #f '()))
        ((and (pair? spec) (eq? (car spec) 'list))
         (make-simple-type #f 'list 'string '() (dsl-typespec (cadr spec)) '()))
        ((and (pair? spec) (eq? (car spec) 'union))
         (make-simple-type #f 'union 'string '() #f (map dsl-typespec (cdr spec))))
        (else (error "dsl: bad typespec" spec))))

    (define (dsl-facet f)
      (let ((kind (case (car f)
                    ((pattern) 'pattern) ((enumeration enum) 'enumeration)
                    ((length) 'length) ((min-length minLength) 'min-length)
                    ((max-length maxLength) 'max-length)
                    ((min-inclusive minInclusive) 'min-inclusive)
                    ((max-inclusive maxInclusive) 'max-inclusive)
                    ((min-exclusive minExclusive) 'min-exclusive)
                    ((max-exclusive maxExclusive) 'max-exclusive)
                    ((total-digits totalDigits) 'total-digits)
                    ((fraction-digits fractionDigits) 'fraction-digits)
                    ((white-space whiteSpace) 'white-space)
                    (else (car f)))))
        (make-facet kind
                    (if (eq? kind 'enumeration) (cdr f) (cadr f))
                    #f)))))
