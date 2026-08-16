;; ===========================================================================
;; A (creme spec)-based port of (creme radix)'s own cases
;; (spec/scheme/modules/creme/radix_spec.cr) -- see modules/creme/spec.sld's
;; own header comment for the framework this uses.
;;
;; (creme radix) is a general-purpose ":name"/"*name" prefix-matching
;; radix tree, factored out of what used to be icecreme/mux.c's own
;; private linear-scanned route table (see that file's own header
;; comment for the history) so (creme mux)'s own routing and this public
;; module share one implementation. Native wraps `luislavena/radix`
;; directly (src/creme/modules/creme/radix.cr); icecreme ports the same
;; algorithm from scratch (icecreme/radix.c) -- both are exercised here,
;; asserting concrete expected values rather than a should-match-native?
;; comparison, since this is deterministic and has no compiler-self-
;; hosting dimension to compare against.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/radix_spec.scm
;;   ./bin/creme --self-hosted spec/creme/radix_spec.scm
;;   ./icecreme/icecreme spec/creme/radix_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (creme radix) (creme spec))

(describe "(creme radix) construction/basics"
  (it "radix-tree?/radix-tree-count on a fresh tree"
    (should-be-true? (radix-tree? (radix-tree)))
    (should-be-false? (radix-tree? 5))
    (should-equal? (radix-tree-count (radix-tree)) 0))

  (it "radix-tree-set!/radix-tree-ref on a literal pattern"
    (let ((t (radix-tree)))
      (radix-tree-set! t "/hello" 'greeting)
      (should-equal? (radix-tree-ref t "/hello") 'greeting)
      (should-be-false? (radix-tree-ref t "/nope"))
      (should-equal? (radix-tree-count t) 1)))

  (it "re-adding the same pattern overwrites without growing the count"
    (let ((t (radix-tree)))
      (radix-tree-set! t "/hello" 'first)
      (radix-tree-set! t "/hello" 'second)
      (should-equal? (radix-tree-ref t "/hello") 'second)
      (should-equal? (radix-tree-count t) 1))))

(describe "(creme radix) :name capture"
  (it "radix-tree-match captures a single named param"
    (let ((t (radix-tree)))
      (radix-tree-set! t "/users/:id" 'user-by-id)
      (let ((result (radix-tree-match t "/users/42")))
        (should-equal? (car result) 'user-by-id)
        (should-equal? (cdr (assoc "id" (cdr result))) "42"))))

  (it "radix-tree-match captures multiple named params in one path"
    (let ((t (radix-tree)))
      (radix-tree-set! t "/orgs/:org/repos/:repo" 'repo-page)
      (let ((result (radix-tree-match t "/orgs/threez/repos/creme")))
        (should-equal? (car result) 'repo-page)
        (should-equal? (cdr (assoc "org" (cdr result))) "threez")
        (should-equal? (cdr (assoc "repo" (cdr result))) "creme")))))

(describe "(creme radix) *name catch-all capture"
  (it "radix-tree-match captures the entire remaining path"
    (let ((t (radix-tree)))
      (radix-tree-set! t "/files/*path" 'file-catchall)
      (let ((result (radix-tree-match t "/files/a/b/c.txt")))
        (should-equal? (car result) 'file-catchall)
        (should-equal? (cdr (assoc "path" (cdr result))) "a/b/c.txt")))))

(describe "(creme radix) precedence"
  (it "a static route wins over an overlapping :name route regardless of registration order"
    (let ((t (radix-tree)))
      (radix-tree-set! t "/users/:id" 'user-by-id)
      (radix-tree-set! t "/users/me" 'current-user)
      (should-equal? (radix-tree-ref t "/users/me") 'current-user)
      (should-equal? (radix-tree-ref t "/users/42") 'user-by-id)))

  (it "a :name route wins over an overlapping *name route regardless of registration order"
    (let ((t (radix-tree)))
      (radix-tree-set! t "/files/*rest" 'file-catchall)
      (radix-tree-set! t "/files/:name" 'single-file)
      (should-equal? (radix-tree-ref t "/files/report.pdf") 'single-file)
      (should-equal? (radix-tree-ref t "/files/a/b/c.txt") 'file-catchall))))

(describe "(creme radix) unbounded depth/length"
  (it "matches a path deeper than the old 8-segment cap"
    (let ((t (radix-tree))
          (deep "/a/b/c/d/e/f/g/h/i/j/k/l"))
      (radix-tree-set! t deep 'deep-route)
      (should-equal? (radix-tree-ref t deep) 'deep-route)))

  (it "matches a segment longer than the old 64-byte cap"
    (let* ((t (radix-tree))
           (long-segment (make-string 200 #\a))
           (pattern (string-append "/" long-segment)))
      (radix-tree-set! t pattern 'long-route)
      (should-equal? (radix-tree-ref t pattern) 'long-route))))

(describe "(creme radix) no match"
  (it "radix-tree-ref/radix-tree-match both return #f when nothing matches"
    (let ((t (radix-tree)))
      (radix-tree-set! t "/hello" 'greeting)
      (should-be-false? (radix-tree-ref t "/goodbye"))
      (should-be-false? (radix-tree-match t "/goodbye")))))

(spec-summary!)
