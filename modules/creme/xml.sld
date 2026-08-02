;; ===========================================================================
;; (creme xml): a minimal well-formed-XML reader/writer, matching a useful
;; subset of Ruby's REXML
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme matrix)/(creme pstore) use) since every export here is
;; expressible in plain R7RS over (creme scanner)'s port-scanning
;; primitives, with no opaque foreign object or third-party Crystal
;; library of its own involved. Hand-written recursive-descent, not a
;; grammar-table parser (that's (creme lr)'s job, for a grammar that
;; genuinely needs infix expression precedence, e.g. (creme syntax
;; ruby)) -- XML is tag-soup-shaped, not expression-shaped, the same
;; reasoning (creme syntax scss)/(creme syntax slim) already document for
;; reaching for (creme scanner) over a real grammar.
;;
;; A parsed document is a node in EXACTLY (creme html)'s own node shape
;; -- `(tag (@ (name value) ...) child ...)`, `tag` a symbol, each attr a
;; 2-element `(name value)` list, `name` a symbol, `value`/text children
;; always strings -- so a parsed XML document is directly usable
;; anywhere a (creme html) node is expected, and vice versa (e.g. reading
;; an XML fragment, editing its child list as plain Scheme data, and
;; feeding it straight to html->string). Text/attribute-value entity
;; decoding when reading, and escaping when writing, both delegate to
;; existing libraries rather than duplicating their tables: reading
;; reuses (creme cgi)'s cgi-unescape-html (the 5 standard named entities
;; plus numeric character references), writing reuses (creme html)'s
;; html-escape.
;;
;;   (xml-read s)            -> s (a whole XML document string) parsed
;;                              into one root node
;;   (xml-read-port port)    -> the same, reading from an already-open
;;                              input port instead of a whole string in
;;                              memory
;;   (xml-write port node)   -> writes node's serialization directly
;;                              into port
;;   (xml->string node)      -> node rendered against a fresh string
;;                              port, returns the accumulated string --
;;                              an element with no children self-closes
;;                              (`<tag/>`) rather than needing an
;;                              explicit void-element list the way
;;                              (creme html) does for HTML5's fixed set
;;                              (XML has no such fixed set: any
;;                              childless element may self-close)
;;
;; Limitations (explicit, matching this project's usual scope honesty --
;; see e.g. (creme ffi)'s SECURITY note, (creme treelist)'s "chaperones
;; ... not implemented" line):
;;   - No DTD/entity-declaration processing -- a <!DOCTYPE ...> is
;;     skipped over verbatim (up to its next top-level '>'), never
;;     interpreted, and a custom entity it might declare is NOT
;;     recognized when decoding text.
;;   - No namespace resolution -- a qualified name like "ns:tag" is kept
;;     as one opaque symbol/string, not split into a prefix and a
;;     resolved namespace URI.
;;   - Comments and processing instructions are skipped over while
;;     parsing, not round-tripped into the resulting node tree at all.
;;   - CDATA sections aren't specially recognized (their contents would
;;     be read as ordinary text, entity-decoding included, which is
;;     wrong for CDATA's own escaping-free contract) -- avoid CDATA in
;;     documents parsed here.
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme xml)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme xml)
  (export xml-read xml-read-port xml-write xml->string)
  (import (scheme base) (scheme char) (scheme write) (creme scanner) (creme html) (creme cgi))
  (begin
    (define (xml-name-char? c)
      (or (char-alphabetic? c) (char-numeric? c) (char=? c #\-) (char=? c #\_) (char=? c #\.) (char=? c #\:)))

    (define (xml-priv-expect! port c who)
      (let ((got (read-char port)))
        (if (or (eof-object? got) (not (char=? got c)))
            (error (string-append "xml-read: expected '" (string c) "' " who)))))

    (define (xml-priv-skip-to-gt! port)
      (skip-while port (lambda (c) (not (char=? c #\>))))
      (read-char port))

    (define (xml-priv-skip-pi! port)
      (let loop ()
        (let ((r (scan-until-char port (lambda (c) (char=? c #\?)))))
          (if (not (cdr r))
              (error "xml-read: unterminated processing instruction")
              (let ((c2 (peek-char port)))
                (if (and (char? c2) (char=? c2 #\>))
                    (read-char port)
                    (loop)))))))

    (define (xml-priv-skip-comment! port)
      (let loop ()
        (let ((r (scan-until-char port (lambda (c) (char=? c #\-)))))
          (if (not (cdr r))
              (error "xml-read: unterminated comment")
              (let ((c2 (peek-char port)))
                (if (and (char? c2) (char=? c2 #\-))
                    (begin
                      (read-char port)
                      (let ((c3 (peek-char port)))
                        (if (and (char? c3) (char=? c3 #\>))
                            (read-char port)
                            (loop))))
                    (loop)))))))

    ;; Skips whitespace/comments/processing-instructions/DOCTYPE, then
    ;; consumes the "<" that begins a real element, leaving the cursor
    ;; right at that element's tag name.
    (define (xml-priv-consume-element-open! port)
      (let loop ()
        (skip-while port char-whitespace?)
        (let ((c (read-char port)))
          (cond
           ((eof-object? c) (error "xml-read: expected an element, got end of input"))
           ((not (char=? c #\<)) (error "xml-read: expected '<'"))
           (else
            (let ((c2 (peek-char port)))
              (cond
               ((and (char? c2) (char=? c2 #\!))
                (read-char port)
                (let ((c3 (peek-char port)))
                  (if (and (char? c3) (char=? c3 #\-))
                      (begin (read-char port) (xml-priv-expect! port #\- "comment") (xml-priv-skip-comment! port))
                      (xml-priv-skip-to-gt! port)))
                (loop))
               ((and (char? c2) (char=? c2 #\?))
                (read-char port)
                (xml-priv-skip-pi! port)
                (loop))
               (else #t))))))))

    (define (xml-priv-parse-attrs! port)
      (let loop ((attrs '()))
        (skip-while port char-whitespace?)
        (let ((c (peek-char port)))
          (cond
           ((eof-object? c) (error "xml-read: unterminated tag"))
           ((char=? c #\/) (read-char port) (xml-priv-expect! port #\> "after self-close /") (cons (reverse attrs) #t))
           ((char=? c #\>) (read-char port) (cons (reverse attrs) #f))
           (else
            (let ((aname (scan-while port xml-name-char?)))
              (skip-while port char-whitespace?)
              (xml-priv-expect! port #\= "after attribute name")
              (skip-while port char-whitespace?)
              (let ((q (read-char port)))
                (if (or (eof-object? q) (not (or (char=? q #\") (char=? q #\'))))
                    (error "xml-read: expected a quote to start attribute value" aname))
                (let ((r (scan-until-char port (lambda (c2) (char=? c2 q)))))
                  (loop (cons (list (string->symbol aname) (cgi-unescape-html (car r))) attrs))))))))))

    (define (xml-priv-parse-children! port open-name)
      (let loop ((acc '()))
        (let* ((r (scan-until-char port (lambda (c) (char=? c #\<))))
               (text (car r))
               (term (cdr r)))
          (if (not term) (error "xml-read: unterminated element" open-name))
          (let ((acc2 (if (> (string-length text) 0) (cons (cgi-unescape-html text) acc) acc)))
            (let ((c2 (peek-char port)))
              (cond
               ((and (char? c2) (char=? c2 #\/))
                (read-char port)
                (let ((close-name (scan-while port xml-name-char?)))
                  (skip-while port char-whitespace?)
                  (xml-priv-expect! port #\> "to close a tag")
                  (if (not (string=? close-name open-name))
                      (error "xml-read: mismatched closing tag" open-name close-name))
                  (reverse acc2)))
               ((and (char? c2) (char=? c2 #\!))
                (read-char port)
                (let ((c3 (peek-char port)))
                  (if (and (char? c3) (char=? c3 #\-))
                      (begin (read-char port) (xml-priv-expect! port #\- "comment") (xml-priv-skip-comment! port))
                      (xml-priv-skip-to-gt! port)))
                (loop acc2))
               ((and (char? c2) (char=? c2 #\?))
                (read-char port)
                (xml-priv-skip-pi! port)
                (loop acc2))
               (else (loop (cons (xml-priv-parse-element port) acc2)))))))))

    (define (xml-priv-parse-element port)
      (let* ((name (scan-while port xml-name-char?))
             (parsed (xml-priv-parse-attrs! port))
             (attr-list (car parsed))
             (self-closing? (cdr parsed))
             (attrs-part (if (null? attr-list) '() (list (cons '@ attr-list)))))
        (if self-closing?
            (append (list (string->symbol name)) attrs-part)
            (append (list (string->symbol name)) attrs-part (xml-priv-parse-children! port name)))))

    (define (xml-read-port port)
      (xml-priv-consume-element-open! port)
      (xml-priv-parse-element port))

    (define (xml-read s) (xml-read-port (open-input-string s)))

    (define (xml-priv-attrs-block? node) (and (pair? node) (eq? (car node) '@)))

    (define (xml-write port node)
      (cond
       ((eq? node #f) #t)
       ((null? node) #t)
       ((string? node) (write-string (html-escape node) port))
       ((number? node) (write-string (html-escape (number->string node)) port))
       ((and (pair? node) (symbol? (car node)))
        (let* ((rest (cdr node))
               (has-attrs? (and (pair? rest) (xml-priv-attrs-block? (car rest))))
               (attrs (if has-attrs? (cdr (car rest)) '()))
               (children (if has-attrs? (cdr rest) rest)))
          (write-string "<" port)
          (write-string (symbol->string (car node)) port)
          (for-each
           (lambda (a)
             (write-string " " port)
             (write-string (symbol->string (car a)) port)
             (write-string "=\"" port)
             (write-string (html-escape (cadr a)) port)
             (write-string "\"" port))
           attrs)
          (if (null? children)
              (write-string "/>" port)
              (begin
                (write-string ">" port)
                (for-each (lambda (c) (xml-write port c)) children)
                (write-string "</" port)
                (write-string (symbol->string (car node)) port)
                (write-string ">" port)))))
       ((pair? node) (for-each (lambda (c) (xml-write port c)) node))
       (else (error "xml-write: invalid node" node))))

    (define (xml->string node)
      (let ((port (open-output-string)))
        (xml-write port node)
        (get-output-string port)))))
