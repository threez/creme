;; ===========================================================================
;; A (creme spec)-based port of the string-input-port half of
;; spec/scheme/r7rs/ch06_13_input_output_spec.cr's own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; open-input-string/read-char/peek-char/read-line/eof-object[?]/port?/
;; input-port?/output-port? used to be a deliberate cvm gap -- cvm's
;; Port was output-string-only, with no input-port variant at all (see
;; cvm/value.h's own header comment on the `kind`-tagged Port struct,
;; added alongside this file). File ports (open-input-file etc.) are a
;; separate, later phase -- not covered here.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/ports_spec.scm
;;   ./bin/creme --self-hosted spec/creme/ports_spec.scm
;;   ./cvm/cvm spec/creme/ports_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "string input ports"
  (it "eof-object/eof-object? identify the same distinguished value"
    (should-match-native? '((eof-object? (eof-object)))))

  (it "read-char/peek-char walk a string port, returning eof-object at the end"
    (should-match-native?
     '((let ((p (open-input-string "abc")))
         (list (read-char p) (read-char p) (peek-char p) (read-char p) (eof-object? (read-char p)))))))

  (it "read-char on an empty string port is eof-object immediately"
    (should-match-native? '((let ((p (open-input-string ""))) (eof-object? (read-char p))))))

  (it "read-line splits on newlines, returning eof-object once exhausted"
    (should-match-native?
     '((let ((p (open-input-string "line1\nline2")))
         (list (read-line p) (read-line p) (eof-object? (read-line p)))))))

  (it "port?/input-port?/output-port? distinguish input and output string ports"
    (should-match-native? '((port? (open-input-string "x"))))
    (should-match-native? '((input-port? (open-input-string "x"))))
    (should-match-native? '((output-port? (open-input-string "x"))))
    (should-match-native? '((input-port? (open-output-string))))
    (should-match-native? '((output-port? (open-output-string))))))

(spec-summary!)
