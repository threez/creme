;; ===========================================================================
;; (scheme process-context): thin re-export frontend over
;; (creme builtin process-context)
;;
;; The native family already merges exactly R7RS's own (scheme
;; process-context) surface — command-line (from ProcessLibrary),
;; get-environment-variable/get-environment-variables (from EnvVars), and
;; exit/emergency-exit (owned directly) — see
;; src/scheme/modules/scheme/process_context.cr. No subset/superset split
;; needed here: the native family's export set IS the R7RS set, exactly.
;; ===========================================================================

(define-library (scheme process-context)
  (import (creme builtin process-context))
  (export command-line emergency-exit exit
          get-environment-variable get-environment-variables))
