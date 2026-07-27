;; ===========================================================================
;; A (creme spec)-based port of the file-port half of
;; spec/scheme/r7rs/ch06_13_input_output_spec.cr's own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; open-input-file/open-output-file/call-with-input-file/
;; call-with-output-file/file-exists? used to be a deliberate cvm gap --
;; only string ports existed there (see ports_spec.scm) until PORT_KIND_
;; INPUT_FILE/PORT_KIND_OUTPUT_FILE were added on top of that same
;; kind-tagged Port (cvm/builtins.c's own "file ports" section).
;;
;; Uses a fixed /tmp path rather than a freshly-generated temp directory
;; (unlike ch06_13_input_output_spec.cr's own Dir.mkdir_p/FileUtils.rm_rf) --
;; kept deliberately simple for a spec/creme file, since nothing here runs
;; concurrently with itself. No delete-file cleanup: delete-file isn't
;; part of this pass's cvm scope (out of scope per the project's own
;; planning doc), so using it here would fail under cvm/cvm specifically,
;; defeating the point of a should-match-native? case -- the probe files
;; are just left behind in /tmp.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/file_ports_spec.scm
;;   ./bin/creme --self-hosted spec/creme/file_ports_spec.scm
;;   ./cvm/cvm spec/creme/file_ports_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (scheme file) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "file ports"
  (it "open-output-file/write-string/close-port/call-with-input-file round-trip a line"
    (should-match-native?
     '((define op (open-output-file "/tmp/creme-spec-file-ports-probe1.txt"))
       (write-string "hi" op)
       (close-port op)
       (call-with-input-file "/tmp/creme-spec-file-ports-probe1.txt" (lambda (p) (read-line p))))))

  (it "file-exists? reflects a file that was just written, and not one that was never created"
    (should-match-native? '((file-exists? "/tmp/creme-spec-file-ports-probe1.txt")))
    (should-match-native? '((file-exists? "/tmp/creme-spec-file-ports-probe-never-created.txt"))))

  (it "call-with-output-file/call-with-input-file round-trip multiple lines, ending in eof-object"
    (should-match-native?
     '((call-with-output-file "/tmp/creme-spec-file-ports-probe2.txt" (lambda (p) (write-string "abc\ndef" p)))
       (call-with-input-file "/tmp/creme-spec-file-ports-probe2.txt"
         (lambda (p) (list (read-line p) (read-line p) (eof-object? (read-line p))))))))

  (it "port?/input-port?/output-port? classify file ports correctly"
    (should-match-native? '((port? (open-output-file "/tmp/creme-spec-file-ports-probe3.txt"))))
    (should-match-native? '((output-port? (open-output-file "/tmp/creme-spec-file-ports-probe4.txt"))))
    (should-match-native?
     '((call-with-output-file "/tmp/creme-spec-file-ports-probe5.txt" (lambda (p) (write-string "x" p)))
       (input-port? (open-input-file "/tmp/creme-spec-file-ports-probe5.txt"))))))

(spec-summary!)
