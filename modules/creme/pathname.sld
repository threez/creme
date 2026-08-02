;; ===========================================================================
;; (creme pathname): pure string path parsing, matching Ruby's Pathname
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme ostruct)/(creme abbrev) use) since every export here is
;; expressible in plain R7RS string operations on top of (creme string),
;; with no filesystem access at all -- that's (creme file)'s job.
;; (creme path) already covers the opposite direction (building a path
;; string forward, macro-folded, from scratch); this library instead
;; parses an existing path string backward into its components. Every
;; method here is lexical/textual only, matching Ruby's #cleanpath (not
;; #realpath): no method here ever touches the filesystem, so a symlink,
;; a nonexistent path, or a relative "..", is handled exactly the same as
;; any other path text, without checking whether it actually exists or
;; where it would really resolve on disk.
;;
;; A <pathname> record wraps one path string, so results chain the way
;; Ruby's Pathname objects do (pathname-dirname's result is itself a
;; pathname, so pathname-basename can be called on it directly, etc.).
;;
;;   (make-pathname str)       -> a new <pathname> wrapping str verbatim
;;   (pathname? x)
;;   (pathname->string p)      -> p's underlying path string
;;   (pathname-dirname p)      -> p's directory part, as a pathname
;;                                (POSIX dirname semantics: dirname("a")
;;                                is ".", dirname("/a") is "/",
;;                                dirname("/a/b") is "/a")
;;   (pathname-basename p)          -> p's final path component, as a
;;                                      pathname (basename("") is ".",
;;                                      basename("/") is "/")
;;   (pathname-basename p ext)      -> like the above, but with a
;;                                      trailing extension stripped: ext
;;                                      "*" or ".*" strips whatever
;;                                      pathname-extname would report;
;;                                      any other ext string is stripped
;;                                      only if it's an exact trailing
;;                                      match
;;   (pathname-extname p)           -> the last extension of p's
;;                                      basename, dot included, or "" if
;;                                      there isn't one -- a leading dot
;;                                      alone doesn't count as one
;;                                      (extname(".bashrc") is "", not
;;                                      ".bashrc"), matching Ruby/POSIX
;;   (pathname-split p)             -> two values: (pathname-dirname p)
;;                                      and (pathname-basename p)
;;   (pathname-join p seg ...)      -> p with each seg appended in turn
;;                                      (a plain string or another
;;                                      pathname), "/"-joined, THEN
;;                                      lexically cleaned (see
;;                                      pathname-cleanpath below) -- if
;;                                      any seg is itself absolute, every
;;                                      segment before it is discarded,
;;                                      matching Ruby's Pathname#+/#join
;;                                      exactly
;;   (pathname-absolute? p) / (pathname-relative? p)
;;   (pathname-cleanpath p)         -> p with every "." component
;;                                      dropped and every ".." component
;;                                      resolved against the preceding
;;                                      real component where possible
;;                                      (an absolute path's leading ".."
;;                                      is simply dropped -- there's
;;                                      nothing above root to go to; a
;;                                      relative path's leading ".." is
;;                                      kept, since there's no real
;;                                      component yet to cancel it
;;                                      against) -- purely lexical, same
;;                                      caveat as #realpath not being
;;                                      implemented here at all
;;   (pathname-parent p)            -> (pathname-join p "..")
;;   (pathname-each-filename p)     -> p's real path components (no
;;                                      empty segments from doubled/
;;                                      leading/trailing slashes), as a
;;                                      list of plain strings, in order
;;   (pathname-sub-ext p newext)    -> p with its existing extension (if
;;                                      any) replaced by newext (which
;;                                      should include its own leading
;;                                      dot, e.g. ".rb")
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme pathname)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme pathname)
  (export make-pathname pathname? pathname->string pathname-dirname
          pathname-basename pathname-extname pathname-split pathname-join
          pathname-absolute? pathname-relative? pathname-cleanpath
          pathname-parent pathname-each-filename pathname-sub-ext)
  (import (scheme base) (creme string))
  (begin
    (define-record-type <pathname>
      (make-pathname path)
      pathname?
      (path pathname->string))

    (define (pathname-priv-filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (pathname-priv-filter pred (cdr lst))))
            (else (pathname-priv-filter pred (cdr lst)))))

    (define (pathname-priv-last lst)
      (if (null? (cdr lst)) (car lst) (pathname-priv-last (cdr lst))))

    (define (pathname-priv-drop-last lst)
      (if (null? (cdr lst)) '() (cons (car lst) (pathname-priv-drop-last (cdr lst)))))

    ;; Non-empty "/"-separated segments of s, keeping "." and ".." as-is.
    (define (pathname-priv-segments s)
      (pathname-priv-filter (lambda (seg) (> (string-length seg) 0)) (string-split s "/")))

    (define (pathname-priv-absolute? s)
      (and (> (string-length s) 0) (string-prefix? s "/")))

    (define (pathname-priv-basename s)
      (let ((segs (pathname-priv-segments s)))
        (cond
         ((not (null? segs)) (pathname-priv-last segs))
         ((pathname-priv-absolute? s) "/")
         (else "."))))

    (define (pathname-priv-dirname s)
      (let ((segs (pathname-priv-segments s)))
        (cond
         ((or (null? segs) (null? (cdr segs)))
          (if (pathname-priv-absolute? s) "/" "."))
         (else
          (string-append
           (if (pathname-priv-absolute? s) "/" "")
           (string-join (pathname-priv-drop-last segs) "/"))))))

    (define (pathname-priv-extname-of-basename b)
      (if (or (string=? b ".") (string=? b ".."))
          ""
          (let* ((parts (string-split b ".")) (n (length parts)))
            (cond
             ((<= n 1) "")
             ((and (string=? (car parts) "") (= n 2)) "")
             (else (string-append "." (pathname-priv-last parts)))))))

    (define (pathname-dirname p) (make-pathname (pathname-priv-dirname (pathname->string p))))

    (define (pathname-basename p . ext-opt)
      (let ((b (pathname-priv-basename (pathname->string p))))
        (make-pathname
         (if (null? ext-opt)
             b
             (let ((ext (car ext-opt)))
               (cond
                ((or (string=? ext "*") (string=? ext ".*"))
                 (let ((e (pathname-priv-extname-of-basename b)))
                   (if (string=? e "") b (substring b 0 (- (string-length b) (string-length e))))))
                ((and (> (string-length ext) 0) (string-suffix? b ext))
                 (substring b 0 (- (string-length b) (string-length ext))))
                (else b)))))))

    (define (pathname-extname p)
      (pathname-priv-extname-of-basename (pathname-priv-basename (pathname->string p))))

    (define (pathname-split p) (values (pathname-dirname p) (pathname-basename p)))

    (define (pathname-absolute? p) (pathname-priv-absolute? (pathname->string p)))
    (define (pathname-relative? p) (not (pathname-absolute? p)))

    (define (pathname-priv-str x) (if (pathname? x) (pathname->string x) x))

    (define (pathname-priv-join-two a b)
      (cond
       ((string=? b "") a)
       ((pathname-priv-absolute? b) b)
       ((string=? a "") b)
       ((string-suffix? a "/") (string-append a b))
       (else (string-append a "/" b))))

    (define (pathname-priv-remove-dots lst)
      (pathname-priv-filter (lambda (s) (not (string=? s "."))) lst))

    (define (pathname-priv-cleanpath-segs segs absolute?)
      (let loop ((segs segs) (stack '()))
        (cond
         ((null? segs) (reverse stack))
         ((string=? (car segs) "..")
          (cond
           ((and (not (null? stack)) (not (string=? (car stack) "..")))
            (loop (cdr segs) (cdr stack)))
           (absolute? (loop (cdr segs) stack))
           (else (loop (cdr segs) (cons ".." stack)))))
         (else (loop (cdr segs) (cons (car segs) stack))))))

    (define (pathname-cleanpath p)
      (let* ((s (pathname->string p))
             (abs? (pathname-priv-absolute? s))
             (no-dot (pathname-priv-remove-dots (pathname-priv-segments s)))
             (cleaned (pathname-priv-cleanpath-segs no-dot abs?)))
        (make-pathname
         (cond
          ((and abs? (null? cleaned)) "/")
          ((and (not abs?) (null? cleaned)) ".")
          (else (string-append (if abs? "/" "") (string-join cleaned "/")))))))

    (define (pathname-join p . segs)
      (let loop ((acc (pathname->string p)) (rest segs))
        (if (null? rest)
            (pathname-cleanpath (make-pathname acc))
            (loop (pathname-priv-join-two acc (pathname-priv-str (car rest))) (cdr rest)))))

    (define (pathname-parent p) (pathname-join p ".."))

    (define (pathname-each-filename p) (pathname-priv-segments (pathname->string p)))

    (define (pathname-priv-with-dir dir filename)
      (cond
       ((string=? dir ".") filename)
       ((string=? dir "/") (string-append "/" filename))
       (else (string-append dir "/" filename))))

    (define (pathname-sub-ext p newext)
      (let* ((s (pathname->string p))
             (dir (pathname-priv-dirname s))
             (base (pathname-priv-basename s))
             (ext (pathname-priv-extname-of-basename base))
             (stem (if (string=? ext "") base (substring base 0 (- (string-length base) (string-length ext))))))
        (make-pathname (pathname-priv-with-dir dir (string-append stem newext)))))))
