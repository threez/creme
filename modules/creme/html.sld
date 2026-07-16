;; ===========================================================================
;; (creme html): a small, efficient HTML-building toolkit, plus a table style
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme sxql)/(creme extra) use) rather than compiled into the interpreter
;; binary, since every export here is expressible in plain R7RS with no
;; opaque foreign object, stateful handle, or third-party Crystal library
;; involved — see modules/creme/extra.sld's own header comment for the same
;; rationale.
;;
;; Built as a PORT-BASED recursive builder rather than plain string
;; concatenation: every builder here writes its own fragments (and delegates
;; children to a thunk that writes into the SAME port) instead of returning a
;; string its caller then has to re-copy via string-append. A string output
;; port (open-output-string) wraps a real growable buffer under the hood, so
;; writing N fragments this way is O(total output size), not O(n²) the way
;; repeatedly string-append-ing an ever-larger accumulated string would be —
;; that's what "efficient" means here, and it's what lets this module build a
;; large or deeply-nested document without the cost blowing up.
;;
;;   (html-tag port name attrs body-thunk)   — <name attrs...>(body-thunk)</name>
;;   (html-void-tag port name attrs)         — <name attrs...>, no children/close
;;   (html-text port s)                      — writes s, HTML-escaped
;;   (html->string builder-thunk)            — runs (builder-thunk port) against
;;                                              a fresh string port, returns the
;;                                              accumulated string
;;   (html-document->string title css body)  — a full <!DOCTYPE html> document
;;
;; `attrs` (for html-tag/html-void-tag) is a flat list of alternating string
;; name/value pairs, e.g. (list "class" "report" "id" "main"), or '() for
;; none — attribute values are HTML-escaped same as text content.
;;
;; html-style is a (creme table) style function (see modules/creme/table.sld's
;; header comment for the style-function protocol) built from the above
;; primitives, producing a real <table> with <thead>/<tbody>/<tfoot> wrapping
;; whichever sections are present and <th> cells for header rows (vs. <td>
;; for body/footer rows) — genuine semantic markup, not just a plain-text
;; table with HTML tags glued on. This module has no code dependency on
;; (creme table) at all (html-style is just an ordinary procedure matching
;; that protocol by convention) — importing (creme table) too is only needed
;; to call table-style/table->string themselves:
;;
;;   (import (creme table) (creme html))
;;   (table->string rows aligns (table-style html-style 'header 1))
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme html)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme html)
  (export html-document->string html-escape html-style html->string
          html-tag html-text html-void-tag)
  (import (scheme base) (scheme write) (creme string))
  (begin
    ;; HTML-escaping for arbitrary text, safe to embed as either element
    ;; content (& < >) or an attribute value (" '), matching what standard
    ;; escapers do (e.g. Ruby's CGI.escapeHTML, Python's html.escape) — & is
    ;; replaced first, so escaping the other 4 doesn't introduce new &s that
    ;; then get escaped again.
    (define (html-escape s)
      (string-replace
       (string-replace
        (string-replace
         (string-replace
          (string-replace s "&" "&amp;")
          "<" "&lt;")
         ">" "&gt;")
        "\"" "&quot;")
       "'" "&#39;"))

    ;; ---- port-based builders ----------------------------------------------

    (define (write-attrs port attrs)
      (if (pair? attrs)
          (let ((name (car attrs)) (value (cadr attrs)))
            (write-string " " port)
            (write-string name port)
            (write-string "=\"" port)
            (write-string (html-escape value) port)
            (write-string "\"" port)
            (write-attrs port (cddr attrs)))))

    (define (write-open-tag port name attrs)
      (write-string "<" port)
      (write-string name port)
      (write-attrs port attrs)
      (write-string ">" port))

    ;; (html-tag port name attrs body-thunk) -> writes <name attrs...>, calls
    ;; (body-thunk) — expected to write its own content (text and/or nested
    ;; html-tag/html-void-tag/html-text calls) into this SAME port — then
    ;; writes </name>. The core recursive-builder primitive: no matter how
    ;; deep body-thunk's own nesting goes, every fragment is written exactly
    ;; once, directly into the one port shared by the whole call tree.
    (define (html-tag port name attrs body-thunk)
      (write-open-tag port name attrs)
      (body-thunk)
      (write-string "</" port)
      (write-string name port)
      (write-string ">" port))

    ;; (html-void-tag port name attrs) -> a self-closing/void element (meta,
    ;; br, hr, link, ...): <name attrs...>, no children, no closing tag.
    (define (html-void-tag port name attrs)
      (write-open-tag port name attrs))

    ;; (html-text port s) -> writes `s`, HTML-escaped, directly to `port`.
    (define (html-text port s)
      (write-string (html-escape s) port))

    ;; (html->string builder-thunk) -> runs (builder-thunk port) against a
    ;; fresh string port and returns the accumulated string — the bridge for
    ;; a caller that needs a final string (e.g. html-style's per-request
    ;; calls below, which must return a string per (creme table)'s
    ;; style-function protocol) while still using the port-based builders
    ;; internally instead of building its own string by hand.
    (define (html->string builder-thunk)
      (let ((port (open-output-string)))
        (builder-thunk port)
        (get-output-string port)))

    ;; (html-document->string title css body-thunk) -> a full <!DOCTYPE html>
    ;; document string: an escaped <title>, an inline <style> block holding
    ;; `css` verbatim (skipped if `css` is ""), and a <body> whose content is
    ;; written by (body-thunk port) — just one more builder-thunk
    ;; composition, not a separate mechanism from the rest of this module.
    (define (html-document->string title css body-thunk)
      (html->string
       (lambda (port)
         (write-string "<!DOCTYPE html>" port)
         (html-tag port "html" '()
           (lambda ()
             (html-tag port "head" '()
               (lambda ()
                 (html-void-tag port "meta" (list "charset" "utf-8"))
                 (html-tag port "title" '() (lambda () (html-text port title)))
                 (if (> (string-length css) 0)
                     (html-tag port "style" '() (lambda () (write-string css port))))))
             (html-tag port "body" '() (lambda () (body-thunk port))))))))

    ;; ---- table style --------------------------------------------------------

    (define (html-row port cell-tag cells)
      (html-tag port "tr" '()
        (lambda ()
          (for-each (lambda (c) (html-tag port cell-tag '() (lambda () (html-text port c)))) cells))))

    ;; A (creme table) style function producing a real <table>, with
    ;; <thead>/<tbody>/<tfoot> wrapping whichever sections are present and
    ;; <th> cells for header rows (vs. <td> for body/footer rows). Ignores
    ;; `widths`/`aligns`: a browser lays out column widths and text alignment
    ;; itself.
    (define (html-style request cells widths aligns)
      (case request
        ((top) "<table>")
        ((bottom) "</table>")
        ((header-open) "<thead>")
        ((header-close) "</thead>")
        ((body-open) "<tbody>")
        ((body-close) "</tbody>")
        ((footer-open) "<tfoot>")
        ((footer-close) "</tfoot>")
        ((header-row) (html->string (lambda (port) (html-row port "th" cells))))
        ((row footer-row) (html->string (lambda (port) (html-row port "td" cells))))
        (else (error "table style: unknown request" request))))))
