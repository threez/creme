;; ===========================================================================
;; A (creme spec)-based port of the remaining (scheme base) bytevector/
;; byte-port cases (base/bytevectors.cr) -- see modules/creme/spec.sld's
;; own header comment for the framework this uses, and compiler_spec.scm's
;; own header comment for the general should-match-native? approach.
;;
;; bytevector-copy/bytevector-copy!/bytevector-append/utf8->string/
;; string->utf8/open-input-bytevector/open-output-bytevector/
;; get-output-bytevector/read-u8/peek-u8/u8-ready?/write-u8/
;; read-bytevector[!]/write-bytevector/binary-port?/textual-port?/
;; input-port-open?/output-port-open?/call-with-port used to be a
;; deliberate icecreme gap -- only bytevector?/bytevector/make-bytevector/
;; bytevector-length/bytevector-u8-ref/bytevector-u8-set!/char-ready?
;; existed there. Now built on the same kind-tagged Port introduced for
;; string ports (see value.h's own comment on Port's `binary` field).
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/bytevectors_spec.scm
;;   ./bin/creme --self-hosted spec/creme/bytevectors_spec.scm
;;   ./icecreme/icecreme spec/creme/bytevectors_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "bytevectors and byte ports"
  (it "bytevector-copy/bytevector-copy!/bytevector-append"
    (should-match-native? '((bytevector-copy (bytevector 1 2 3 4) 1 3)))
    (should-match-native?
     '((define to (make-bytevector 5 0))
       (bytevector-copy! to 1 (bytevector 9 9 9))
       to))
    (should-match-native? '((bytevector-append (bytevector 1 2) (bytevector 3 4)))))

  (it "utf8->string/string->utf8 round-trip"
    (should-match-native? '((utf8->string (string->utf8 "hello"))))
    (should-match-native? '((string->utf8 "AB"))))

  (it "open-input-bytevector/read-u8/peek-u8 walk a bytevector port"
    (should-match-native?
     '((let ((p (open-input-bytevector (bytevector 65 66 67))))
         (list (read-u8 p) (peek-u8 p) (read-u8 p) (eof-object? (read-u8 p)))))))

  (it "open-output-bytevector/write-u8/get-output-bytevector round-trip"
    (should-match-native?
     '((let ((p (open-output-bytevector)))
         (write-u8 65 p)
         (write-u8 66 p)
         (get-output-bytevector p)))))

  (it "read-bytevector/read-bytevector! read a fixed count of bytes"
    (should-match-native?
     '((let ((p (open-input-bytevector (bytevector 1 2 3 4 5))))
         (read-bytevector 3 p))))
    (should-match-native?
     '((let ((p (open-input-bytevector (bytevector 1 2 3 4 5)))
             (dst (make-bytevector 5 0)))
         (read-bytevector! dst p)
         dst))))

  (it "write-bytevector writes a bytevector's bytes to a port"
    (should-match-native?
     '((let ((p (open-output-bytevector)))
         (write-bytevector (bytevector 1 2 3) p)
         (get-output-bytevector p)))))

  (it "binary-port?/textual-port? distinguish bytevector and string ports"
    (should-match-native? '((binary-port? (open-input-bytevector (bytevector 1)))))
    (should-match-native? '((textual-port? (open-input-bytevector (bytevector 1)))))
    (should-match-native? '((binary-port? (open-input-string "x"))))
    (should-match-native? '((textual-port? (open-input-string "x")))))

  (it "input-port-open?/output-port-open? reflect close-port"
    (should-match-native?
     '((let ((p (open-input-string "x")))
         (list (input-port-open? p) (begin (close-port p) (input-port-open? p)))))))

  (it "call-with-port applies proc to the port and closes it afterward"
    (should-match-native?
     '((let ((p (open-input-string "abc")))
         (list (call-with-port p (lambda (port) (read-char port))) (input-port-open? p))))))

  (it "u8-ready? mirrors char-ready?'s always-#t contract"
    (should-match-native? '((u8-ready? (open-input-bytevector (bytevector 1)))))))

(spec-summary!)
