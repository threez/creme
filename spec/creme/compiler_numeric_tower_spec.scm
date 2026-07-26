;; ===========================================================================
;; The one case split out of compiler_spec.scm's own "numeric and
;; bytevector literals" section: rationals and complex numbers. See
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; Originally split into its own file because cvm (the standalone C11 VM,
;; see cvm/README.md) had NO rational/complex number support at all, and
;; compile-program compiles a whole script as ONE chunk upfront -- a
;; single unparseable/unrepresentable literal ANYWHERE in a file used to
;; abort compiling the ENTIRE file under cvm, so keeping this case inside
;; compiler_spec.scm would have blocked all 117 OTHER, unrelated cases in
;; that file from ever running there. cvm now has real T_RATIONAL (GMP-
;; backed, arbitrary-precision) and T_COMPLEX support (cvm/value.h), so
;; this case runs (and passes) under `cvm/cvm` too -- kept in its own file
;; regardless, both for git-blame/history clarity and because a future,
;; still-unsupported numeric literal would have the exact same whole-
;; file-aborts-under-cvm failure mode this file was split out to avoid.
;;
;; Run with (all three pass):
;;   ./bin/creme spec/creme/compiler_numeric_tower_spec.scm
;;   ./bin/creme --self-hosted spec/creme/compiler_numeric_tower_spec.scm
;;   ./cvm/cvm spec/creme/compiler_numeric_tower_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "numeric and bytevector literals requiring rational/complex support"
  (it "rationals, negative rationals, a complex, and a bytevector literal"
    (should-match-native? '((quote (1/2 -3/4 1+2i #u8(1 2 3)))))))

(spec-summary!)
