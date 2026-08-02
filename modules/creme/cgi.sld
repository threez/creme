;; ===========================================================================
;; (creme cgi): form-urlencoding, HTML-entity escaping, and query-string
;; parsing, matching Ruby's CGI module's escaping/parsing surface
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme pathname)/(creme abbrev) use) since every export here is
;; expressible in plain R7RS on top of bytevector ports/(creme html)'s own
;; escaper, with no opaque foreign object or third-party Crystal library
;; involved. Deliberately scoped to escaping/parsing only -- Ruby's CGI
;; class also has a whole CGI-script/HTTP-request-reading API, entirely
;; out of scope here (that's (creme mux)'s job).
;;
;;   (cgi-escape s)    -> s as application/x-www-form-urlencoded: every
;;                        byte of s's UTF-8 encoding except ASCII
;;                        alphanumerics and `_ . -` is percent-encoded
;;                        (%XX, uppercase hex) EXCEPT a space, which
;;                        becomes `+` -- Ruby's exact CGI.escape unsafe
;;                        set, not RFC 3986's broader "unreserved" set
;;                        (which additionally allows `~`) -- see (creme
;;                        uri)'s uri-encode-www-form/uri-decode-www-form,
;;                        which are thin wrappers over this pair.
;;   (cgi-unescape s)  -> the inverse: `+` decodes to a space, `%XX`
;;                        decodes to that byte, everything else passes
;;                        through as-is (bytes are reassembled via a
;;                        bytevector port and utf8->string, so a
;;                        percent-encoded multi-byte UTF-8 sequence
;;                        round-trips correctly)
;;   (cgi-escape-html s)   -> delegates to (creme html)'s own html-escape
;;                            (the same 5-entity table: & < > " '),
;;                            rather than duplicating it
;;   (cgi-unescape-html s) -> decodes &amp; &lt; &gt; &quot; &#39; &apos;
;;                            plus any numeric character reference
;;                            (&#NN; decimal or &#xHH;/&#XHH; hex) --
;;                            deliberately NOT Ruby's full ~250-entry
;;                            legacy HTML4 named-entity table (&yen;,
;;                            &copy;, etc.): those never round-trip
;;                            through cgi-escape-html in the first place
;;                            (which only ever emits the 5 basic ones),
;;                            so decoding them is a separate, much larger
;;                            static-table feature this library doesn't
;;                            take on. An unrecognized `&...;` sequence
;;                            (or a bare `&`) passes through unchanged.
;;   (cgi-parse qs)    -> a raw query string (no leading `?`) parsed into
;;                        an alist `(key . (value ...))` -- REPEATED keys
;;                        accumulate every occurrence's value in order,
;;                        rather than the last one winning, matching
;;                        Ruby's CGI.parse exactly (e.g. "a=1&a=2" ->
;;                        (("a" "1" "2"))); a key with no `=` at all maps
;;                        to a single empty-string value (("a" ""));
;;                        every key/value is cgi-unescape'd. Key order in
;;                        the result alist is first-seen order, matching
;;                        Ruby Hash's own insertion-order iteration.
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme cgi)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme cgi)
  (export cgi-escape cgi-unescape cgi-escape-html cgi-unescape-html cgi-parse)
  (import (scheme base) (creme string) (creme html))
  (begin
    (define (cgi-priv-safe-byte? b)
      (or (and (>= b 48) (<= b 57))
          (and (>= b 65) (<= b 90))
          (and (>= b 97) (<= b 122))
          (= b 95) (= b 46) (= b 45)))

    (define (cgi-priv-hex2 b)
      (let ((s (number->string b 16)))
        (string-upcase (if (= (string-length s) 1) (string-append "0" s) s))))

    (define (cgi-priv-escape-byte b)
      (cond
       ((cgi-priv-safe-byte? b) (string (integer->char b)))
       ((= b 32) "+")
       (else (string-append "%" (cgi-priv-hex2 b)))))

    (define (cgi-escape s)
      (let* ((bv (string->utf8 s)) (n (bytevector-length bv)))
        (let loop ((i 0) (acc '()))
          (if (= i n)
              (apply string-append (reverse acc))
              (loop (+ i 1) (cons (cgi-priv-escape-byte (bytevector-u8-ref bv i)) acc))))))

    (define (cgi-unescape s)
      (let ((n (string-length s)) (out (open-output-bytevector)))
        (let loop ((i 0))
          (if (< i n)
              (let ((c (string-ref s i)))
                (cond
                 ((char=? c #\+) (write-u8 32 out) (loop (+ i 1)))
                 ((and (char=? c #\%) (<= (+ i 3) n) (string->number (substring s (+ i 1) (+ i 3)) 16))
                  (write-u8 (string->number (substring s (+ i 1) (+ i 3)) 16) out)
                  (loop (+ i 3)))
                 (else
                  (let* ((cb (string->utf8 (string c))) (m (bytevector-length cb)))
                    (let byte-loop ((j 0))
                      (if (< j m)
                          (begin (write-u8 (bytevector-u8-ref cb j) out) (byte-loop (+ j 1)))))
                    (loop (+ i 1)))))))
        (utf8->string (get-output-bytevector out)))))

    (define (cgi-escape-html s) (html-escape s))

    (define (cgi-priv-matches? s i lit n)
      (and (<= (+ i (string-length lit)) n)
           (string=? (substring s i (+ i (string-length lit))) lit)))

    (define (cgi-priv-digit? c) (and (char>=? c #\0) (char<=? c #\9)))

    (define (cgi-priv-hex-digit? c)
      (or (cgi-priv-digit? c)
          (and (char>=? c #\a) (char<=? c #\f))
          (and (char>=? c #\A) (char<=? c #\F))))

    (define (cgi-priv-try-numeric-entity s i n)
      (if (and (< (+ i 1) n) (char=? (string-ref s (+ i 1)) #\#))
          (let* ((hexp (and (< (+ i 2) n)
                             (or (char=? (string-ref s (+ i 2)) #\x) (char=? (string-ref s (+ i 2)) #\X))))
                 (start (if hexp (+ i 3) (+ i 2))))
            (let loop ((j start))
              (cond
               ((and (< j n) (if hexp (cgi-priv-hex-digit? (string-ref s j)) (cgi-priv-digit? (string-ref s j))))
                (loop (+ j 1)))
               ((and (> j start) (< j n) (char=? (string-ref s j) #\;))
                (let ((code (string->number (substring s start j) (if hexp 16 10))))
                  (if code (cons (string (integer->char code)) (+ j 1)) #f)))
               (else #f))))
          #f))

    (define (cgi-priv-try-entity s i n)
      (cond
       ((cgi-priv-matches? s i "&amp;" n) (cons "&" (+ i 5)))
       ((cgi-priv-matches? s i "&lt;" n) (cons "<" (+ i 4)))
       ((cgi-priv-matches? s i "&gt;" n) (cons ">" (+ i 4)))
       ((cgi-priv-matches? s i "&quot;" n) (cons "\"" (+ i 6)))
       ((cgi-priv-matches? s i "&#39;" n) (cons "'" (+ i 5)))
       ((cgi-priv-matches? s i "&apos;" n) (cons "'" (+ i 6)))
       (else (cgi-priv-try-numeric-entity s i n))))

    (define (cgi-unescape-html s)
      (let ((n (string-length s)))
        (let loop ((i 0) (acc '()))
          (if (>= i n)
              (apply string-append (reverse acc))
              (if (char=? (string-ref s i) #\&)
                  (let ((m (cgi-priv-try-entity s i n)))
                    (if m
                        (loop (cdr m) (cons (car m) acc))
                        (loop (+ i 1) (cons (string (string-ref s i)) acc))))
                  (loop (+ i 1) (cons (string (string-ref s i)) acc)))))))

    (define (cgi-priv-parse-update acc key val)
      (if (null? acc)
          (list (cons key (list val)))
          (let ((entry (car acc)))
            (if (equal? (car entry) key)
                (cons (cons key (append (cdr entry) (list val))) (cdr acc))
                (cons entry (cgi-priv-parse-update (cdr acc) key val))))))

    (define (cgi-parse qs)
      (if (string=? qs "")
          '()
          (let loop ((pairs (string-split qs "&")) (acc '()))
            (if (null? pairs)
                acc
                (let* ((pair (car pairs))
                       (eq-idx (string-index-of pair "="))
                       (key (cgi-unescape (if eq-idx (substring pair 0 eq-idx) pair)))
                       (val (cgi-unescape (if eq-idx (substring pair (+ eq-idx 1) (string-length pair)) ""))))
                  (loop (cdr pairs) (cgi-priv-parse-update acc key val)))))))))
