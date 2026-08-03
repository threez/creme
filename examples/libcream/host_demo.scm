;; A plain Scheme script — nothing marks host-greet/host-version/host-sum/
;; host-scale-vector/host-word-lengths/host-stats as coming from the host
;; program below; they're just free identifiers, resolved by name against
;; whatever the C host registered before running this file. See
;; host_demo.c and icecreme/README.md's "Embedding" section.
(import (scheme base) (scheme write) (creme hash-table))

(display (host-greet "world"))
(newline)
(display host-version)
(newline)

;; list -> integer
(display (host-sum '(1 2 3 4 5)))
(newline)

;; vector + number -> vector
(display (host-scale-vector #(1 2 3) 2.5))
(newline)

;; list of strings -> alist, fed straight into a real Scheme hash table --
;; host-word-lengths itself knows nothing about hash tables at all, it
;; just returns plain (string . length) pairs.
(define lengths (make-hash-table))
(for-each (lambda (pair) (hash-table-set! lengths (car pair) (cdr pair)))
          (host-word-lengths '("scheme" "is" "wonderful")))
(display (hash-table-ref lengths "wonderful" #f))
(newline)

;; variadic numbers -> vector
(display (host-stats 3 1 4 1 5 9 2 6))
(newline)
