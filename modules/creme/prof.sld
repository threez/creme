;; ===========================================================================
;; (creme prof): CPU sampling profiler — combined frontend
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme sxql)/(creme extra)/(creme bench) use), but unlike those, this one
;; has no definitions of its own — it just (import)s and re-exports the two
;; Crystal-registered libraries that actually implement profiling:
;;
;;   (creme prof-native)  src/scheme/modules/creme/prof_native.cr
;;     Wraps prof.cr's SIGPROF-based sampler: unwinds the raw native C
;;     stack, so its frame names are Crystal internals (e.g.
;;     "*Scheme::VM#call") — useful for finding hot spots in the
;;     *interpreter itself*. Not present on musl (Alpine); see that file's
;;     own header comment.
;;
;;   (creme prof-vm)  src/scheme/modules/creme/prof_vm.cr
;;     A cooperative sampler that periodically inspects the VM's own
;;     dispatch loop, so its labels are Scheme-level source text (e.g.
;;     "(fib (- n 1))") — useful for finding hot spots in the *guest
;;     program*. No native dependency; available everywhere prof-native
;;     isn't (e.g. musl).
;;
;; Kept as two separate libraries rather than one, since they're genuinely
;; independent mechanisms (one wall-clock/signal-driven, one
;; trampoline-step-driven) with different platform availability — a caller
;; that only wants one (e.g. bench/prof.scm profiling both together, or a
;; musl build that can only ever use prof-vm) can import just that one
;; directly instead of pulling in both through this frontend. `(import
;; (creme prof))` — this file — is the convenience for a caller that wants
;; both, e.g. any existing script written before the split.
;;
;; Importing this library on musl fails the same way importing
;; (creme prof-native) directly would (see that file's require guard in
;; src/scheme.cr) — there is no degraded "prof-vm only" fallback here; ask
;; for (creme prof-vm) directly if that's what you want on musl.
;; ===========================================================================

(define-library (creme prof)
  (export profile profile-report? profile-total-samples profile-top
          profile-write-folded profile-write-speedscope
          profile-scheme profile-scheme-report? profile-scheme-total-samples
          profile-scheme-top)
  (import (creme prof-native) (creme prof-vm)))
