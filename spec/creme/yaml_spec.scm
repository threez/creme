;; ===========================================================================
;; A (creme spec)-based port of (creme yaml)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme yaml) used to be entirely absent from both backends. Native's
;; own (creme yaml) (src/creme/modules/creme/yaml.cr) leans on Crystal's
;; stdlib `YAML`; icecreme's (icecreme/yaml.c) wraps libyaml directly -- both end up
;; backed by the same underlying C library either way (see yaml.c's own
;; header comment for the full design and its one deliberate, narrow
;; native divergence around non-string-typed mapping keys).
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/yaml_spec.scm
;;   ./bin/creme --self-hosted spec/creme/yaml_spec.scm
;;   ./icecreme/icecreme spec/creme/yaml_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme yaml) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme yaml)"
  (it "yaml-read reads a bare scalar"
    (should-match-native? '((yaml-read "42"))))

  (it "yaml-read reads a sequence into a vector"
    (should-match-native? '((yaml-read "- 1\n- 2\n- 3\n"))))

  (it "yaml-read reads a mapping into an alist"
    (should-match-native? '((yaml-read "a: 1\nb: two\nc: true\n"))))

  (it "yaml-read conflates an empty mapping with null"
    (should-match-native? '((list (yaml-read "{}") (yaml-read "null")))))

  (it "yaml-read resolves core-schema plain scalars"
    (should-match-native? '((yaml-read "a: yes\nb: no\nc: on\nd: off\n")))
    (should-match-native? '((yaml-read "a: 0x1F\nb: 0o17\nc: 010\nd: 1_000\n"))))

  (it "yaml-read keeps a quoted scalar a string even if it looks like a bool/int"
    (should-match-native? '((yaml-read "a: \"true\"\nb: '123'\n"))))

  (it "yaml-read raises on malformed yaml"
    (should-raise? (lambda () (yaml-read "a: [1,2"))))

  (it "yaml-write/yaml-read round-trip a vector"
    (should-match-native? '((yaml-read (yaml-write (vector 1 2 "three"))))))

  (it "yaml-write/yaml-read round-trip a (string . value) alist as a mapping"
    (should-match-native? '((yaml-read (yaml-write (list (cons "a" 1) (cons "b" (vector 1 2))))))))

  (it "yaml-write writes a plain (non-alist) proper list as a sequence"
    (should-match-native? '((yaml-write (list 1 2 3)))))

  (it "yaml-write raises writing an improper list"
    (should-raise? (lambda () (yaml-write (cons 1 2))))))

(spec-summary!)
