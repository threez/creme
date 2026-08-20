;; ===========================================================================
;; (creme svg): a minimal SVG bar-chart-grid builder
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme html)/(creme table)/(creme numfmt)/(creme color) use) rather than
;; compiled into either backend -- every export here is expressible in
;; plain R7RS with no opaque foreign object, stateful handle, or third-party
;; library involved, and it builds directly on (creme html)'s existing node
;; renderer instead of reimplementing one: html-render's node grammar
;; (`(tag . rest)` with an optional `(@ (name value) ...)` attrs block) is
;; already tag-agnostic -- it only special-cases HTML *void* elements (br,
;; img, ...), and SVG has none of those names, so ordinary SVG tags (svg,
;; rect, text) already round-trip through it correctly as ordinary
;; container elements (`<rect ...></rect>` is valid SVG embedded in an
;; HTML5 document, so no self-closing-tag support needs adding to the
;; renderer at all). Color math (darkening, categorical hues) is (creme
;; color)'s job, not this module's -- see that library's own header comment.
;;
;;   (svg-bar-chart-grid charts columns width height) -> ONE
;;     "<svg>...</svg>" string containing every chart in `charts` (a list
;;     of (title . items), items a list of (label . value-or-#f) pairs --
;;     value a real number or #f, "n/a", rendered as a zero-height column
;;     labeled "n/a", same convention (creme numfmt)'s own numfmt-fixed
;;     uses), each as its own titled, rounded, light-gray-bordered card,
;;     arranged in a grid with `columns` cards per row (row-major,
;;     wrapping; the last row is short if `charts`' length isn't a
;;     multiple of `columns`).
;;
;;     Inside each card: the chart's own title, centered at the top; below
;;     it, one column per (label . value) pair, arranged LEFT TO RIGHT in
;;     the item's own order, each growing BOTTOM TO TOP from a shared
;;     baseline -- an ordinary column chart, not a stacked one. Column
;;     height is proportional to value / (max non-#f value in that
;;     chart's own items), scaled so the tallest column in the chart
;;     reaches exactly `height`; `width` is the approximate width
;;     available for one chart's columns (actual per-column width is
;;     derived by dividing it evenly, with a fixed gap, across however
;;     many items that chart has). Each column's formatted value
;;     (numfmt-fixed value 2, or "n/a") is drawn just above it; its label
;;     is drawn just below the baseline. Every column has 3px rounded
;;     corners and a border.
;;
;;     Every column gets its own pastel fill, keyed by the column's OWN
;;     LABEL TEXT rather than its position ((creme color)'s
;;     categorical-color) -- this is what lets every chart in the grid
;;     render a given language in the SAME color, even though each
;;     chart's own column order can differ. The fill is 50% darker than
;;     the base pastel; the border is a further dark tint of the SAME hue
;;     (50% darker again, i.e. "100% darker" than the base pastel read as
;;     one more full halving step) rather than plain black, so a column's
;;     outline still visually reads as "the same color, darker".
;;
;;     Output size: every shared, per-element-identical style (rounded
;;     corners, stroke width, font-size, text-anchor, the card's own
;;     fill/stroke) lives once in a `<style>` block instead of being
;;     repeated as presentation attributes on every rect/text (fill/
;;     stroke on bars are the only per-element exception, since those
;;     genuinely vary by label); every numeric coordinate is rounded to 2
;;     decimal places (see `rnd` below) instead of carrying a full
;;     double's worth of decimal digits.
;;
;; Not auto-imported anywhere -- every script that wants svg-bar-chart-grid
;; must (import (creme svg)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme svg)
  (export svg-bar-chart-grid)
  (import (scheme base) (creme html) (creme numfmt) (creme color))
  (begin
    (define bar-gap 10)
    (define bar-min-width 20)
    (define label-font-size 10)
    (define value-font-size 10)
    (define title-font-size 13)
    ;; Vertical space reserved above the columns for value labels, and
    ;; below the baseline for column labels -- flat constants sized for
    ;; this module's own short label/value text, not general-purpose.
    (define value-space 14)
    (define label-space 16)
    (define title-space 22)
    ;; Card "box" styling/spacing: internal padding on every side, plus
    ;; the light-gray rounded border every chart is wrapped in.
    (define card-padding 8)
    (define card-gap 12)
    (define corner-radius 3)
    (define card-border-color "#cccccc")

    ;; Coerces to a plain inexact number -- forces a float instead of
    ;; risking an exact rational like 25/2 reaching `max`/`min` (which
    ;; only accept int/bigint/float). Used where a value still needs
    ;; further arithmetic, not final attribute embedding. `inexact` is
    ;; R7RS (scheme base)'s own name for what R5RS called exact->inexact.
    (define (px n) (inexact n))

    ;; Every numeric SVG attribute value goes through this instead of
    ;; `number->string` directly -- rounds to 2 decimal places (via
    ;; (creme numfmt)'s own exact-arithmetic-based numfmt-fixed, so no
    ;; floating-point print noise like "181.57281386236085" survives) and
    ;; returns the formatted STRING directly, which (creme html)'s
    ;; attribute writer accepts as-is (attr-value->string passes a string
    ;; through unchanged) -- shrinking every coordinate down to a handful
    ;; of bytes instead of a full double's worth of decimal digits.
    (define (rnd n) (numfmt-fixed n 2))

    ;; Shared CSS for every rect/text this module ever draws -- built
    ;; once from these same layout constants, factoring out the
    ;; attributes that are IDENTICAL on every card/bar/label instead of
    ;; repeating them on every single element (fill/stroke are the only
    ;; per-bar attributes left inline, since those genuinely vary by
    ;; label). rx/ry are valid CSS properties for SVG shapes (SVG2), same
    ;; visual effect as the rx/ry presentation attributes this replaces.
    (define (grid-css)
      (string-append
       ".card{fill:none;stroke:" card-border-color ";rx:" (number->string corner-radius)
       ";ry:" (number->string corner-radius) "}"
       ".bar{rx:" (number->string corner-radius) ";ry:" (number->string corner-radius) ";stroke-width:1.5}"
       ".lbl{font-size:" (number->string label-font-size) "px;text-anchor:middle}"
       ".title{font-size:" (number->string title-font-size) "px;text-anchor:middle}"))

    (define (svg-max-value items)
      (let loop ((items items) (best #f))
        (if (null? items)
            best
            (let ((v (cdar items)))
              (loop (cdr items) (if (and v (or (not best) (> v best))) v best))))))

    ;; `max` only accepts int/bigint/float (not exact rationals), so the
    ;; division here is forced inexact before it ever reaches `max`.
    (define (column-width n width)
      (if (= n 0) width (max bar-min-width (px (/ (- width (* (- n 1) bar-gap)) n)))))

    ;; One item at column `index` -> its bar rect (rounded, bordered,
    ;; pastel-filled), value label (above), and column label (below the
    ;; baseline) -- all offset by (dx, dy), the chart's own cell origin
    ;; within the grid.
    (define (svg-bar-column item index bw baseline height max-value dx dy)
      (let* ((label (car item))
             (value (cdr item))
             (x (+ dx (* index (+ bw bar-gap))))
             (bar-h (if (and value max-value (> max-value 0)) (* (/ value max-value) height) 0))
             (y (+ dy (- baseline bar-h)))
             (mid-x (+ x (/ bw 2)))
             (value-text (if value (numfmt-fixed value 2) "n/a"))
             (base-color (categorical-color label))
             (fill-color (color->css (color-darken base-color 50)))
             (border-color (color->css (color-darken base-color 75))))
        (list
         `(rect (@ (x ,(rnd x)) (y ,(rnd y)) (width ,(rnd bw)) (height ,(rnd bar-h))
                   (class "bar") (fill ,fill-color) (stroke ,border-color)))
         `(text (@ (x ,(rnd mid-x)) (y ,(rnd (- y 4))) (class "lbl")) ,value-text)
         `(text (@ (x ,(rnd mid-x)) (y ,(rnd (+ dy baseline label-space -2))) (class "lbl")) ,label))))

    (define (svg-bar-columns items bw baseline height max-value dx dy)
      (let loop ((items items) (i 0) (acc '()))
        (if (null? items)
            (reverse acc)
            (loop (cdr items) (+ i 1) (cons (svg-bar-column (car items) i bw baseline height max-value dx dy) acc)))))

    ;; One chart's card: its rounded light-gray border box, its title, and
    ;; its bar columns -- all offset by (dx, dy), the cell's own origin.
    (define (svg-chart-card chart cell-width cell-height width height dx dy)
      (let* ((title (car chart))
             (items (cdr chart))
             (n (length items))
             (bw (column-width n width))
             (max-value (svg-max-value items))
             (baseline (+ card-padding title-space height value-space))
             (columns (apply append (svg-bar-columns items bw baseline height max-value (+ dx card-padding) dy))))
        (cons
         `(rect (@ (x ,(rnd dx)) (y ,(rnd dy)) (width ,(rnd cell-width)) (height ,(rnd cell-height)) (class "card")))
         (cons
          `(text (@ (x ,(rnd (+ dx (/ cell-width 2)))) (y ,(rnd (+ dy card-padding title-font-size -2))) (class "title"))
                 ,title)
          columns))))

    (define (svg-bar-chart-grid charts columns width height)
      (let* ((n (length charts))
             (max-items (apply max 1 (map (lambda (c) (length (cdr c))) charts)))
             (bw (column-width max-items width))
             (bars-width (+ (* max-items bw) (* (max 0 (- max-items 1)) bar-gap)))
             (cell-width (+ bars-width (* 2 card-padding)))
             (cell-height (+ card-padding title-space height value-space label-space card-padding))
             (rows (if (= n 0) 0 (ceiling (/ n columns))))
             (grid-width (+ (* columns cell-width) (* (max 0 (- columns 1)) card-gap)))
             (grid-height (+ (* rows cell-height) (* (max 0 (- rows 1)) card-gap)))
             (nodes
              (apply append
                     (let loop ((charts charts) (i 0) (acc '()))
                       (if (null? charts)
                           (reverse acc)
                           (let* ((row (quotient i columns))
                                  (col (remainder i columns))
                                  (dx (* col (+ cell-width card-gap)))
                                  (dy (* row (+ cell-height card-gap))))
                             (loop (cdr charts) (+ i 1)
                                   (cons (svg-chart-card (car charts) cell-width cell-height width height dx dy)
                                         acc))))))))
        (html->string
         `(svg (@ (xmlns "http://www.w3.org/2000/svg")
                  (width ,(rnd grid-width)) (height ,(rnd grid-height))
                  (font-family "sans-serif")
                  (viewBox ,(string-append "0 0 " (rnd grid-width) " " (rnd grid-height))))
               (style (raw ,(grid-css)))
               ,@nodes))))))
