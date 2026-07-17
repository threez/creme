;; ===========================================================================
;; (creme match): minimal record-shape pattern matching
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme extra)/(creme pipe) use) — the macro itself is pure syntax-rules;
;; the one primitive it needs, record-fields (generic positional reflection
;; over any define-record-type instance — see (creme introspection)'s doc
;; comment), is re-exported here so `(import (creme match))` alone is
;; enough. This project's define-syntax/syntax-rules is unhygienic, so
;; match's own expansion needs record-fields already in scope wherever
;; match is USED, not just wherever match.sld itself was compiled.
;;
;; (match expr ((pred? field ...) body ...) ... [(else body ...)])
;; evaluates expr once, then tries each clause's own predicate — written
;; out by the caller exactly as define-record-type generated it (ping?,
;; pong?, ...) — in order; the first that succeeds binds field ...
;; POSITIONALLY off (record-fields v) and runs its body. This is
;; deliberately NOT `((ping field ...) ...)` deriving a `ping?` predicate
;; from a bare `ping` tag: unhygienic syntax-rules has no identifier-
;; pasting, so there's no way to build the symbol `ping?` out of the
;; symbol `ping` — spelling out the real predicate name sidesteps that
;; entirely, at the cost of one extra `?` per clause. No clause matching
;; with no (else ...) present is an error.
;;
;; Example:
;;   (define-record-type <ping> (make-ping from) ping? (from ping-from))
;;   (match msg
;;     ((ping? from) (display from))
;;     (else (display "unknown")))
;; ===========================================================================

(define-library (creme match)
  (export match record-fields)
  (import (scheme base) (creme introspection))
  (begin
    (define-syntax match
      (syntax-rules (else)
        ((_ v (else body ...))
         (begin body ...))
        ((_ v ((pred? field ...) body ...) rest ...)
         (let ((%match-v v))
           (if (pred? %match-v)
               (apply (lambda (field ...) body ...) (record-fields %match-v))
               (match %match-v rest ...))))
        ((_ v)
         (error "match: no clause matched" v))))))
