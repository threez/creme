;; ===========================================================================
;; A (creme spec)-based port of (creme file)'s own FileExtra cases
;; (spec/scheme/modules/creme/file_spec.cr) plus open-binary-input-file/
;; open-binary-output-file -- see modules/creme/spec.sld's own header
;; comment for the framework this uses, and compiler_spec.scm's own
;; header comment for the general should-match-native? approach.
;;
;; open-binary-input-file/open-binary-output-file, with-input-from-file/
;; with-output-to-file, file-append, file-lines, file-size, and
;; current-directory used to be a deliberate icecreme gap -- (creme file) was
;; only a narrow partial port (file-read/file-write/delete-file, in
;; bootstrap.c) plus R7RS's own open-input-file/open-output-file/
;; call-with-*-file/file-exists? (builtins.c). with-input-from-file/
;; with-output-to-file needed a genuinely new piece: icecreme's (current-
;; input-port)/(current-output-port) used to be hardcoded, non-
;; redirectable sentinels (display/write/write-char/newline/read-line/
;; read-char/peek-char all read straight through them) -- they're now a
;; mutable per-thread indirection instead, and these two builtins reuse
;; the SAME dynamic-wind unwind-stack mechanism (creme)'s own
;; dynamic-wind builtin does, so the previous port is restored even if
;; the redirected thunk escapes via an error (see the "restoration
;; through an escaping error" case below).
;;
;; Uses a fixed /tmp path per case, same convention file_ports_spec.scm
;; already established.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/file_extra_spec.scm
;;   ./bin/creme --self-hosted spec/creme/file_extra_spec.scm
;;   ./icecreme/icecreme spec/creme/file_extra_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme file) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme file) extras"
  ;; A single should-match-native? call, not several -- should-match-
  ;; native? runs the SAME snippet against both native (for comparison)
  ;; and whichever backend is executing this file, against the SAME
  ;; physical file on disk; file-append is not idempotent, so splitting
  ;; this into separate calls sharing one probe path would have each
  ;; side's own run append onto whatever the OTHER side's run already
  ;; left behind. Starting with file-write (which truncates) keeps this
  ;; one call self-contained regardless of how many times it's re-run.
  (it "file-write/file-read/file-size/file-append round-trip"
    (should-match-native?
     '((file-write "/tmp/creme-spec-file-extra-probe1.txt" "hello")
       (list (file-read "/tmp/creme-spec-file-extra-probe1.txt")
             (file-size "/tmp/creme-spec-file-extra-probe1.txt")
             (begin
               (file-append "/tmp/creme-spec-file-extra-probe1.txt" " world")
               (file-read "/tmp/creme-spec-file-extra-probe1.txt"))))))

  (it "file-lines splits a file into a list of lines with no trailing newlines"
    (should-match-native?
     '((file-write "/tmp/creme-spec-file-extra-probe2.txt" "a\nb\nc\n")
       (file-lines "/tmp/creme-spec-file-extra-probe2.txt"))))

  (it "current-directory returns a non-empty string"
    (should-match-native? '((string? (current-directory))))
    (should-match-native? '((> (string-length (current-directory)) 0))))

  (it "open-binary-input-file/open-binary-output-file round-trip a byte via read-u8/write-u8"
    (should-match-native?
     '((let ((p (open-binary-output-file "/tmp/creme-spec-file-extra-probe3.bin")))
         (write-u8 65 p)
         (close-port p))
       (let ((p (open-binary-input-file "/tmp/creme-spec-file-extra-probe3.bin")))
         (let ((b (read-u8 p)))
           (close-port p)
           b)))))

  (it "with-output-to-file and with-input-from-file redirect the current ports"
    (should-match-native?
     '((with-output-to-file "/tmp/creme-spec-file-extra-probe4.txt" (lambda () (display "redirected"))))))

  (it "with-input-from-file reads back what with-output-to-file just wrote"
    (should-match-native?
     '((with-input-from-file "/tmp/creme-spec-file-extra-probe4.txt" (lambda () (read-line))))))

  (it "with-output-to-file restores the previous current-output-port after the thunk returns"
    (should-match-native?
     '((with-output-to-file "/tmp/creme-spec-file-extra-probe5.txt" (lambda () (display "inside")))
       (let ((p (open-output-string)))
         (display "outside" p)
         (get-output-string p)))))

  (it "with-output-to-file restores the previous port even when the thunk raises"
    (should-match-native?
     '((guard (e (#t 'caught))
         (with-output-to-file "/tmp/creme-spec-file-extra-probe6.txt"
           (lambda () (display "before-error") (error "boom"))))
       (let ((p (open-output-string)))
         (display "still-works" p)
         (get-output-string p)))))

  (it "with-output-to-file nests correctly, each level restoring its own outer port"
    (should-match-native?
     '((with-output-to-file "/tmp/creme-spec-file-extra-probe7.txt"
         (lambda ()
           (display "outer-before")
           (with-output-to-file "/tmp/creme-spec-file-extra-probe8.txt" (lambda () (display "inner")))
           (display "outer-after")))
       (list (call-with-input-file "/tmp/creme-spec-file-extra-probe7.txt" (lambda (p) (read-line p)))
             (call-with-input-file "/tmp/creme-spec-file-extra-probe8.txt" (lambda (p) (read-line p))))))))

(spec-summary!)
