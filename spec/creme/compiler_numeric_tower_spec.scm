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
    (should-match-native? '((quote (1/2 -3/4 1+2i #u8(1 2 3))))))

  ;; floor/ceiling/round/truncate of a rational used to be a deliberate
  ;; cvm cut (see cvm/builtins.c's own comment at the top of its
  ;; numeric-predicates section) -- now implemented, so verified here the
  ;; same should-match-native? way as every other numeric-tower case in
  ;; this file. (abs/zero?/positive?/negative? of a complex value stay
  ;; unimplemented in cvm, matching the native interpreter's own
  ;; behavior -- not a gap, see that same comment.)
  (it "floor/ceiling/round/truncate of positive and negative rationals"
    (should-match-native? '((floor 7/2)))
    (should-match-native? '((floor -7/2)))
    (should-match-native? '((ceiling 7/2)))
    (should-match-native? '((ceiling -7/2)))
    (should-match-native? '((truncate 7/2)))
    (should-match-native? '((truncate -7/2)))
    (should-match-native? '((round 7/2)))   ; halfway, even winner -> 4
    (should-match-native? '((round -7/2)))  ; halfway, even winner -> -4
    (should-match-native? '((round 5/2)))   ; halfway, even winner -> 2
    (should-match-native? '((round 8/3)))))  ; not halfway -> 3

(spec-summary!)
