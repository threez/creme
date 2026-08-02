;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/appendix_b_feature_
;; identifiers_spec.cr's own cases -- see modules/creme/spec.sld's own
;; header comment for the framework this uses. The original Crystal spec
;; evaluated each case's Scheme source via a fresh sub-interpreter (run(src)/
;; w(src)) since it was testing a Scheme interpreter from OUTSIDE, as
;; Crystal code; here, running directly as Scheme, each case's forms are
;; written and asserted directly via should-equal?/should-be-true? instead
;; of comparing write_string'd output against a literal string.
;;
;; The feature-identifier list itself ((features), Interpreter#features in
;; src/scheme/eval/interpreter.cr) is `(r7rs creme creme.cr)`, matching the
;; Crystal original exactly -- verified directly rather than assumed. Same
;; list under `--self-hosted` (modules/creme/compiler/compiler.sld's own
;; cond-expand-known-features).
;;
;; cond-expand's `(library (name ...))` requirement form USED to be a
;; genuine divergence between backends: the self-hosted compiler
;; (modules/creme/compiler/compiler.sld, used by both `--self-hosted` and
;; `cvm/cvm`) used to treat EVERY `(library ...)` requirement as
;; unconditionally unsatisfied, unlike native Crystal's own cond-expand
;; (src/scheme/eval/interpreter.cr), which really does consult the
;; interpreter's own library registry. Fixed: `feature-satisfied?`'s own
;; `library` case now reuses the same `library-export-alist` check
;; `ensure-library-loaded!`/`import-set-resolved-bindings` already rely
;; on elsewhere (a real .sld file, or a native family introspection,
;; recognizing the name) -- so `(library (scheme base))` is genuinely
;; satisfied and `(library (scheme fictional-not-real))` genuinely isn't,
;; under all three backends now.
;;
;; `(features)` itself (the procedure, distinct from cond-expand's own
;; compile-time feature-identifier check above) USED to be entirely
;; unbound under cvm specifically (`--self-hosted` never showed this,
;; since it still runs inside the ordinary Crystal process, so an
;; ordinary procedure call like this one still resolved to Crystal's own
;; native builtin regardless of the self-hosted compiler's own, separate
;; cond-expand-time check) -- fixed (cvm/builtins.c's own `bi_features`,
;; matching native's exact `(r7rs creme creme.cr)` list).
;;
;; Run with (all cases pass, 0 pending, under all three):
;;   ./bin/creme spec/creme/r7rs/appendix_b_feature_identifiers_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/appendix_b_feature_identifiers_spec.scm
;;   ./cvm/cvm spec/creme/r7rs/appendix_b_feature_identifiers_spec.scm
;; ===========================================================================

(import (scheme base) (creme spec))

(describe "Appendix B Standard Feature Identifiers"
  (it "features returns the list of feature identifiers this implementation provides"
    (should-equal? (features) '(r7rs creme creme.cr)))

  (it "the r7rs feature identifier is provided, since this implementation satisfies R7RS's own report"
    (should-equal? (cond-expand (r7rs 'yes) (else 'no)) 'yes))

  (it "cond-expand's else clause is selected for a feature identifier this implementation does not claim"
    (should-equal? (cond-expand (exact-closed 'yes) (else 'no)) 'no)
    (should-equal? (cond-expand (posix 'yes) (else 'no)) 'no)
    (should-equal? (cond-expand (full-unicode 'yes) (else 'no)) 'no))

  (it "cond-expand's (library (name ...)) requirement form checks whether a library is importable"
    (should-equal? (cond-expand ((library (scheme base)) 'yes) (else 'no)) 'yes)
    (should-equal? (cond-expand ((library (scheme fictional-not-real)) 'yes) (else 'no)) 'no))

  (it "cond-expand's and/or/not feature-requirement combinators compose correctly against features/libraries"
    (should-equal? (cond-expand ((and r7rs (library (scheme base))) 'yes) (else 'no)) 'yes)
    (should-equal? (cond-expand ((or exact-closed r7rs) 'yes) (else 'no)) 'yes)
    (should-equal? (cond-expand ((not exact-closed) 'yes) (else 'no)) 'yes)))

(spec-summary!)
