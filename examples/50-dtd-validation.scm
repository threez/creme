;; Validate XML documents against a real DTD, parsed with (creme xml-schema dtd).

(import (scheme base) (scheme write) (creme xml) (creme xml-schema)
        (creme xml-schema dtd) (creme extra))

(define note-dtd
  (string-append
   "<!ELEMENT note (to, from, body?)>"
   "<!ELEMENT to   (#PCDATA)>"
   "<!ELEMENT from (#PCDATA)>"
   "<!ELEMENT body (#PCDATA)>"
   "<!ATTLIST note"
   "  id   ID       #REQUIRED"
   "  prio (low|high) #IMPLIED"
   "  ver  CDATA    #FIXED \"1.0\">"))

(define schema (dtd-read note-dtd))

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

(check "conforming"
       "<note id=\"a1\" prio=\"high\"><to>Ada</to><from>Grace</from><body>hi</body></note>")
(check "optional body omitted"
       "<note id=\"a2\"><to>Ada</to><from>Grace</from></note>")
(check "missing #REQUIRED id"
       "<note><to>Ada</to><from>Grace</from></note>")
(check "prio not in (low|high)"
       "<note id=\"a3\" prio=\"urgent\"><to>Ada</to><from>Grace</from></note>")
(check "#FIXED ver violated"
       "<note id=\"a4\" ver=\"2.0\"><to>Ada</to><from>Grace</from></note>")
(check "wrong child order"
       "<note id=\"a5\"><from>Grace</from><to>Ada</to></note>")
