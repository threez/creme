require "../../spec_helper"

# Runs a Scheme snippet with the schema + xml libraries loaded, on a fresh
# interpreter, and returns the final value's write_string -- same harness shape
# as xml_spec.cr's `w`.
private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(
    interp,
    "(import (scheme base) (scheme write) (creme xml) (creme xml-schema) (creme extra)) #{src}"
  ).write_string
end

# A reusable note schema (sequence + occurrence + attributes).
private NOTE_SCHEMA = <<-SCM
  (define note-schema
    (dsl->schema
      '(schema
         (element note
           (complex (sequence (element to   (type string))
                              (element from (type string))
                              (element body (type string) (occurs 0 1))
                              (element n    (type integer) (occurs 0 unbounded)))
                    (attribute id (type string) (use required))
                    (attribute kind (enum "a" "b")))))))
  SCM

private def with_note(expr : String) : String
  w("#{NOTE_SCHEMA} #{expr}")
end

# Like `w`, but also loads the DTD reader library.
private def wd(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(
    interp,
    "(import (scheme base) (scheme write) (creme xml) (creme xml-schema) (creme xml-schema dtd) (creme extra)) #{src}"
  ).write_string
end

# Like `w`, but also loads the XSD reader library.
private def wx(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(
    interp,
    "(import (scheme base) (scheme write) (creme xml) (creme xml-schema) (creme xml-schema xsd) (creme extra)) #{src}"
  ).write_string
end

private XSD_BOOK = <<-SCM
  (define book-xsd (xsd-read (string-append
    "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>"
    "  <xs:element name='book'><xs:complexType><xs:sequence>"
    "    <xs:element name='title' type='xs:string'/>"
    "    <xs:element name='author' type='xs:string' maxOccurs='unbounded'/>"
    "    <xs:element name='year'><xs:simpleType><xs:restriction base='xs:integer'>"
    "      <xs:minInclusive value='1450'/><xs:maxInclusive value='2100'/>"
    "    </xs:restriction></xs:simpleType></xs:element>"
    "    <xs:element name='price' minOccurs='0'><xs:complexType><xs:simpleContent>"
    "      <xs:extension base='xs:decimal'><xs:attribute name='currency' type='xs:string' use='required'/>"
    "    </xs:extension></xs:simpleContent></xs:complexType></xs:element>"
    "  </xs:sequence><xs:attribute name='isbn' type='xs:string' use='required'/>"
    "  </xs:complexType></xs:element></xs:schema>")))
  SCM

describe "xml-schema module" do
  describe "S-expr DSL + validation" do
    it "accepts a document matching a sequence schema" do
      with_note(%[(valid? note-schema (xml-read "<note id='1'><to>a</to><from>b</from></note>"))])
        .should eq("#t")
    end

    it "accepts optional and unbounded occurrences" do
      with_note(%[(valid? note-schema (xml-read "<note id='1'><to>a</to><from>b</from><body>hi</body><n>1</n><n>2</n></note>"))])
        .should eq("#t")
    end

    it "rejects children in the wrong order (content-model error)" do
      with_note(%[(map validation-error-kind (validate note-schema (xml-read "<note id='1'><from>b</from><to>a</to></note>")))])
        .should eq("(content-model)")
    end

    it "reports a missing required attribute" do
      with_note(%[(map validation-error-kind (validate note-schema (xml-read "<note><to>a</to><from>b</from></note>")))])
        .should eq("(missing-attribute)")
    end

    it "rejects an attribute value outside its enumeration" do
      with_note(%[(map validation-error-kind (validate note-schema (xml-read "<note id='1' kind='z'><to>a</to><from>b</from></note>")))])
        .should eq("(bad-attribute)")
    end

    it "rejects a bad datatype in element text" do
      with_note(%[(map validation-error-kind (validate note-schema (xml-read "<note id='1'><to>a</to><from>b</from><n>xx</n></note>")))])
        .should eq("(datatype)")
    end

    it "rejects child elements inside simple content" do
      with_note(%[(map validation-error-kind (validate note-schema (xml-read "<note id='1'><to><x/></to><from>b</from></note>")))])
        .should eq("(unexpected-element)")
    end

    it "flags an undeclared root element" do
      with_note(%[(map validation-error-kind (validate note-schema (xml-read "<other/>")))])
        .should eq("(undeclared)")
    end
  end

  describe "choice, global refs, recursion, named simple types, facets" do
    catalog = <<-SCM
      (define cat
        (dsl->schema
          '(schema
             (simple-type year (restrict integer (min-inclusive 1450) (max-inclusive 2100)))
             (element catalog (complex (sequence (ref book (occurs 1 unbounded)))))
             (element book
               (complex (sequence (choice (element title (type string))
                                          (element untitled (type string)))
                                  (element year (type year))
                                  (ref section (occurs 0 unbounded)))))
             (element section
               (complex (sequence (element head (type string))
                                  (ref section (occurs 0 unbounded))))))))
      SCM

    it "accepts either branch of a choice" do
      w(%[#{catalog} (list (valid? cat (xml-read "<catalog><book><title>T</title><year>2000</year></book></catalog>"))
                            (valid? cat (xml-read "<catalog><book><untitled>U</untitled><year>1999</year></book></catalog>")))])
        .should eq("(#t #t)")
    end

    it "validates arbitrarily deep recursion via a self-referential ref" do
      w(%[#{catalog} (valid? cat (xml-read "<catalog><book><title>T</title><year>2000</year><section><head>h1</head><section><head>h2</head></section></section></book></catalog>"))])
        .should eq("#t")
    end

    it "applies facets from a named simple type" do
      w(%[#{catalog} (map validation-error-kind (validate cat (xml-read "<catalog><book><title>T</title><year>1000</year></book></catalog>")))])
        .should eq("(datatype)")
    end

    it "requires at least one occurrence (empty parent fails)" do
      w(%[#{catalog} (valid? cat (xml-read "<catalog></catalog>"))]).should eq("#f")
    end
  end

  describe "content models (NFA matcher)" do
    it "validates mixed content (text interspersed with a repeated choice)" do
      w(%[(define m (dsl->schema '(schema (element p (complex (choice (element b (type string)) (element i (type string)) (occurs 0 unbounded)) mixed)))))
          (list (valid? m (xml-read "<p>hello <b>x</b> world <i>y</i></p>"))
                (valid? m (xml-read "<p>only text</p>")))])
        .should eq("(#t #t)")
    end

    it "enforces empty content" do
      w(%[(define e (dsl->schema '(schema (element br (complex empty)))))
          (list (valid? e (xml-read "<br/>")) (valid? e (xml-read "<br>x</br>")))])
        .should eq("(#t #f)")
    end

    it "accepts any element under a wildcard" do
      w(%[(define wc (dsl->schema '(schema (element wrap (complex (sequence (any (occurs 0 unbounded))))))))
          (valid? wc (xml-read "<wrap><anything/><whatever>x</whatever></wrap>"))])
        .should eq("#t")
    end

    it "matches xs:all in any order, once each, rejecting dups/missing" do
      w(%[(define a (dsl->schema '(schema (element rec (complex (all (element head (type string)) (element body (type string))))))))
          (list (valid? a (xml-read "<rec><head>h</head><body>b</body></rec>"))
                (valid? a (xml-read "<rec><body>b</body><head>h</head></rec>"))
                (valid? a (xml-read "<rec><head>h</head><head>h2</head></rec>"))
                (valid? a (xml-read "<rec><head>h</head></rec>")))])
        .should eq("(#t #t #f #f)")
    end

    it "handles a nested-unbounded model over many children without blowup" do
      w(%[(define s (dsl->schema '(schema (element r (complex (sequence (sequence (element a (type string) (occurs 0 1)) (occurs 0 unbounded)) (occurs 0 unbounded)))))))
          (define doc (string-append "<r>" (apply string-append (map (lambda (i) "<a>x</a>") (iota 300))) "</r>"))
          (valid? s (xml-read doc))])
        .should eq("#t")
    end
  end

  describe "DTD reader" do
    dtd = <<-SCM
      (define dtd-schema
        (dtd-read (string-append
          "<!ELEMENT note (to, from, body?, n*)>"
          "<!ELEMENT to (#PCDATA)>   <!ELEMENT from (#PCDATA)>"
          "<!ELEMENT body (#PCDATA)> <!ELEMENT n (#PCDATA)>"
          "<!ATTLIST note id ID #REQUIRED kind (a|b|c) #IMPLIED ver CDATA #FIXED \\"1.0\\">")))
      SCM

    it "validates a document against ELEMENT/ATTLIST declarations" do
      wd(%[#{dtd} (list
             (valid? dtd-schema (xml-read "<note id='n1'><to>a</to><from>b</from><body>hi</body><n>x</n></note>"))
             (valid? dtd-schema (xml-read "<note id='n1'><to>a</to><from>b</from></note>")))])
        .should eq("(#t #t)")
    end

    it "reports content-model, required-ID, enumerated and #FIXED violations" do
      wd(%[#{dtd} (list
             (map validation-error-kind (validate dtd-schema (xml-read "<note id='n1'><from>b</from><to>a</to></note>")))
             (map validation-error-kind (validate dtd-schema (xml-read "<note><to>a</to><from>b</from></note>")))
             (map validation-error-kind (validate dtd-schema (xml-read "<note id='n1' kind='z'><to>a</to><from>b</from></note>")))
             (map validation-error-kind (validate dtd-schema (xml-read "<note id='n1' ver='2.0'><to>a</to><from>b</from></note>"))))])
        .should eq("((content-model) (missing-attribute) (bad-attribute) (bad-attribute))")
    end

    it "expands parameter entities inside a mixed content model" do
      wd(%[(define s (dtd-read (string-append
              "<!ENTITY % inline \\"b|i\\">"
              "<!ELEMENT p (#PCDATA|%inline;)*>"
              "<!ELEMENT b (#PCDATA)> <!ELEMENT i (#PCDATA)>")))
           (valid? s (xml-read "<p>hi <b>x</b> yo <i>y</i></p>"))])
        .should eq("#t")
    end
  end

  describe "datatypes and facets (validate-simple)" do
    it "validates builtin lexical spaces" do
      w(%[(map (lambda (p) (null? (validate-simple (car p) (cadr p))))
               (list (list 'integer "42") (list 'integer "4.5")
                     (list 'decimal "3.14") (list 'boolean "true") (list 'boolean "yes")
                     (list 'date "2026-08-08") (list 'date "2026-8-8")
                     (list 'nonNegativeInteger "0") (list 'nonNegativeInteger "-1")
                     (list 'NCName "foo-bar") (list 'NCName "a:b")))])
        .should eq("(#t #f #t #t #f #t #f #t #f #t #f)")
    end

    it "applies pattern, length, range and enumeration facets" do
      w(%[(define (mk base facets) (make-simple-type #f 'atomic base facets #f '()))
          (list
            (null? (validate-simple (mk 'string (list (make-facet 'pattern "[A-Z]{3}" #f))) "ABC"))
            (null? (validate-simple (mk 'string (list (make-facet 'pattern "[A-Z]{3}" #f))) "abcd"))
            (null? (validate-simple (mk 'integer (list (make-facet 'min-inclusive 1 #f) (make-facet 'max-inclusive 10 #f))) "5"))
            (null? (validate-simple (mk 'integer (list (make-facet 'max-inclusive 10 #f))) "11"))
            (null? (validate-simple (mk 'string (list (make-facet 'enumeration (list "red" "green") #f))) "blue")))])
        .should eq("(#t #f #t #f #f)")
    end

    it "handles whiteSpace collapse, list and union varieties" do
      w(%[(list
            (null? (validate-simple (make-simple-type #f 'atomic 'string
                     (list (make-facet 'white-space 'collapse #f) (make-facet 'enumeration (list "a b") #f)) #f '())
                     "   a    b   "))
            (null? (validate-simple (make-simple-type #f 'list 'string '() 'integer '()) "1 2 3"))
            (null? (validate-simple (make-simple-type #f 'list 'string '() 'integer '()) "1 x 3"))
            (null? (validate-simple (make-simple-type #f 'union 'string '() #f (list 'integer 'boolean)) "true")))])
        .should eq("(#t #t #f #t)")
    end
  end

  describe "XSD reader" do
    it "validates against anonymous types, facets and simpleContent extension" do
      wx(%[#{XSD_BOOK} (list
             (valid? book-xsd (xml-read "<book isbn='x'><title>T</title><author>A1</author><author>A2</author><year>2000</year><price currency='USD'>9.99</price></book>"))
             (valid? book-xsd (xml-read "<book isbn='x'><title>T</title><author>A</author><year>2000</year></book>")))])
        .should eq("(#t #t)")
    end

    it "reports missing attr, out-of-range facet, bad order and bad decimal" do
      wx(%[#{XSD_BOOK} (list
             (map validation-error-kind (validate book-xsd (xml-read "<book><title>T</title><author>A</author><year>2000</year></book>")))
             (map validation-error-kind (validate book-xsd (xml-read "<book isbn='x'><title>T</title><author>A</author><year>1000</year></book>")))
             (map validation-error-kind (validate book-xsd (xml-read "<book isbn='x'><author>A</author><title>T</title><year>2000</year></book>")))
             (map validation-error-kind (validate book-xsd (xml-read "<book isbn='x'><title>T</title><author>A</author><year>2000</year><price currency='USD'>abc</price></book>"))))])
        .should eq("((missing-attribute) (datatype) (content-model) (datatype))")
    end

    it "resolves complexContent extension, xs:group and xs:attributeGroup refs" do
      grp = <<-SCM
        (define s (xsd-read (string-append
          "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>"
          "<xs:attributeGroup name='idattrs'><xs:attribute name='id' type='xs:string' use='required'/></xs:attributeGroup>"
          "<xs:group name='ng'><xs:sequence><xs:element name='first' type='xs:string'/><xs:element name='last' type='xs:string'/></xs:sequence></xs:group>"
          "<xs:complexType name='Base'><xs:sequence><xs:element name='id' type='xs:string'/></xs:sequence></xs:complexType>"
          "<xs:element name='person'><xs:complexType><xs:complexContent><xs:extension base='Base'>"
          "  <xs:sequence><xs:group ref='ng'/><xs:choice>"
          "    <xs:element name='email' type='xs:string'/><xs:element name='phone' type='xs:string'/></xs:choice></xs:sequence>"
          "  <xs:attributeGroup ref='idattrs'/></xs:extension></xs:complexContent></xs:complexType></xs:element></xs:schema>")))
        SCM
      wx(%[#{grp} (list
             (valid? s (xml-read "<person id='p'><id>x</id><first>A</first><last>B</last><email>e</email></person>"))
             (valid? s (xml-read "<person><id>x</id><first>A</first><last>B</last><email>e</email></person>"))
             (valid? s (xml-read "<person id='p'><id>x</id><first>A</first><email>e</email></person>")))])
        .should eq("(#t #f #f)")
    end

    it "validates namespaced documents (prefixed and default) via targetNamespace" do
      wx(%[(define s (xsd-read (string-append
              "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' targetNamespace='urn:b'>"
              "<xs:element name='book'><xs:complexType><xs:sequence>"
              "<xs:element name='title' type='xs:string'/></xs:sequence></xs:complexType></xs:element></xs:schema>")))
           (list (valid? s (xml-read "<b:book xmlns:b='urn:b'><b:title>T</b:title></b:book>"))
                 (valid? s (xml-read "<book xmlns='urn:b'><title>T</title></book>"))
                 (valid? s (xml-read "<book xmlns='urn:b'><nope>T</nope></book>")))])
        .should eq("(#t #t #f)")
    end

    it "matches substitution-group members" do
      wx(%[(define s (xsd-read (string-append
              "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>"
              "<xs:element name='contact' type='xs:string'/>"
              "<xs:element name='email' type='xs:string' substitutionGroup='contact'/>"
              "<xs:element name='card'><xs:complexType><xs:sequence>"
              "<xs:element ref='contact'/></xs:sequence></xs:complexType></xs:element></xs:schema>")))
           (list (valid? s (xml-read "<card><contact>c</contact></card>"))
                 (valid? s (xml-read "<card><email>e</email></card>"))
                 (valid? s (xml-read "<card><phone>p</phone></card>")))])
        .should eq("(#t #t #f)")
    end
  end

  describe "ID/IDREF cross-checks and include" do
    it "enforces ID uniqueness and IDREF resolution (via a DTD)" do
      wd(%[(define s (dtd-read (string-append
              "<!ELEMENT root (item*)>"
              "<!ELEMENT item (#PCDATA)>"
              "<!ATTLIST item key ID #REQUIRED refs IDREFS #IMPLIED>")))
           (list
             (map validation-error-kind (validate s (xml-read "<root><item key='a'/><item key='b' refs='a'/></root>")))
             (map validation-error-kind (validate s (xml-read "<root><item key='a'/><item key='a'/></root>")))
             (map validation-error-kind (validate s (xml-read "<root><item key='a' refs='a zzz'/></root>"))))])
        .should eq("(() (id-conflict) (idref-dangling))")
    end

    it "merges an included schema through an in-memory resolver" do
      wx(%[(define types-xsd (string-append
              "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>"
              "<xs:element name='title' type='xs:string'/>"
              "<xs:complexType name='Money'><xs:simpleContent><xs:extension base='xs:decimal'>"
              "<xs:attribute name='cur' type='xs:string' use='required'/></xs:extension></xs:simpleContent></xs:complexType>"
              "</xs:schema>"))
           (define (resolver loc) types-xsd)
           (define s (xsd-read (string-append
              "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>"
              "<xs:include schemaLocation='types.xsd'/>"
              "<xs:element name='book'><xs:complexType><xs:sequence>"
              "<xs:element ref='title'/><xs:element name='price' type='Money'/>"
              "</xs:sequence></xs:complexType></xs:element></xs:schema>") resolver))
           (list (valid? s (xml-read "<book><title>T</title><price cur='USD'>9.99</price></book>"))
                 (valid? s (xml-read "<book><title>T</title><price cur='USD'>abc</price></book>"))
                 (valid? s (xml-read "<book><title>T</title><price>9.99</price></book>")))])
        .should eq("(#t #f #f)")
    end
  end

  describe "validate/raise" do
    it "returns #t for a valid document" do
      with_note(%[(validate/raise note-schema (xml-read "<note id='1'><to>a</to><from>b</from></note>"))])
        .should eq("#t")
    end

    it "raises on the first error" do
      interp = Creme::Interpreter.new(library_search_path: ["./modules"])
      expect_raises(Creme::SchemeError) do
        Creme.run_source(interp,
          "(import (scheme base) (creme xml) (creme xml-schema)) #{NOTE_SCHEMA} " \
          "(validate/raise note-schema (xml-read \"<note><to>a</to><from>b</from></note>\"))")
      end
    end
  end
end
