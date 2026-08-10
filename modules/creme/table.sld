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
;; — a base style (bordered-style, borderless-style, markdown-style, a
;; custom one from make-bordered-style/make-borderless-style, (creme html)'s
;; html-style, or a bespoke style function written from scratch) plus how
;; many leading/trailing rows are the header/footer:
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
;; (creme tui) (src/creme/modules/tui.cr) deliberately only wraps
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
  (export bordered-style borderless-style markdown-style make-bordered-style
          make-borderless-style table-style table->string)
  (import (scheme base) (scheme write) (scheme cxr)
          (only (creme string) string-join string-repeat)
          (only (creme extra) filter iota take drop))
  (begin

    ;; A cell's width as it actually occupies terminal columns, skipping any
    ;; embedded ANSI SGR escape sequence ("\x1b;[...m", R7RS's own #\escape
    ;; named character through the next 'm') -- a caller that colorizes cell
    ;; text (e.g. competition/bench.scm's per-column gradient) needs
    ;; column-widths/pad-cell sized against what's actually VISIBLE, not
    ;; against invisible escape bytes: a border segment is built from
    ;; ordinary repeated dash characters with no invisible bytes of its own
    ;; to absorb that inflation, so sizing borders off the raw (escape-
    ;; inclusive) string length leaves them visibly wider than the padded
    ;; cell text above/below — a real misalignment, not a cosmetic one. A
    ;; plain cell with no escape sequence measures exactly as string-length
    ;; would (the scan below never finds a #\escape to skip past).
    (define (visible-length s)
      (let ((len (string-length s)))
        (let loop ((i 0) (n 0))
          (cond ((= i len) n)
                ((char=? (string-ref s i) #\escape)
                 (let skip ((j (+ i 1)))
                   (cond ((= j len) n)
                         ((char=? (string-ref s j) #\m) (loop (+ j 1) n))
                         (else (skip (+ j 1))))))
                (else (loop (+ i 1) (+ n 1)))))))

    ;; Column i's width: the widest cell (by visible-length) across every
    ;; row at that index.
    (define (column-widths rows)
      (map (lambda (i) (apply max (map (lambda (row) (visible-length (list-ref row i))) rows)))
           (iota (length (car rows)))))

    ;; Pads by VISIBLE length, not raw string-length -- (creme string)'s
    ;; string-pad/string-pad-right pad against a Crystal String's own
    ;; .size (every byte, escape sequences included), which would under-pad
    ;; an already-colorized cell by exactly its escape overhead. Built
    ;; directly here instead (plain space characters, no other dependency)
    ;; so this stays correct for both plain and colorized cells alike.
    (define (pad-cell cell width align)
      (let* ((deficit (max 0 (- width (visible-length cell))))
             (padding (make-string deficit #\space)))
        (if (eq? align 'left)
            (string-append cell padding)
            (string-append padding cell))))

    (define (non-empty? s) (> (string-length s) 0))

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

    ;; ---- markdown style -----------------------------------------------------

    ;; GFM-flavored markdown: pipe-delimited rows plus a `---`/`:---`/`---:`
    ;; alignment separator directly below the header row. Assumes exactly one
    ;; header row, matching every real bench-table->string/->html call site
    ;; today (they all pass 'header 1) — GFM's separator must sit immediately
    ;; under the header, so there's no way to express a markdown table with
    ;; zero header rows; a style request sequence with no header section
    ;; would render as ordinary pipe-joined text, not a real table.

    ;; A literal "|" inside cell text would otherwise be read as a column
    ;; separator by any markdown renderer — escape it, the one character
    ;; markdown table syntax itself is sensitive to.
    (define (escape-pipes s)
      (let loop ((i 0) (acc '()))
        (if (= i (string-length s))
            (apply string-append (reverse acc))
            (loop (+ i 1)
                  (cons (if (char=? (string-ref s i) #\|) "\\|" (string (string-ref s i)))
                        acc)))))

    (define (markdown-cell-row cells widths aligns)
      (string-append
       "| "
       (string-join (map (lambda (c w a) (pad-cell (escape-pipes c) w a)) cells widths aligns) " | ")
       " |"))

    ;; One column's separator segment: `n` dashes (at least 3, GFM's own
    ;; minimum). No per-column alignment marker (`:---`/`---:`) — the style
    ;; protocol only passes real `aligns` alongside a *-row request; 'header-
    ;; close (where this separator is built) gets #f in aligns' place, same
    ;; as every other widths-only request, so a column's actual alignment
    ;; isn't available here to encode. The already-padded cell text above/
    ;; below still reads aligned in the raw markdown source; only the
    ;; *rendered* table loses per-column alignment, defaulting to left.
    (define (markdown-separator widths)
      (string-append "| " (string-join (map (lambda (w) (string-repeat "-" (max 3 w))) widths) " | ") " |"))

    (define (markdown-style request cells widths aligns)
      (case request
        ((top bottom header-open body-open body-close footer-open footer-close) "")
        ((header-close) (markdown-separator widths))
        ((header-row row footer-row) (markdown-cell-row cells widths aligns))
        (else (error "table style: unknown request" request))))

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
