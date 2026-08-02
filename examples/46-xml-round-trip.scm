(import (scheme base) (scheme write) (creme xml))

(define doc "<person id=\"42\"><name>Ada</name><role>Engineer</role></person>")

;; Parse into (creme html)-shaped node data: (tag (@ (attr val) ...) child ...)
(define node (xml-read doc))
(display "parsed node: ") (display node) (newline)
(newline)

;; It's plain Scheme data -- read fields out of it directly.
(define (child-text node tag)
  (let loop ((children (cddr node)))
    (cond
     ((null? children) #f)
     ((and (pair? (car children)) (eq? (caar children) tag)) (cadr (car children)))
     (else (loop (cdr children))))))

(display "name: ") (display (child-text node 'name)) (newline)
(display "role: ") (display (child-text node 'role)) (newline)
(newline)

;; Edit the tree as ordinary lists, then write it back out.
(define updated (list 'person (cadr node) (list 'name "Ada") (list 'role "Principal Engineer")))
(display "updated xml: ") (display (xml->string updated)) (newline)
