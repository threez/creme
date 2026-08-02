(import (scheme base) (scheme write) (creme uri) (creme cgi))

;; Parse a URL into its components.
(define u (uri-parse "https://example.com:8443/search?q=scheme+lists&page=2#top"))
(display "scheme: ") (display (uri-scheme u)) (newline)
(display "host: ") (display (uri-host u)) (newline)
(display "port: ") (display (uri-port u)) (newline)
(display "path: ") (display (uri-path u)) (newline)
(display "query: ") (display (uri-query u)) (newline)
(display "fragment: ") (display (uri-fragment u)) (newline)
(newline)

;; Decode the query string into one (key . value) pair per occurrence.
(display "decoded query: ") (display (uri-decode-www-form (uri-query u))) (newline)
(newline)

;; Resolve a relative reference against a base URL (RFC 3986 5.3).
(define base (uri-parse "http://example.com/docs/guide/intro.html"))
(display "../api.html resolves to: ")
(display (uri->string (uri-join base "../api.html")))
(newline)
(newline)

;; Build a fresh query string from an alist, cgi-escaping as needed.
(define built (uri-encode-www-form (list (cons "name" "Jo Bloggs") (cons "team" "R&D"))))
(display "built query string: ") (display built) (newline)
(display "round-tripped: ") (display (cgi-parse built)) (newline)
