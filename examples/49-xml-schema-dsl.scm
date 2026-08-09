;; Declarative XML-schema validation using the S-expression DSL.
;; Author a schema as plain data with (creme xml-schema)'s dsl->schema, then
;; validate parsed documents against it.

(import (scheme base) (scheme write) (creme xml) (creme xml-schema) (creme extra))

;; A schema for <note>: an ordered sequence of children, an optional body, a
;; repeatable <n>, a required id attribute and an enumerated kind attribute.
(define note-schema
  (dsl->schema
    '(schema
       (element note
         (complex (sequence (element to   (type string))
                            (element from (type string))
                            (element body (type string) (occurs 0 1))
                            (element n    (type integer) (occurs 0 unbounded)))
                  (attribute id   (type string) (use required))
                  (attribute kind (enum "memo" "reminder")))))))

(define (check label doc)
  (let ((errs (validate note-schema (xml-read doc))))
    (display label) (display " -> ")
    (if (null? errs)
        (display "valid")
        (begin (display "INVALID: ")
               (for-each (lambda (e)
                           (display "[") (display (validation-error-kind e)) (display "] ")
                           (display (validation-error-message e)) (display "  "))
                         errs)))
    (newline)))

(check "well-formed note"
       "<note id=\"n1\" kind=\"memo\"><to>Ada</to><from>Grace</from><body>hi</body><n>1</n><n>2</n></note>")
(check "minimal note"
       "<note id=\"n2\"><to>Ada</to><from>Grace</from></note>")
(check "missing required id"
       "<note><to>Ada</to><from>Grace</from></note>")
(check "children out of order"
       "<note id=\"n3\"><from>Grace</from><to>Ada</to></note>")
(check "non-integer <n>"
       "<note id=\"n4\"><to>Ada</to><from>Grace</from><n>oops</n></note>")
(check "kind not in enumeration"
       "<note id=\"n5\" kind=\"urgent\"><to>Ada</to><from>Grace</from></note>")
