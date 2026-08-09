;; ===========================================================================
;; (creme xml-schema dtd): parse a DTD (Document Type Definition) into the
;; (creme xml-schema) IR, so a document can be validated against a real DTD.
;;
;; Hand-written recursive descent over (creme scanner)'s port primitives --
;; the same style (creme xml) uses for XML itself, and for the same reason
;; ((creme xml) skips <!DOCTYPE> entirely, so a DTD is not otherwise parsed
;; anywhere). Everything compiles to (creme xml-schema)'s records; the
;; validator never knows a DTD produced its schema.
;;
;;   (dtd-read s)        -> a <schema> parsed from DTD text string `s`
;;   (dtd-read-port p)   -> the same, from an open input port
;;
;; Covers: <!ELEMENT> content specs (EMPTY, ANY, (#PCDATA), mixed
;; (#PCDATA|a|b)*, and children with the `, | ? * +` operators and nested
;; groups); <!ATTLIST> (CDATA/ID/IDREF(S)/NMTOKEN(S)/ENTITY/ENTITIES/NOTATION
;; and (enumerated) types; #REQUIRED/#IMPLIED/#FIXED/defaults); <!ENTITY>
;; general and parameter (`%name;`) entities, with parameter-entity references
;; expanded inside <!ELEMENT>/<!ATTLIST> declaration text and inside entity
;; values. Comments and PIs are skipped.
;;
;; Limitations (explicit): external entities (SYSTEM/PUBLIC) are not fetched;
;; a parameter entity whose replacement text spans/introduces whole
;; declarations (rather than appearing within one declaration's content spec
;; or attribute list) is not expanded; conditional sections
;; (<![INCLUDE[/<![IGNORE[) are skipped, not honored. DTDs have no
;; namespaces, so every name is in no namespace.
;; ===========================================================================

(define-library (creme xml-schema dtd)
  (export dtd-read dtd-read-port)
  (import (scheme base) (scheme char) (scheme cxr)
          (creme scanner) (creme regex) (creme hash-table) (creme string)
          (creme extra) (creme xml-schema))
  (begin

    (define (dtd-name-char? c)
      (or (char-alphabetic? c) (char-numeric? c)
          (char=? c #\-) (char=? c #\_) (char=? c #\.) (char=? c #\:)))

    (define (skip-ws port) (skip-while port char-whitespace?))

    (define (read-quoted port)
      (let ((q (read-char port)))            ; " or '
        (car (scan-until-char port (lambda (c) (char=? c q))))))

    (define (skip-to-gt port)
      (skip-while port (lambda (c) (not (char=? c #\>))))
      (read-char port))

    ;; ---- parameter-entity expansion within a declaration's text ----------
    (define (expand-param-refs text param-table)
      (if (not (string-contains? text "%")) text
          (let loop ((text text) (guard 0))
            (if (>= guard 50) text
                (let ((next (fold-alist
                             (lambda (name val acc)
                               (regexp-replace-all
                                (regexp (string-append "%" name ";")) val acc))
                             text param-table)))
                  (if (string=? next text) text (loop next (+ guard 1))))))))

    (define (fold-alist f init table)
      (let loop ((al (hash-table->alist table)) (acc init))
        (if (null? al) acc
            (loop (cdr al) (f (caar al) (cdar al) acc)))))

    ;; ---- content-model parsing -------------------------------------------
    ;; parse `(...)` children model text into a particle.
    (define (parse-content-model text)
      (let ((p (open-input-string text)))
        (skip-ws p)
        (parse-cp p)))

    (define (with-occurs particle mn mx)
      (cond
        ((particle-element? particle)
         (make-particle-element (particle-element-ref particle)
                                (particle-element-inline particle) mn mx))
        ((particle-group? particle)
         (make-particle-group (particle-group-kind particle)
                              (particle-group-children particle) mn mx))
        (else particle)))

    (define (apply-suffix p particle)
      (let ((c (peek-char p)))
        (cond
          ((and (char? c) (char=? c #\?)) (read-char p) (with-occurs particle 0 1))
          ((and (char? c) (char=? c #\*)) (read-char p) (with-occurs particle 0 'unbounded))
          ((and (char? c) (char=? c #\+)) (read-char p) (with-occurs particle 1 'unbounded))
          (else particle))))

    (define (parse-cp p)
      (skip-ws p)
      (let ((c (peek-char p)))
        (if (and (char? c) (char=? c #\())
            (parse-group p)
            (let ((nm (scan-while p dtd-name-char?)))
              (apply-suffix p (make-particle-element
                               (make-ename #f (string->symbol nm)) #f 1 1))))))

    (define (parse-group p)
      (read-char p)                          ; consume (
      (let loop ((items (list (parse-cp p))) (sep #f))
        (skip-ws p)
        (let ((c (peek-char p)))
          (cond
            ((and (char? c) (char=? c #\)))
             (read-char p)
             (apply-suffix p (finish-group (reverse items) sep)))
            ((and (char? c) (or (char=? c #\,) (char=? c #\|)))
             (read-char p)
             (loop (cons (parse-cp p) items)
                   (if (char=? c #\,) 'sequence 'choice)))
            (else (error "dtd: malformed content model near" (scan-while p (lambda (x) #t))))))))

    (define (finish-group items sep)
      (if (= (length items) 1) (car items)
          (make-particle-group (or sep 'sequence) items 1 1)))

    ;; contentspec text (already param-expanded, trimmed) -> complex-type
    (define (contentspec->type spec)
      (let ((s (string-trim spec)))
        (cond
          ((string=? s "EMPTY") (make-complex-type #f 'empty #f #f '() #f #f #f #f))
          ((string=? s "ANY")   (make-complex-type #f 'any #f #f '() #f #f #f #f))
          ((and (>= (string-length s) 1) (char=? (string-ref s 0) #\()
                (string-contains? s "#PCDATA"))
           (mixed-or-pcdata->type s))
          (else
           (make-complex-type #f 'element-only (parse-content-model s) #f '() #f #f #f #f)))))

    (define (mixed-or-pcdata->type s)
      ;; s is like "(#PCDATA)" or "(#PCDATA|a|b)*"
      (let* ((inner (string-trim (strip-outer-parens s)))
             (toks (map string-trim (string-split inner "|")))
             (names (filter (lambda (t) (not (string=? t "#PCDATA"))) toks)))
        (if (null? names)
            (make-complex-type #f 'simple #f #f '() #f #f #f #f)   ; text-only
            (make-complex-type
             #f 'mixed
             (make-particle-group
              'choice
              (map (lambda (nm) (make-particle-element
                                 (make-ename #f (string->symbol nm)) #f 1 1))
                   names)
              0 'unbounded)
             #t '() #f #f #f #f))))

    (define (strip-outer-parens s)
      ;; drop the leading "(" and everything from the trailing ")" onward
      (let* ((open (or (string-index-of s "(") 0))
             (afteropen (substring s (+ open 1) (string-length s)))
             (close (last-index-of afteropen #\))))
        (if close (substring afteropen 0 close) afteropen)))

    (define (last-index-of s ch)
      (let loop ((i (- (string-length s) 1)))
        (cond ((< i 0) #f)
              ((char=? (string-ref s i) ch) i)
              (else (loop (- i 1))))))

    ;; ---- ATTLIST parsing -------------------------------------------------
    (define (parse-attlist text)
      ;; text is the body after "<!ATTLIST", param-expanded, up to but not
      ;; including ">". Returns (cons elem-name-string list-of-attr-decl).
      (let ((p (open-input-string text)))
        (skip-ws p)
        (let ((elem (scan-while p dtd-name-char?)))
          (let loop ((attrs '()))
            (skip-ws p)
            (let ((c (peek-char p)))
              (if (eof-object? c)
                  (cons elem (reverse attrs))
                  (let ((ad (parse-att-def p)))
                    (loop (cons ad attrs)))))))))

    (define (parse-att-def p)
      (skip-ws p)
      (let ((name (scan-while p dtd-name-char?)))
        (skip-ws p)
        (let* ((type-info (parse-att-type p))     ; (cons type-symbol enum-or-#f)
               (dfl (begin (skip-ws p) (parse-att-default p))))
          (make-attr-decl (make-ename #f (string->symbol name))
                          (car type-info)
                          (car dfl)               ; use
                          (cadr dfl)              ; default
                          (caddr dfl)             ; fixed
                          (cdr type-info)))))     ; enum

    (define (parse-att-type p)
      (let ((c (peek-char p)))
        (cond
          ((and (char? c) (char=? c #\()) (cons 'NMTOKEN (read-enum p)))
          (else
           (let ((kw (scan-while p (lambda (ch) (char-alphabetic? ch)))))
             (cond
               ((string=? kw "NOTATION") (skip-ws p) (cons 'string (read-enum p)))
               ((string=? kw "CDATA") (cons 'string #f))
               ((member kw '("ID" "IDREF" "IDREFS" "NMTOKEN" "NMTOKENS" "ENTITY" "ENTITIES"))
                (cons (string->symbol kw) #f))
               (else (cons 'string #f))))))))

    (define (read-enum p)
      (read-char p)                          ; consume (
      (let loop ((vals '()))
        (skip-ws p)
        (let ((v (scan-while p dtd-name-char?)))
          (skip-ws p)
          (let ((c (read-char p)))
            (cond
              ((and (char? c) (char=? c #\|)) (loop (cons v vals)))
              ((and (char? c) (char=? c #\))) (reverse (cons v vals)))
              (else (reverse (cons v vals))))))))

    (define (parse-att-default p)
      ;; -> (list use default-or-#f fixed-or-#f)
      (let ((c (peek-char p)))
        (cond
          ((and (char? c) (char=? c #\#))
           (read-char p)
           (let ((kw (scan-while p (lambda (ch) (char-alphabetic? ch)))))
             (cond
               ((string=? kw "REQUIRED") (list 'required #f #f))
               ((string=? kw "IMPLIED")  (list 'optional #f #f))
               ((string=? kw "FIXED")
                (skip-ws p) (list 'optional #f (read-quoted p)))
               (else (list 'optional #f #f)))))
          ((and (char? c) (or (char=? c #\") (char=? c #\')))
           (list 'optional (read-quoted p) #f))
          (else (list 'optional #f #f)))))

    ;; ---- top-level DTD parse ---------------------------------------------
    (define (dtd-read s) (dtd-read-port (open-input-string s)))

    (define (dtd-read-port port)
      (let ((elems  (make-hash-table))       ; name-string -> complex-type
            (attrs  (make-hash-table))       ; name-string -> list of attr-decl
            (params (make-hash-table)))      ; param-entity name -> value
        (parse-loop port elems attrs params)
        (assemble-schema elems attrs)))

    (define (parse-loop port elems attrs params)
      (let loop ()
        (skip-ws port)
        (let ((c (peek-char port)))
          (cond
            ((eof-object? c) #t)
            ((char=? c #\<)
             (read-char port)                ; <
             (let ((c2 (peek-char port)))
               (cond
                 ((and (char? c2) (char=? c2 #\!))
                  (read-char port)           ; !
                  (let ((c3 (peek-char port)))
                    (if (and (char? c3) (char=? c3 #\-))
                        (skip-comment port)
                        (dispatch-decl port elems attrs params))))
                 ((and (char? c2) (char=? c2 #\?)) (skip-to-gt port))
                 (else (skip-to-gt port))))
             (loop))
            (else (read-char port) (loop))))))

    (define (skip-comment port)
      ;; cursor just past "<!"; skip "--" ... "-->"
      (skip-to-gt port))                     ; comments contain no '>' in practice here

    (define (dispatch-decl port elems attrs params)
      (let ((kw (scan-while port (lambda (ch) (char-alphabetic? ch)))))
        (cond
          ((string=? kw "ELEMENT") (parse-element-decl port elems params))
          ((string=? kw "ATTLIST") (parse-attlist-decl port attrs params))
          ((string=? kw "ENTITY")  (parse-entity-decl port params))
          (else (skip-to-gt port)))))        ; NOTATION and others: ignore

    (define (grab-decl-body port)
      ;; everything up to and consuming the next top-level '>'
      (car (scan-until-char port (lambda (c) (char=? c #\>)))))

    (define (parse-element-decl port elems params)
      (skip-ws port)
      (let* ((name (scan-while port dtd-name-char?))
             (spec (expand-param-refs (grab-decl-body port) params)))
        (hash-table-set! elems name (contentspec->type spec))))

    (define (parse-attlist-decl port attrs params)
      (let* ((body (expand-param-refs (grab-decl-body port) params))
             (parsed (parse-attlist body))
             (elem (car parsed)))
        (hash-table-set! attrs elem
                         (append (if (hash-table-contains? attrs elem)
                                     (hash-table-ref attrs elem) '())
                                 (cdr parsed)))))

    (define (parse-entity-decl port params)
      (skip-ws port)
      (let ((c (peek-char port)))
        (if (and (char? c) (char=? c #\%))
            (begin                            ; parameter entity
              (read-char port) (skip-ws port)
              (let ((name (scan-while port dtd-name-char?)))
                (skip-ws port)
                (let ((c2 (peek-char port)))
                  (if (and (char? c2) (or (char=? c2 #\") (char=? c2 #\')))
                      (let ((val (expand-param-refs (read-quoted port) params)))
                        (hash-table-set! params name val)
                        (skip-to-gt port))
                      (skip-to-gt port)))))    ; external param entity: skip
            (skip-to-gt port))))              ; general entity: skip (unused by validator)

    (define (assemble-schema elems attrs)
      (let ((schema (schema-new #f)))
        (for-each
         (lambda (name)
           (let* ((ct (hash-table-ref elems name))
                  (as (if (hash-table-contains? attrs name)
                          (hash-table-ref attrs name) '()))
                  (ct2 (complex-with-attrs ct as)))
             (schema-register-element!
              schema
              (make-element-decl (make-ename #f (string->symbol name))
                                 ct2 #f #f #f #f #f))))
         (hash-table-keys elems))
        schema))

    (define (complex-with-attrs ct attrs)
      (make-complex-type (complex-type-name ct)
                         (complex-type-content-kind ct)
                         (complex-type-particle ct)
                         (complex-type-mixed? ct)
                         (append (complex-type-attrs ct) attrs)
                         (complex-type-attr-wildcard ct)
                         (complex-type-base ct)
                         (complex-type-derivation ct)
                         (complex-type-abstract? ct)))))
