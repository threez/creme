;; Validate XML documents against an XSD schema, parsed with
;; (creme xml-schema xsd). Exercises complexType, a simpleType facet, an
;; unbounded element, a required attribute, and xs:include via an in-memory
;; resolver (so the example needs no files on disk).

(import (scheme base) (scheme write) (creme xml) (creme xml-schema)
        (creme xml-schema xsd) (creme extra))

;; The "types" schema that the main schema includes.
(define types-xsd
  (string-append
   "<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">"
   "  <xs:complexType name=\"Money\">"
   "    <xs:simpleContent><xs:extension base=\"xs:decimal\">"
   "      <xs:attribute name=\"currency\" type=\"xs:string\" use=\"required\"/>"
   "    </xs:extension></xs:simpleContent>"
   "  </xs:complexType>"
   "</xs:schema>"))

;; Resolve schemaLocation "types.xsd" from memory rather than from disk.
(define (resolver location)
  (if (string=? location "types.xsd") types-xsd
      (error "unknown schemaLocation" location)))

(define book-xsd
  (string-append
   "<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">"
   "  <xs:include schemaLocation=\"types.xsd\"/>"
   "  <xs:element name=\"book\"><xs:complexType><xs:sequence>"
   "    <xs:element name=\"title\" type=\"xs:string\"/>"
   "    <xs:element name=\"author\" type=\"xs:string\" maxOccurs=\"unbounded\"/>"
   "    <xs:element name=\"year\"><xs:simpleType><xs:restriction base=\"xs:integer\">"
   "      <xs:minInclusive value=\"1450\"/><xs:maxInclusive value=\"2100\"/>"
   "    </xs:restriction></xs:simpleType></xs:element>"
   "    <xs:element name=\"price\" type=\"Money\" minOccurs=\"0\"/>"
   "  </xs:sequence>"
   "  <xs:attribute name=\"isbn\" type=\"xs:string\" use=\"required\"/>"
   "  </xs:complexType></xs:element>"
   "</xs:schema>"))

(define schema (xsd-read book-xsd resolver))

(define (check label doc)
  (let ((errs (validate schema (xml-read doc))))
    (display label) (display " -> ")
    (if (null? errs)
        (display "valid")
        (begin (display "INVALID: ")
               (for-each (lambda (e)
                           (display "[") (display (validation-error-kind e)) (display "] ")
                           (display (validation-error-message e)) (display "  "))
                         errs)))
    (newline)))

(check "conforming book"
       "<book isbn=\"978-0\"><title>SICP</title><author>Abelson</author><author>Sussman</author><year>1985</year><price currency=\"USD\">42.00</price></book>")
(check "no price (optional)"
       "<book isbn=\"978-1\"><title>T</title><author>A</author><year>2000</year></book>")
(check "missing required isbn"
       "<book><title>T</title><author>A</author><year>2000</year></book>")
(check "year below minInclusive"
       "<book isbn=\"978-2\"><title>T</title><author>A</author><year>1000</year></book>")
(check "price missing required currency"
       "<book isbn=\"978-3\"><title>T</title><author>A</author><year>2000</year><price>9.99</price></book>")
