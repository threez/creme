;; ===========================================================================
;; (creme color): small HSL color-math helpers
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme html)/(creme svg)/(creme numfmt) use) rather than compiled into
;; either backend -- every export here is expressible in plain R7RS with no
;; opaque foreign object, stateful handle, or third-party library involved.
;;
;; An HSL color is a plain 3-element list (hue saturation lightness): hue
;; in [0,360), saturation/lightness in [0,100] -- no opaque record type,
;; just a small constructor/accessor set, so a color is ordinary data any
;; caller can build, pattern-match, or pass around freely.
;;
;;   (hsl h s l)                    -> a color
;;   (hsl-hue c) / (hsl-saturation c) / (hsl-lightness c)
;;   (color-darken c percent)       -> c with its lightness reduced by
;;                                      `percent`% of its CURRENT value
;;                                      (0 = unchanged, 50 = half as light,
;;                                      100 = black) -- hue/saturation
;;                                      untouched, so repeated darkening
;;                                      steps read as "same hue, darker"
;;                                      rather than drifting toward black
;;                                      after just one step.
;;   (color-lighten c percent)      -> symmetric, moves lightness toward
;;                                      100 by `percent`% of the REMAINING
;;                                      headroom (100 - current lightness).
;;   (color->css c)                 -> "hsl(h, s%, l%)", each component
;;                                      rounded to 2 decimal places (via
;;                                      (creme numfmt)'s own exact-
;;                                      arithmetic-based numfmt-fixed, so
;;                                      no floating-point print noise like
;;                                      "18.841796875" survives into the
;;                                      output)
;;   (categorical-color label)      -> a deterministic, well-spread pastel
;;                                      color for `label` -- hue from a
;;                                      cheap string hash stepped by the
;;                                      golden angle (137.508 degrees), a
;;                                      standard technique for generating
;;                                      N maximally-distinct categorical
;;                                      hues without knowing N up front;
;;                                      fixed pastel saturation/lightness
;;                                      (65%, 82%). Keyed by the label's
;;                                      own TEXT (not a positional index),
;;                                      so two independent callers asking
;;                                      for the same label's color always
;;                                      agree, with no shared state.
;;
;; Not auto-imported anywhere -- every script that wants any of this must
;; (import (creme color)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme color)
  (export hsl hsl-hue hsl-saturation hsl-lightness
          color-darken color-lighten color->css categorical-color)
  (import (scheme base) (scheme cxr) (creme numfmt))
  (begin
    (define (hsl h s l) (list h s l))
    (define (hsl-hue c) (car c))
    (define (hsl-saturation c) (cadr c))
    (define (hsl-lightness c) (caddr c))

    (define (color-darken c percent)
      (hsl (hsl-hue c) (hsl-saturation c) (* (hsl-lightness c) (- 1 (/ percent 100)))))

    (define (color-lighten c percent)
      (let ((l (hsl-lightness c)))
        (hsl (hsl-hue c) (hsl-saturation c) (+ l (* (- 100 l) (/ percent 100))))))

    (define (color->css c)
      (string-append "hsl(" (numfmt-fixed (hsl-hue c) 2) ", "
                      (numfmt-fixed (hsl-saturation c) 2) "%, "
                      (numfmt-fixed (hsl-lightness c) 2) "%)"))

    ;; x mod m, for real (not just integer) x -- (scheme base)'s own
    ;; modulo/remainder require integer arguments.
    (define (fmod x m) (- x (* m (floor (/ x m)))))

    ;; A cheap string hash (no cryptographic properties needed -- just
    ;; enough spread to feed the golden-angle hue step below).
    (define (string-hash s)
      (let loop ((chars (string->list s)) (acc 0))
        (if (null? chars) acc (loop (cdr chars) (+ (* acc 31) (char->integer (car chars)))))))

    (define (categorical-color label)
      (hsl (inexact (fmod (* (string-hash label) 137.508) 360)) 65 82))))
