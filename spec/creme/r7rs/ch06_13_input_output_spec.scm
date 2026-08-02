;; ===========================================================================
;; A (creme spec)-based port of spec/scheme/r7rs/ch06_13_input_output_spec.cr's
;; own cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses, and spec/creme/ports_spec.scm/file_ports_spec.scm's
;; own header comments for this project's existing string-port/file-port
;; testing precedent (this file follows the same idioms: open-input-string/
;; open-output-string/get-output-string used directly, no string-embedding-
;; and-sub-eval needed since this file already runs in a real Scheme
;; runtime).
;;
;; This file used to document five genuine cvm gaps: current-output-port
;; being a plain mutable per-thread C global rather than a real
;; make-parameter-backed parameter object (so `parameterize` couldn't
;; target it -- "parameterize: expected a parameter object"), plus
;; write-shared/write-simple/read-string/flush-output-port each having no
;; cvm_register_builtin entry at all. All five are now fixed:
;; current-output-port/current-input-port are genuine T_PARAMETER values
;; (cvm/builtins.c's cvm_init_current_ports, cvm/vm.h's own VM-struct doc
;; comment), and write-shared genuinely tracks shared/circular structure
;; and emits real #n=/#n# datum labels (`write_value_shared`), not just
;; an alias to `write`. Every case in this file runs unconditionally now.
;;
;; The file-backed-port case uses a fixed /tmp path (never cleaned up),
;; matching file_ports_spec.scm's own house style, rather than the Crystal
;; original's freshly Dir.mkdir_p'd temp directory.
;;
;; Run with (all cases pass, 0 pending, under all three):
;;   ./bin/creme spec/creme/r7rs/ch06_13_input_output_spec.scm
;;   ./bin/creme --self-hosted spec/creme/r7rs/ch06_13_input_output_spec.scm
;;   ./cvm/cvm spec/creme/r7rs/ch06_13_input_output_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (scheme read) (scheme file) (creme spec))

(describe "R7RS §6.13.1 Ports"
  (it "open-input-string/open-output-string/get-output-string provide textual string ports"
    (let ((op (open-output-string)))
      (write "hello" op)
      (should-equal? (get-output-string op) "\"hello\"")))

  (it "port?/input-port?/output-port?/textual-port? classify string ports correctly"
    (let ((p (open-input-string "abc")))
      (should-equal? (list (port? p) (output-port? p) (input-port? p) (textual-port? p))
                     (list #t #f #t #t))))

  (it "current-output-port can be parameterize'd to redirect display/write output"
    (should-equal?
     (parameterize ((current-output-port (open-output-string)))
       (display "piece")
       (display " by piece ")
       (display "by piece.")
       (newline)
       (get-output-string (current-output-port)))
     "piece by piece by piece.\n"))

  (it "open-input-bytevector/open-output-bytevector/get-output-bytevector provide binary ports"
    (let ((ip (open-input-bytevector (bytevector 65 66 67))))
      (should-equal? (read-u8 ip) 65)))

  (it "(scheme file) provides file-backed ports/predicates under R7RS's own standard library name"
    (let ((path "/tmp/creme-r7rs-ch06-13-spec-probe1.txt"))
      (let ((op (open-output-file path)))
        (write-string "hi" op)
        (close-port op))
      (should-equal? (call-with-input-file path (lambda (p) (read-line p))) "hi"))))

(describe "R7RS §6.13.2 Input"
  (it "read parses one datum's external representation from a textual input port"
    (let ((p (open-input-string "(a b c)")))
      (should-equal? (read p) (list 'a 'b 'c))))

  (it "read returns an eof-object when the port is exhausted"
    (let ((p (open-input-string "(a b c)")))
      (read p)
      (should-be-true? (eof-object? (read p)))))

  (it "read-line reads up to (not including) the next end-of-line, updating the port"
    (should-equal? (read-line (open-input-string "hello\nworld")) "hello"))

  (it "peek-char returns the next character without consuming it"
    (let ((p (open-input-string "world")))
      (should-equal? (list (peek-char p) (read-char p)) (list #\w #\w))))

  (it "read-char consumes and returns the next character, updating the port to point past it"
    (should-equal? (read-char (open-input-string "abc")) #\a))

  (it "read-string reads up to k characters, or as many as available before eof"
    (let ((p (open-input-string "hello")))
      (should-equal? (read-string 3 p) "hel")))

  (it "read-u8/peek-u8/u8-ready? operate on binary ports"
    (let ((ip (open-input-bytevector (bytevector 65 66 67))))
      (should-equal? (list (read-u8 ip) (u8-ready? ip)) (list 65 #t)))))

(describe "R7RS §6.13.3 Output"
  (it "write produces a machine-readable representation, quoting strings and escaping specials"
    (let ((op (open-output-string)))
      (write "hi" op)
      (should-equal? (get-output-string op) "\"hi\"")))

  (it "display produces a human-readable representation, without quoting strings"
    (let ((op (open-output-string)))
      (display "hi" op)
      (should-equal? (get-output-string op) "hi")))

  (it "write-shared is the same as write, but represents shared/circular structure using datum labels"
    (let ((op (open-output-string))
          (x (list 1 2)))
      (set-cdr! (cdr x) x)
      (write-shared x op)
      (should-equal? (get-output-string op) "#0=(1 2 . #0#)")))

  (it "write-simple is the same as write, never emitting datum labels"
    (let ((op (open-output-string)))
      (write-simple "hi" op)
      (should-equal? (get-output-string op) "\"hi\"")))

  (it "newline writes an end-of-line to the given textual output port"
    (let ((op (open-output-string)))
      (display "a" op)
      (newline op)
      (should-equal? (get-output-string op) "a\n")))

  (it "write-char writes a single character (not its external representation) to the port"
    (let ((op (open-output-string)))
      (write-char #\a op)
      (should-equal? (get-output-string op) "a")))

  (it "write-u8 writes a single byte to a binary output port"
    (let ((op (open-output-bytevector)))
      (write-u8 65 op)
      (should-equal? (bytevector-u8-ref (get-output-bytevector op) 0) 65)))

  (it "flush-output-port flushes any buffered output, returning an unspecified value"
    (flush-output-port)))

(spec-summary!)
