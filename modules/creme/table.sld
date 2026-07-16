;; ===========================================================================
;; (creme table): bordered/borderless text-table rendering, pluggable styles
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme sxql)/(creme extra) use) rather than compiled into the interpreter
;; binary, since every export here is expressible in plain R7RS with no
;; opaque foreign object, stateful handle, or third-party Crystal library
;; involved — see modules/creme/extra.sld's own header comment for the same
;; rationale.
;;
;; table->string takes a plain list of rows — there's no separate "headers"
;; argument. A compiled style (see table-style below) says how many of the
;; LEADING rows are header rows and how many of the TRAILING rows are footer
;; rows; everything else is an ordinary body row. Each of the 3 sections gets
;; its own open/row/close requests, so a style can wrap a section in
;; something real (<thead>/<tbody>/<tfoot>) and render its row(s) differently
;; (<th> vs <td>), not just draw a divider line between otherwise-identical
;; rows. A style function is `(style request cells widths aligns)`:
;;
;;   'top                                    (widths only)
;;   'header-open  'header-row  'header-close (row: cells = a header row, once
;;                                              per header row — only called
;;                                              at all if there IS one)
;;   'body-open    'row         'body-close    (row: cells = a body row, once
;;                                              per row)
;;   'footer-open  'footer-row  'footer-close  (row: cells = a footer row,
;;                                              once per row — only called at
;;                                              all if there IS one)
;;   'bottom                                  (widths only)
;;
;; `cells`/`aligns` only matter for the 3 *-row requests — the rest only need
;; `widths`, and are called with #f in cells'/aligns' place. Every request
;; returns one string (possibly itself containing embedded newlines — that's
;; fine, table->string just treats it as one chunk of text), or "" if that
;; style draws nothing there; table->string filters out "" results and joins
;; the rest with "\n". A borderless style is simply one whose every request
;; except the 3 *-row ones always returns "".
;;
;; table->string only ever accepts a COMPILED style, produced by table-style
;; — a base style (bordered-style, borderless-style, a custom one from
;; make-bordered-style/make-borderless-style, (creme html)'s html-style, or
;; a bespoke style function written from scratch) plus how many leading/
;; trailing rows are the header/footer:
;;
;;   (table-style bordered-style 'header 1 'footer 1)
;;   ; -> the first row is the header section, the last is the footer
;;   ; section; unspecified, both default to 0 (no header/footer section —
;;   ; every row is an ordinary body row) — explicit opt-in either way, so
;;   ; a row is never silently mistaken for a header/footer.
;;
;; The default bordered glyphs are borrowed from lib/tui/src/tui/core/term.cr
;; (a vendored Crystal shard's terminal-UI helpers) purely for the character
;; choices — there's no existing Scheme-exposed table/box API to reuse:
;; (creme tui) (src/scheme/modules/tui.cr) deliberately only wraps
;; color/style/buffer/window primitives, not box or table rendering.
;;
;; This module only lays out already-stringified cells — it has no idea
;; what a number, a ratio, or "unavailable" means. See (creme numfmt) for
;; formatting values into the strings this module then renders.
;;
;; Not auto-imported anywhere — every script that wants table->string must
;; (import (creme table)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme table)
  (export bordered-style borderless-style make-bordered-style
          make-borderless-style table-style table->string)
  (import (scheme base) (scheme write) (scheme cxr) (creme string))
  (begin
    ;; (0 1 ... n-1), for indexed list-ref access — kept local rather than
    ;; pulling in (creme extra)'s iota, to keep this module's imports minimal.
    (define (range n)
      (let loop ((i (- n 1)) (acc '()))
        (if (< i 0) acc (loop (- i 1) (cons i acc)))))

    ;; Column i's width: the widest cell across every row at that index.
    (define (column-widths rows)
      (map (lambda (i) (apply max (map (lambda (row) (string-length (list-ref row i))) rows)))
           (range (length (car rows)))))

    (define (pad-cell cell width align)
      (if (eq? align 'left)
          (string-pad-right cell width " ")
          (string-pad cell width " ")))

    (define (non-empty? s) (> (string-length s) 0))

    ;; SRFI-1-style helpers, not exported by (scheme base) — kept local
    ;; rather than pulling in (creme extra) for these few uses.
    (define (filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
            (else (filter pred (cdr lst)))))

    (define (take lst n)
      (if (or (<= n 0) (null? lst)) '() (cons (car lst) (take (cdr lst) (- n 1)))))

    (define (drop lst n)
      (if (or (<= n 0) (null? lst)) lst (drop (cdr lst) (- n 1))))

    ;; (plist-ref plist key default) — plist alternates keys and values;
    ;; returns the value after the first eq? match, or `default`.
    (define (plist-ref plist key default)
      (cond ((null? plist) default)
            ((eq? (car plist) key) (cadr plist))
            (else (plist-ref (cddr plist) key default))))

    ;; Splits `rows` into (header-rows body-rows footer-rows): the first
    ;; `header-n` rows and the last `footer-n` rows (both clamped so they
    ;; never overlap, even if header-n + footer-n exceeds the row count).
    (define (split-sections rows header-n footer-n)
      (let* ((total (length rows))
             (h (max 0 (min header-n total)))
             (f (max 0 (min footer-n (- total h))))
             (header-rows (take rows h))
             (rest (drop rows h))
             (body-count (- (length rest) f)))
        (list header-rows (take rest body-count) (drop rest body-count))))

    ;; ---- bordered style -----------------------------------------------------

    ;; One border line (top border, a section divider, or the bottom border):
    ;; each column becomes a `fill`-repeated segment two chars wider than its
    ;; content width (matching bordered-row's 1-space padding on each side),
    ;; joined by `junction` and capped by `left`/`right`.
    (define (border-line left fill junction right widths)
      (string-append
       left
       (string-join (map (lambda (w) (string-repeat fill (+ w 2))) widths) junction)
       right))

    ;; One content line, cells separated by vertical lines with a space of
    ;; breathing room on each side. Used for header rows, ordinary rows, and
    ;; footer rows alike — bordered-style doesn't render any of the 3
    ;; differently.
    (define (bordered-row vl cells widths aligns)
      (string-append
       vl " "
       (string-join (map (lambda (c w a) (pad-cell c w a)) cells widths aligns)
                     (string-append " " vl " "))
       " " vl))

    ;; (make-bordered-style tl tr bl br hl vl tj bj lj rj cj) -> a style
    ;; function drawing a full box with the given 11 glyphs (4 corners, the
    ;; horizontal/vertical line chars, and the 5 T-junction/cross chars used
    ;; for the top border, a section divider, and the bottom border). Draws
    ;; one divider between the header and body (only if there's a header),
    ;; and one between the body and a footer (only if there's a footer).
    (define (make-bordered-style tl tr bl br hl vl tj bj lj rj cj)
      (lambda (request cells widths aligns)
        (case request
          ((top) (border-line tl hl tj tr widths))
          ((bottom) (border-line bl hl bj br widths))
          ((header-close footer-open) (border-line lj hl cj rj widths))
          ((header-open body-open body-close footer-close) "")
          ((header-row row footer-row) (bordered-row vl cells widths aligns))
          (else (error "table style: unknown request" request)))))

    (define bordered-style
      (make-bordered-style "╭" "╮" "╰" "╯" "─" "│" "┬" "┴" "├" "┤" "┼"))

    ;; ---- borderless style -----------------------------------------------------

    ;; (make-borderless-style gap) -> a style function with no lines at all
    ;; (every section open/close draws nothing): padded cells joined by `gap`,
    ;; the same way for header rows, ordinary rows, and footer rows alike.
    (define (make-borderless-style gap)
      (lambda (request cells widths aligns)
        (case request
          ((top bottom header-open header-close body-open body-close footer-open footer-close) "")
          ((header-row row footer-row) (string-join (map (lambda (c w a) (pad-cell c w a)) cells widths aligns) gap))
          (else (error "table style: unknown request" request)))))

    (define borderless-style (make-borderless-style "  "))

    ;; ---- compiling a style + header/footer placement into one value ----------

    ;; (table-style base-style key val ...) -> a compiled style: same calling
    ;; convention as `base-style` — every request delegated straight through —
    ;; plus 'header-count/'footer-count, answered from the trailing plist
    ;; (keys 'header/'footer, each an integer: how many of the leading/
    ;; trailing rows table->string should treat as the header/footer
    ;; section). Unspecified, both default to 0 (no header/footer section).
    (define (table-style base-style . plist)
      (let ((header-count (plist-ref plist 'header 0))
            (footer-count (plist-ref plist 'footer 0)))
        (lambda (request cells widths aligns)
          (case request
            ((header-count) header-count)
            ((footer-count) footer-count)
            (else (base-style request cells widths aligns))))))

    ;; ---- rendering ------------------------------------------------------------

    ;; (table->string rows aligns style) -> a multi-line string (no trailing
    ;; newline). Each row in `rows` is a list of already-stringified cells,
    ;; one per column; `aligns` is a same-length list of 'left/'right
    ;; symbols; `style` is a compiled style produced by table-style (see this
    ;; file's header comment), which says how many leading/trailing rows are
    ;; the header/footer.
    (define (table->string rows aligns style)
      (let* ((widths (column-widths rows))
             (sections (split-sections rows
                                        (style 'header-count #f widths #f)
                                        (style 'footer-count #f widths #f)))
             (header-rows (car sections))
             (body-rows (cadr sections))
             (footer-rows (caddr sections))
             (lines (append
                     (list (style 'top #f widths #f))
                     (if (null? header-rows)
                         '()
                         (append
                          (list (style 'header-open #f widths #f))
                          (map (lambda (row) (style 'header-row row widths aligns)) header-rows)
                          (list (style 'header-close #f widths #f))))
                     (list (style 'body-open #f widths #f))
                     (map (lambda (row) (style 'row row widths aligns)) body-rows)
                     (list (style 'body-close #f widths #f))
                     (if (null? footer-rows)
                         '()
                         (append
                          (list (style 'footer-open #f widths #f))
                          (map (lambda (row) (style 'footer-row row widths aligns)) footer-rows)
                          (list (style 'footer-close #f widths #f))))
                     (list (style 'bottom #f widths #f)))))
        (string-join (filter non-empty? lines) "\n")))))
