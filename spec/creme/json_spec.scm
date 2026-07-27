;; ===========================================================================
;; A (creme spec)-based port of (creme json)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme json) used to be entirely absent from cvm. Crystal's own
;; `require "json"` is standard library, not an external shard (see
;; shard.yml) -- backed here (cvm/json.c) by a small hand-rolled
;; recursive-descent JSON parser/writer, since cvm has no JSON support to
;; reuse from anywhere else. Matches native's own conventions exactly: a
;; JSON array decodes to a vector, an object decodes to an alist of
;; (string . value) pairs usable with assoc/cdr/car, and an empty object
;; conflates with JSON null (both decode to '() -- an accepted native
;; tradeoff, not a cvm-specific cut: an alist built from zero pairs IS
;; '(), not a special case).
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/json_spec.scm
;;   ./bin/creme --self-hosted spec/creme/json_spec.scm
;;   ./cvm/cvm spec/creme/json_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme json) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme json)"
  (it "parses arrays into vectors"
    (should-match-native? '((json-read "[1, 2.5, \"a\", true, null]"))))

  (it "parses objects into an alist accessible via assoc/cdr"
    (should-match-native? '((cdr (assoc "a" (json-read "{\"a\":1}"))))))

  (it "returns #f from assoc for a missing key"
    (should-match-native? '((assoc "z" (json-read "{\"a\":1}")))))

  (it "round-trips stringify for objects and arrays"
    (should-match-native? '((json-write (json-read "{\"a\":1,\"b\":[1,2]}"))))
    (should-match-native? '((json-write (json-read "[1,2,3]")))))

  (it "stringifies a plain list as a JSON array"
    (should-match-native? '((json-write (list 1 2 3)))))

  (it "conflates an empty object with null (accepted tradeoff of using plain NIL for both)"
    (should-match-native? '((json-read "{}")))
    (should-match-native? '((json-write (json-read "{}")))))

  (it "raises on malformed json"
    (should-raise? (lambda () (json-read "{not json"))))

  (it "stringifies a char as a 1-character string"
    (should-match-native? '((json-write #\a))))

  (it "mutates an object entry in place with set-cdr!"
    (should-match-native?
     '((let ((o (json-read "{\"x\":1}")))
         (set-cdr! (assoc "x" o) 2)
         (cdr (assoc "x" o)))))))

(spec-summary!)
