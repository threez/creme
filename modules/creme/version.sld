;; ===========================================================================
;; (creme version): the shared one-line version banner.
;;
;; Formats the native `runtime` alist ((creme introspection)) into the single
;; banner string every front-end shows -- so `creme --version` (icecreme's
;; driver) and the REPL startup banner ((creme repl)) share one format instead
;; of hand-building the same string twice. Imports (creme introspection) (the
;; .sld re-export, NOT (creme builtin introspection) directly) so `runtime` is a
;; resolvable visible name here rather than a free native ref.
;; ===========================================================================

(define-library (creme version)
  (export runtime-version-string)
  (import (scheme base) (creme introspection))
  (begin
    ;; "creme <version> (<vm>/<compiler>, <os>/<arch>)"
    (define (runtime-version-string)
      (let* ((rt (runtime)) (get (lambda (k) (cdr (assq k rt)))))
        (string-append "creme " (get 'version) " (" (get 'vm) "/" (get 'compiler)
                       ", " (get 'os) "/" (get 'arch) ")")))))
