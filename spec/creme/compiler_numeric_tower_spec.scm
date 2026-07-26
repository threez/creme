;; ===========================================================================
;; The one case split out of compiler_spec.scm's own "numeric and
;; bytevector literals" section: rationals and complex numbers. See
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; Split into its own file specifically because cvm (the standalone C11
;; VM, see cvm/README.md) has NO rational/bignum/complex number support
;; at all -- a deep, pre-existing, deliberate scope limitation of that
;; "prototype" VM (cvm/value.h's own header comment: "doubles only (no
;; bignum/rational/complex...)"), not something this project's spec/
;; creme test suite is trying to fix. Since compile-program compiles a
;; whole script as ONE chunk upfront, a single unparseable/unrepresentable
;; literal ANYWHERE in a file aborts compiling the ENTIRE file under cvm
;; -- keeping this case inside compiler_spec.scm would have blocked all
;; 117 OTHER, unrelated cases in that file from ever running under `cvm`.
;;
;; Run with:
;;   ./bin/creme spec/creme/compiler_numeric_tower_spec.scm
;;   ./bin/creme --self-hosted spec/creme/compiler_numeric_tower_spec.scm
;; (not `cvm/cvm` -- see this file's own header comment above for why.)
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
