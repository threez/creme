;; ===========================================================================
;; (creme spec)-based cross-backend tests for (creme xml-schema) and its DTD /
;; XSD readers. Runs under all three backends:
;;   ./bin/creme spec/creme/xml-schema_spec.scm
;;   ./bin/creme --self-hosted spec/creme/xml-schema_spec.scm
;;   ./icecreme/icecreme spec/creme/xml-schema_spec.scm
;; See modules/creme/spec.sld for the framework.
;; ===========================================================================

(import (scheme base) (scheme write) (scheme process-context)
        (creme xml) (creme xml-schema) (creme xml-schema dtd) (creme xml-schema xsd)
        (creme extra) (creme spec))

(define (kinds schema doc)
  (map validation-error-kind (validate schema (xml-read doc))))

(describe "(creme xml-schema) S-expr DSL"
  (define s
    (dsl->schema
      '(schema
         (element note
           (complex (sequence (element to   (type string))
                              (element from (type string))
                              (element n    (type integer) (occurs 0 unbounded)))
                    (attribute id (type string) (use required))
                    (attribute kind (enum "a" "b")))))))
  (it "accepts a conforming document"
    (should-be-true? (valid? s (xml-read "<note id='1'><to>a</to><from>b</from><n>1</n></note>"))))
  (it "rejects wrong order"
    (should-equal? (kinds s "<note id='1'><from>b</from><to>a</to></note>") '(content-model)))
  (it "rejects missing required attribute"
    (should-equal? (kinds s "<note><to>a</to><from>b</from></note>") '(missing-attribute)))
  (it "rejects a bad datatype"
    (should-equal? (kinds s "<note id='1'><to>a</to><from>b</from><n>x</n></note>") '(datatype))))

(describe "(creme xml-schema) content models"
  (define m (dsl->schema '(schema (element p (complex (choice (element b (type string))
                                                              (element i (type string))
                                                              (occurs 0 unbounded)) mixed)))))
  (it "validates mixed content"
    (should-be-true? (valid? m (xml-read "<p>hi <b>x</b> and <i>y</i></p>"))))
  (define a (dsl->schema '(schema (element r (complex (all (element h (type string))
                                                          (element b (type string))))))))
  (it "matches xs:all in any order"
    (should-be-true? (valid? a (xml-read "<r><b>x</b><h>y</h></r>"))))
  (it "rejects a duplicate in xs:all"
    (should-be-false? (valid? a (xml-read "<r><h>1</h><h>2</h></r>")))))

(describe "(creme xml-schema dtd) DTD reader"
  (define s (dtd-read (string-append
              "<!ELEMENT note (to, from)>"
              "<!ELEMENT to (#PCDATA)> <!ELEMENT from (#PCDATA)>"
              "<!ATTLIST note id ID #REQUIRED kind (a|b) #IMPLIED>")))
  (it "validates against ELEMENT/ATTLIST"
    (should-be-true? (valid? s (xml-read "<note id='n1'><to>a</to><from>b</from></note>"))))
  (it "flags an enumerated-attribute violation"
    (should-equal? (kinds s "<note id='n1' kind='z'><to>a</to><from>b</from></note>") '(bad-attribute)))
  (it "detects a duplicate ID"
    (should-equal? (kinds (dtd-read (string-append
                            "<!ELEMENT r (i*)> <!ELEMENT i (#PCDATA)> <!ATTLIST i k ID #REQUIRED>"))
                          "<r><i k='a'/><i k='a'/></r>")
                   '(id-conflict))))

(describe "(creme xml-schema xsd) XSD reader"
  (define s (xsd-read (string-append
              "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>"
              "<xs:element name='book'><xs:complexType><xs:sequence>"
              "<xs:element name='title' type='xs:string'/>"
              "<xs:element name='year'><xs:simpleType><xs:restriction base='xs:integer'>"
              "<xs:minInclusive value='1450'/></xs:restriction></xs:simpleType></xs:element>"
              "</xs:sequence><xs:attribute name='isbn' type='xs:string' use='required'/>"
              "</xs:complexType></xs:element></xs:schema>")))
  (it "accepts a conforming book"
    (should-be-true? (valid? s (xml-read "<book isbn='x'><title>T</title><year>2000</year></book>"))))
  (it "enforces a facet"
    (should-equal? (kinds s "<book isbn='x'><title>T</title><year>1000</year></book>") '(datatype)))
  (it "validates a namespaced document"
    (should-be-true?
     (valid? (xsd-read (string-append
               "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' targetNamespace='urn:b'>"
               "<xs:element name='t' type='xs:string'/></xs:schema>"))
             (xml-read "<t xmlns='urn:b'>hi</t>")))))

(spec-summary!)
