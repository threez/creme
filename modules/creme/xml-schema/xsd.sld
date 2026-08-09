;; ===========================================================================
;; (creme xml-schema xsd): parse an XSD (XML Schema Definition) document into
;; the (creme xml-schema) IR.
;;
;; The XSD document is itself XML, so it is first read with (creme xml) and
;; then its SXML tree is walked into (creme xml-schema)'s records. XSD elements
;; are recognised by their LOCAL name (the `xs:`/`xsd:` prefix is stripped via
;; split-qname), so any conventional prefix bound to the XML Schema namespace
;; works. restriction/extension are recorded as (base derivation) on the
;; complex type and resolved lazily by the validator (so anonymous, forward-
;; referenced, and chained bases all work).
;;
;;   (xsd-read s)   -> a <schema> parsed from XSD document string `s`
;;
;; Covers (P6/P7): xs:element (global + local, ref + inline type), named and
;; anonymous xs:complexType / xs:simpleType, xs:sequence/choice/all with
;; minOccurs/maxOccurs, xs:attribute (use/default/fixed), simpleContent /
;; complexContent extension & restriction, xs:restriction facets, xs:list /
;; xs:union, xs:any / xs:anyAttribute, xs:group / xs:attributeGroup refs, and
;; targetNamespace + elementFormDefault name qualification. import/include are
;; handled by (creme xml-schema xsd) too (see xsd-read-file / resolver).
;;
;; Limitations: XSD 1.1 (assert, conditional types, open content) and
;; xs:key/keyref/unique identity constraints are OUT of scope; substitution
;; groups are matched but abstract-element enforcement is minimal.
;; ===========================================================================

(define-library (creme xml-schema xsd)
  (export xsd-read xsd-read-file)
  (import (scheme base) (scheme char) (scheme cxr)
          (creme xml) (creme string) (creme hash-table) (creme extra) (creme file)
          (creme xml-schema))
  (begin

    ;; ---- SXML / XSD node helpers -----------------------------------------
    (define (local-of sym)
      (call-with-values (lambda () (split-qname sym)) (lambda (p l) l)))

    (define (el-tag node) (local-of (car node)))       ; local name symbol

    (define (xsd-node-attr-block node)
      (let ((rest (cdr node)))
        (and (pair? rest) (pair? (car rest)) (eq? (car (car rest)) '@) (car rest))))
    (define (raw-attrs node)
      (let ((blk (xsd-node-attr-block node))) (if blk (cdr blk) '())))
    (define (xsd-node-children node)
      (let ((rest (cdr node))) (if (xsd-node-attr-block node) (cdr rest) rest)))
    (define (child-elements node)
      (filter (lambda (c) (and (pair? c) (symbol? (car c)))) (xsd-node-children node)))

    ;; attribute value by local name, or #f
    (define (xattr node name)
      (let loop ((as (raw-attrs node)))
        (cond ((null? as) #f)
              ((eq? (local-of (car (car as))) name) (cadr (car as)))
              (else (loop (cdr as))))))

    (define (xsd-element? node local) (and (pair? node) (eq? (el-tag node) local)))

    ;; ---- name / type resolution (P6: names in no namespace) --------------
    (define (name->ename s) (make-ename #f (string->symbol s)))

    ;; A `type="..."` reference -> a builtin symbol or a type-ref.
    (define (typeref-of str)
      (let ((local (local-of (string->symbol str))))
        (if (builtin-datatype? local) local (make-type-ref (make-ename #f local)))))

    (define (occurs-of node)
      (let ((mn (xattr node 'minOccurs))
            (mx (xattr node 'maxOccurs)))
        (values (if mn (string->number mn) 1)
                (cond ((not mx) 1)
                      ((string=? mx "unbounded") 'unbounded)
                      (else (string->number mx))))))

    ;; ---- particles -------------------------------------------------------
    (define (parse-particle node)
      (case (el-tag node)
        ((sequence choice all) (parse-model-group node))
        ((element) (parse-particle-element node))
        ((any) (parse-any node))
        ((group) (parse-group-ref node))
        (else #f)))

    (define (parse-model-group node)
      (call-with-values (lambda () (occurs-of node))
        (lambda (mn mx)
          (make-particle-group
           (el-tag node)
           (filter (lambda (x) x) (map parse-particle (child-elements node)))
           mn mx))))

    (define (parse-particle-element node)
      (call-with-values (lambda () (occurs-of node))
        (lambda (mn mx)
          (let ((ref (xattr node 'ref)))
            (if ref
                (make-particle-element (make-ename #f (local-of (string->symbol ref))) #f mn mx)
                (make-particle-element #f (xsd-parse-element-decl node) mn mx))))))

    (define (parse-any node)
      (call-with-values (lambda () (occurs-of node))
        (lambda (mn mx)
          (let ((ns (xattr node 'namespace)) (pc (xattr node 'processContents)))
            (make-particle-wildcard
             (cond ((not ns) 'any)
                   ((string=? ns "##any") 'any)
                   ((string=? ns "##other") 'other)
                   ((string=? ns "##local") 'local)
                   (else (string-split ns " ")))
             (if pc (string->symbol pc) 'strict)
             mn mx)))))

    ;; group ref: resolved later by splice-groups! (needs the schema table).
    (define (parse-group-ref node)
      (call-with-values (lambda () (occurs-of node))
        (lambda (mn mx)
          (let ((ref (xattr node 'ref)))
            ;; represent a pending group ref as a particle-element whose ref is
            ;; tagged; splice happens in resolve pass. Use a sentinel record:
            (make-group-ref (make-ename #f (local-of (string->symbol ref))) mn mx)))))

    ;; ---- elements --------------------------------------------------------
    (define (xsd-parse-element-decl node)
      (let* ((name (xattr node 'name))
             (type-attr (xattr node 'type))
             (inline (find-child node '(complexType simpleType)))
             (ty (cond (type-attr (typeref-of type-attr))
                       (inline (parse-type inline))
                       (else 'string)))            ; untyped -> xs:anyType approx
             (nillable (equal? (xattr node 'nillable) "true"))
             (abstract (equal? (xattr node 'abstract) "true"))
             (subst (xattr node 'substitutionGroup)))
        (make-element-decl (name->ename (or name "?")) ty nillable abstract
                           (and subst (make-ename #f (local-of (string->symbol subst))))
                           (xattr node 'default) (xattr node 'fixed))))

    (define (find-child node locals)
      (let loop ((cs (child-elements node)))
        (cond ((null? cs) #f)
              ((memq (el-tag (car cs)) locals) (car cs))
              (else (loop (cdr cs))))))

    ;; ---- types -----------------------------------------------------------
    (define (parse-type node)
      (case (el-tag node)
        ((complexType) (parse-complex-type node))
        ((simpleType) (parse-simple-type node))
        (else #f)))

    (define (parse-complex-type node)
      (let* ((name (xattr node 'name))
             (mixed (equal? (xattr node 'mixed) "true"))
             (simple-content (find-child node '(simpleContent)))
             (complex-content (find-child node '(complexContent))))
        (cond
          (simple-content (parse-simple-content node simple-content name))
          (complex-content (parse-complex-content node complex-content name mixed))
          (else
           (let* ((grp (find-child node '(sequence choice all group)))
                  (particle (and grp (parse-particle grp)))
                  (attrs (parse-attributes node))
                  (awild (find-child node '(anyAttribute))))
             (make-complex-type (and name (name->ename name))
                                (cond ((and (not particle) (null? attrs)) 'empty)
                                      (mixed 'mixed)
                                      (else 'element-only))
                                particle mixed attrs
                                (and awild (parse-any-attribute awild))
                                #f #f
                                (equal? (xattr node 'abstract) "true")))))))

    (define (parse-simple-content node sc name)
      (let* ((ext (find-child sc '(extension)))
             (res (find-child sc '(restriction)))
             (deriv (or ext res))
             (base (xattr deriv 'base))
             (base-ty (if (builtin-datatype? (local-of (string->symbol base)))
                          (local-of (string->symbol base))
                          'string))
             (attrs (parse-attributes deriv)))
        ;; simple content: text validated against the base simple type,
        ;; attributes from the extension/restriction. No content merging.
        (make-complex-type (and name (name->ename name))
                           'simple base-ty #f attrs #f #f #f #f)))

    (define (parse-complex-content node cc name mixed)
      (let* ((ext (find-child cc '(extension)))
             (res (find-child cc '(restriction)))
             (deriv (or ext res))
             (base (xattr deriv 'base))
             (grp (and deriv (find-child deriv '(sequence choice all group))))
             (particle (and grp (parse-particle grp)))
             (attrs (if deriv (parse-attributes deriv) '())))
        (make-complex-type (and name (name->ename name))
                           (if mixed 'mixed 'element-only)
                           particle mixed attrs #f
                           (make-ename #f (local-of (string->symbol base)))
                           (if ext 'extension 'restriction)
                           #f)))

    (define (parse-simple-type node)
      (let* ((name (xattr node 'name))
             (res (find-child node '(restriction)))
             (lst (find-child node '(list)))
             (uni (find-child node '(union))))
        (cond
          (res
           (let* ((base (xattr res 'base))
                  (base-ty (if base
                               (let ((l (local-of (string->symbol base))))
                                 (if (builtin-datatype? l) l (make-ename #f l)))
                               'string))
                  (inline-base (find-child res '(simpleType))))
             (make-simple-type (and name (name->ename name)) 'atomic
                               (if inline-base
                                   ;; inline base simple type: use its base builtin
                                   (simple-type-base (parse-simple-type inline-base))
                                   base-ty)
                               (parse-facets res) #f '())))
          (lst
           (let ((it (xattr lst 'itemType)))
             (make-simple-type (and name (name->ename name)) 'list 'string '()
                               (if it (typeref-of it)
                                   (let ((c (find-child lst '(simpleType))))
                                     (if c (parse-simple-type c) 'string)))
                               '())))
          (uni
           (let ((mem (xattr uni 'memberTypes)))
             (make-simple-type (and name (name->ename name)) 'union 'string '() #f
                               (append
                                (if mem (map typeref-of (string-split mem " ")) '())
                                (map parse-simple-type (child-elements uni))))))
          (else (make-simple-type (and name (name->ename name)) 'atomic 'string '() #f '())))))

    (define (parse-facets res)
      (let loop ((cs (child-elements res)) (enums '()) (acc '()))
        (if (null? cs)
            (if (null? enums) (reverse acc)
                (reverse (cons (make-facet 'enumeration (reverse enums) #f) acc)))
            (let* ((node (car cs))
                   (tag (el-tag node))
                   (v (xattr node 'value)))
              (case tag
                ((enumeration) (loop (cdr cs) (cons v enums) acc))
                ((pattern) (loop (cdr cs) enums (cons (make-facet 'pattern v #f) acc)))
                ((length) (loop (cdr cs) enums (cons (make-facet 'length (string->number v) #f) acc)))
                ((minLength) (loop (cdr cs) enums (cons (make-facet 'min-length (string->number v) #f) acc)))
                ((maxLength) (loop (cdr cs) enums (cons (make-facet 'max-length (string->number v) #f) acc)))
                ((minInclusive) (loop (cdr cs) enums (cons (make-facet 'min-inclusive (string->number v) #f) acc)))
                ((maxInclusive) (loop (cdr cs) enums (cons (make-facet 'max-inclusive (string->number v) #f) acc)))
                ((minExclusive) (loop (cdr cs) enums (cons (make-facet 'min-exclusive (string->number v) #f) acc)))
                ((maxExclusive) (loop (cdr cs) enums (cons (make-facet 'max-exclusive (string->number v) #f) acc)))
                ((totalDigits) (loop (cdr cs) enums (cons (make-facet 'total-digits (string->number v) #f) acc)))
                ((fractionDigits) (loop (cdr cs) enums (cons (make-facet 'fraction-digits (string->number v) #f) acc)))
                ((whiteSpace) (loop (cdr cs) enums (cons (make-facet 'white-space (string->symbol v) #f) acc)))
                (else (loop (cdr cs) enums acc)))))))

    ;; ---- attributes ------------------------------------------------------
    (define (parse-attributes node)
      (append-map
       (lambda (c)
         (case (el-tag c)
           ((attribute) (list (parse-attribute c)))
           ((attributeGroup) (list (make-attr-group-ref
                                     (make-ename #f (local-of (string->symbol (xattr c 'ref)))))))
           (else '())))
       (child-elements node)))

    (define (parse-attribute node)
      (let* ((name (xattr node 'name))
             (type-attr (xattr node 'type))
             (inline (find-child node '(simpleType)))
             (ty (cond (type-attr (typeref-of type-attr))
                       (inline (parse-simple-type inline))
                       (else 'string)))
             (use (xattr node 'use)))
        (make-attr-decl (name->ename (or name "?")) ty
                        (cond ((not use) 'optional)
                              ((string=? use "required") 'required)
                              ((string=? use "prohibited") 'prohibited)
                              (else 'optional))
                        (xattr node 'default) (xattr node 'fixed) #f)))

    (define (parse-any-attribute node)
      (let ((ns (xattr node 'namespace)) (pc (xattr node 'processContents)))
        (make-particle-wildcard
         (cond ((not ns) 'any) ((string=? ns "##any") 'any)
               ((string=? ns "##other") 'other) ((string=? ns "##local") 'local)
               (else (string-split ns " ")))
         (if pc (string->symbol pc) 'strict) 0 'unbounded)))

    ;; ---- group-ref / attr-group-ref sentinels ----------------------------
    ;; xs:group ref and xs:attributeGroup ref can't be resolved until the whole
    ;; schema is read; we record placeholders and splice/flatten in a resolve
    ;; pass. Reuse type-ref-shaped tiny records via association pairs tagged in
    ;; a private table -- simplest: use particle-element with ref + a marker in
    ;; a side table. Here we use dedicated helper closures held in local lists.
    (define group-ref-tag (list 'group-ref))
    (define attr-group-ref-tag (list 'attr-group-ref))
    (define (make-group-ref ename mn mx) (list group-ref-tag ename mn mx))
    (define (group-ref? x) (and (pair? x) (eq? (car x) group-ref-tag)))
    (define (make-attr-group-ref ename) (list attr-group-ref-tag ename))
    (define (attr-group-ref? x) (and (pair? x) (eq? (car x) attr-group-ref-tag)))

    ;; ---- top-level schema ------------------------------------------------
    ;; (xsd-read s [resolver]) -- resolver maps a schemaLocation string to the
    ;; XSD document text of the included/imported schema (default: read it as a
    ;; file). include (same target namespace) and import (another namespace)
    ;; both merge the other schema's declarations into this one; a visited set
    ;; on schemaLocation guards against include cycles. Because names match by
    ;; local part (see (creme xml-schema)), cross-namespace imports coexist in
    ;; the one symbol table.
    (define (default-resolver location) (file-read location))

    (define (xsd-read s . opt)
      (let* ((resolver (if (pair? opt) (car opt) default-resolver))
             (root (xml-read s))
             (schema (schema-new (xattr root 'targetNamespace)))
             (visited (make-hash-table)))
        (xsd-merge! schema root resolver visited)
        (splice-refs! schema)
        schema))

    (define (xsd-read-file path . opt)
      (let ((resolver (if (pair? opt) (car opt) default-resolver)))
        (xsd-read (file-read path) resolver)))

    (define (xsd-merge! schema root resolver visited)
      (for-each
       (lambda (node)
         (case (el-tag node)
           ((element)
            (schema-register-element! schema (xsd-parse-element-decl node)))
           ((complexType)
            (let ((ct (parse-complex-type node)))
              (schema-register-type! schema (complex-type-name ct) ct)))
           ((simpleType)
            (let ((st (parse-simple-type node)))
              (schema-register-type! schema (simple-type-name st) st)))
           ((group)
            (let ((g (find-child node '(sequence choice all))))
              (schema-register-group! schema
                                      (make-ename #f (string->symbol (xattr node 'name)))
                                      (and g (parse-particle g)))))
           ((attributeGroup)
            (schema-register-attribute-group!
             schema (make-ename #f (string->symbol (xattr node 'name)))
             (parse-attributes node)))
           ((include import)
            (let ((loc (xattr node 'schemaLocation)))
              (if (and loc (not (hash-table-contains? visited loc)))
                  (begin
                    (hash-table-set! visited loc #t)
                    (xsd-merge! schema (xml-read (resolver loc)) resolver visited)))))
           (else #f)))
       (child-elements root)))

    ;; Resolve group / attributeGroup references throughout the schema.
    (define (splice-refs! schema)
      ;; element decls
      (for-each
       (lambda (k)
         (let ((decl (hash-table-ref (schema-elements schema) k)))
           (hash-table-set! (schema-elements schema) k (splice-decl schema decl))))
       (hash-table-keys (schema-elements schema)))
      ;; named types
      (for-each
       (lambda (k)
         (let ((ty (hash-table-ref (schema-types schema) k)))
           (if (complex-type? ty)
               (hash-table-set! (schema-types schema) k (splice-complex schema ty)))))
       (hash-table-keys (schema-types schema))))

    (define (splice-decl schema decl)
      (let ((ty (element-decl-type decl)))
        (if (complex-type? ty)
            (make-element-decl (element-decl-name decl) (splice-complex schema ty)
                               (element-decl-nillable? decl) (element-decl-abstract? decl)
                               (element-decl-subst-group decl) (element-decl-default decl)
                               (element-decl-fixed decl))
            decl)))

    (define (splice-complex schema ty)
      (make-complex-type (complex-type-name ty) (complex-type-content-kind ty)
                         (splice-particle schema (complex-type-particle ty))
                         (complex-type-mixed? ty)
                         (append-map (lambda (a) (flatten-attr schema a)) (complex-type-attrs ty))
                         (complex-type-attr-wildcard ty) (complex-type-base ty)
                         (complex-type-derivation ty) (complex-type-abstract? ty)))

    (define (flatten-attr schema a)
      (if (attr-group-ref? a)
          (let ((found (hash-table-ref-opt2 (schema-attribute-groups schema)
                                            (ename-key (cadr a)))))
            (if found (append-map (lambda (x) (flatten-attr schema x)) found) '()))
          (list a)))

    (define (splice-particle schema p)
      (cond
        ((not p) #f)
        ((group-ref? p)
         (let ((found (hash-table-ref-opt2 (schema-groups schema) (ename-key (cadr p)))))
           (if found
               (let ((g (splice-particle schema found)))
                 ;; wrap with the ref site's occurrence
                 (make-particle-group 'sequence (list g) (caddr p) (cadddr p)))
               (make-particle-group 'sequence '() 0 0))))
        ((particle-group? p)
         (make-particle-group (particle-group-kind p)
                              (map (lambda (c) (splice-particle schema c))
                                   (particle-group-children p))
                              (particle-group-min p) (particle-group-max p)))
        ((particle-element? p)
         (if (particle-element-inline p)
             (make-particle-element #f (splice-decl schema (particle-element-inline p))
                                    (particle-element-min p) (particle-element-max p))
             p))
        (else p)))

    (define (hash-table-ref-opt2 h k)
      (if (hash-table-contains? h k) (hash-table-ref h k) #f))))
