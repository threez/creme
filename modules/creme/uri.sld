;; ===========================================================================
;; (creme uri): URI parsing, building, and reference resolution, matching
;; Ruby's URI module's core (not its per-scheme URI::HTTP/URI::FTP/etc.
;; subclasses -- one generic record covers every scheme here, an explicit
;; scope boundary, not an oversight)
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme cgi)/(creme pathname) use) since every export here is expressible
;; in plain R7RS over (creme regex)'s regexp-search, with no opaque
;; foreign object or third-party Crystal library of its own involved.
;;
;; A <uri> record: scheme, userinfo, host, port, path, query, fragment.
;; scheme/userinfo/port/query/fragment are #f when absent; host is #f
;; only when there's no authority component at all ("//...") -- an
;; authority present but empty (e.g. "file:///path") gives host "" (an
;; empty string, still present), matching the RFC 3986 grammar's own
;; distinction. port, when present, is an exact integer (parsed via
;; string->number), not a string.
;;
;;   (uri-parse s)       -> s parsed into a <uri>, via the RFC 3986
;;                          Appendix B reference regex (a purely
;;                          syntactic split -- percent-decoding a path/
;;                          query segment is the caller's own job via
;;                          (creme cgi)'s cgi-unescape, same as Ruby's
;;                          URI doesn't auto-decode either)
;;   (uri->string u)     -> u recomposed back into a URI string
;;   (uri? x)
;;   (uri-scheme u) / (uri-userinfo u) / (uri-host u) / (uri-port u) /
;;   (uri-path u) / (uri-query u) / (uri-fragment u)
;;   (uri-encode-www-form alist)  -> alist's (key . value) pairs joined
;;                          as "key=value", each cgi-escape'd, joined by
;;                          "&" -- a repeated key is simply included as
;;                          more than one pair, same as Ruby's
;;                          URI.encode_www_form taking an array of pairs
;;   (uri-decode-www-form qs)     -> qs parsed into a list of (key .
;;                          value) pairs, ONE PER OCCURRENCE, in
;;                          original order -- unlike (creme cgi)'s
;;                          cgi-parse, repeated keys are NOT grouped into
;;                          one entry's value list, matching Ruby's
;;                          URI.decode_www_form exactly (which returns
;;                          an array of pairs, not CGI.parse's hash of
;;                          arrays) -- e.g. (uri-decode-www-form "a=1&a=2")
;;                          -> (("a" . "1") ("a" . "2"))
;;   (uri-join base ref) -> ref (a string -- an absolute or relative URI
;;                          reference) resolved against base (a <uri>),
;;                          per RFC 3986 5.3's reference-resolution
;;                          algorithm (5.2.4's remove_dot_segments
;;                          included) -- e.g. given base
;;                          "http://a/b/c/d;p?q", (uri-join base "g")
;;                          is "http://a/b/c/g", (uri-join base "../g")
;;                          is "http://a/b/g", (uri-join base "/g") is
;;                          "http://a/g"
;;
;; Native `bin/creme` only -- `icecreme/icecreme`'s regexp-search drops a trailing
;; unmatched optional group entirely instead of reporting it as #f (e.g.
;; a pattern ending in "(b)?" against input lacking that group returns
;; one shorter a list on icecreme than on native creme), which desyncs
;; uri-parse's fixed group-index reads; not addressed here since fixing
;; it is an icecreme regex-engine change, out of this library's own scope.
;;
;; Limitations: no IPv6 literal host handling (a "[::1]"-shaped host
;; isn't specially recognized -- the generic authority split still
;; extracts SOMETHING, just not necessarily the right thing for a
;; bracketed IPv6 address with an embedded ":"); percent-encoding/
;; decoding path or userinfo components is left entirely to the caller
;; (via (creme cgi)) rather than happening automatically anywhere here.
;; ===========================================================================

(define-library (creme uri)
  (export uri-parse uri->string uri? uri-scheme uri-userinfo uri-host
          uri-port uri-path uri-query uri-fragment uri-encode-www-form
          uri-decode-www-form uri-join)
  (import (scheme base) (creme string) (creme regex) (creme cgi))
  (begin
    (define-record-type <uri>
      (uri-priv-make scheme userinfo host port path query fragment)
      uri?
      (scheme uri-scheme)
      (userinfo uri-userinfo)
      (host uri-host)
      (port uri-port)
      (path uri-path)
      (query uri-query)
      (fragment uri-fragment))

    (define uri-priv-generic-regex
      (regexp "^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\\?([^#]*))?(#(.*))?"))

    (define uri-priv-authority-regex
      (regexp "^(?:([^@]*)@)?([^:]*)(?::([0-9]*))?$"))

    (define (uri-priv-nth lst n)
      (if (= n 0) (car lst) (uri-priv-nth (cdr lst) (- n 1))))

    (define (uri-parse s)
      (let* ((m (regexp-search uri-priv-generic-regex s))
             (scheme (uri-priv-nth m 2))
             (authority (uri-priv-nth m 4))
             (path (uri-priv-nth m 5))
             (query (uri-priv-nth m 7))
             (fragment (uri-priv-nth m 9)))
        (if (not authority)
            (uri-priv-make scheme #f #f #f path query fragment)
            (let* ((am (regexp-search uri-priv-authority-regex authority))
                   (userinfo (uri-priv-nth am 1))
                   (host (uri-priv-nth am 2))
                   (port-str (uri-priv-nth am 3))
                   (port (if (and port-str (> (string-length port-str) 0)) (string->number port-str) #f)))
              (uri-priv-make scheme userinfo host port path query fragment)))))

    (define (uri->string u)
      (string-append
       (if (uri-scheme u) (string-append (uri-scheme u) ":") "")
       (if (uri-host u)
           (string-append
            "//"
            (if (uri-userinfo u) (string-append (uri-userinfo u) "@") "")
            (uri-host u)
            (if (uri-port u) (string-append ":" (number->string (uri-port u))) ""))
           "")
       (uri-path u)
       (if (uri-query u) (string-append "?" (uri-query u)) "")
       (if (uri-fragment u) (string-append "#" (uri-fragment u)) "")))

    (define (uri-encode-www-form alist)
      (string-join
       (map (lambda (kv) (string-append (cgi-escape (car kv)) "=" (cgi-escape (cdr kv)))) alist)
       "&"))

    (define (uri-decode-www-form qs)
      (if (string=? qs "")
          '()
          (map
           (lambda (pair)
             (let ((eq-idx (string-index-of pair "=")))
               (cons (cgi-unescape (if eq-idx (substring pair 0 eq-idx) pair))
                     (cgi-unescape (if eq-idx (substring pair (+ eq-idx 1) (string-length pair)) "")))))
           (string-split qs "&"))))

    (define (uri-priv-filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (uri-priv-filter pred (cdr lst))))
            (else (uri-priv-filter pred (cdr lst)))))

    (define (uri-priv-last-slash-index s)
      (let loop ((i (- (string-length s) 1)))
        (cond
         ((< i 0) #f)
         ((char=? (string-ref s i) #\/) i)
         (else (loop (- i 1))))))

    (define (uri-priv-remove-last-segment out)
      (let ((idx (uri-priv-last-slash-index out)))
        (if idx (substring out 0 idx) "")))

    (define (uri-priv-first-segment-end in)
      (let ((start (if (string-prefix? in "/") 1 0)))
        (let loop ((i start))
          (cond
           ((>= i (string-length in)) (string-length in))
           ((char=? (string-ref in i) #\/) i)
           (else (loop (+ i 1)))))))

    ;; RFC 3986 5.2.4 remove_dot_segments, followed almost verbatim.
    (define (uri-priv-remove-dot-segments path)
      (let loop ((in path) (out ""))
        (cond
         ((string=? in "") out)
         ((string-prefix? in "../") (loop (substring in 3 (string-length in)) out))
         ((string-prefix? in "./") (loop (substring in 2 (string-length in)) out))
         ((string=? in "/.") (loop "/" out))
         ((string-prefix? in "/./") (loop (substring in 2 (string-length in)) out))
         ((string=? in "/..") (loop "/" (uri-priv-remove-last-segment out)))
         ((string-prefix? in "/../") (loop (substring in 3 (string-length in)) (uri-priv-remove-last-segment out)))
         ((or (string=? in ".") (string=? in "..")) out)
         (else
          (let ((end (uri-priv-first-segment-end in)))
            (loop (substring in end (string-length in)) (string-append out (substring in 0 end))))))))

    ;; RFC 3986 5.3's merge, given whether base has an authority component.
    (define (uri-priv-merge base-has-authority? base-path ref-path)
      (if (and base-has-authority? (string=? base-path ""))
          (string-append "/" ref-path)
          (let ((idx (uri-priv-last-slash-index base-path)))
            (if idx (string-append (substring base-path 0 (+ idx 1)) ref-path) ref-path))))

    (define (uri-join base ref)
      (let* ((r (uri-parse ref))
             (base-has-authority? (if (uri-host base) #t #f)))
        (cond
         ((uri-scheme r)
          (uri-priv-make (uri-scheme r) (uri-userinfo r) (uri-host r) (uri-port r)
                          (uri-priv-remove-dot-segments (uri-path r)) (uri-query r) (uri-fragment r)))
         ((uri-host r)
          (uri-priv-make (uri-scheme base) (uri-userinfo r) (uri-host r) (uri-port r)
                          (uri-priv-remove-dot-segments (uri-path r)) (uri-query r) (uri-fragment r)))
         ((string=? (uri-path r) "")
          (uri-priv-make (uri-scheme base) (uri-userinfo base) (uri-host base) (uri-port base)
                          (uri-path base)
                          (if (uri-query r) (uri-query r) (uri-query base))
                          (uri-fragment r)))
         (else
          (let ((merged
                 (if (string-prefix? (uri-path r) "/")
                     (uri-priv-remove-dot-segments (uri-path r))
                     (uri-priv-remove-dot-segments
                      (uri-priv-merge base-has-authority? (uri-path base) (uri-path r))))))
            (uri-priv-make (uri-scheme base) (uri-userinfo base) (uri-host base) (uri-port base)
                            merged (uri-query r) (uri-fragment r)))))))))
