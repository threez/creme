;; The "report" script — a user-editable policy layer over the host's own
;; data (host-orders) and live state (host-price-lookup queries the
;; host's own price catalog). Nothing here marks host-welcome/host-log/
;; host-price-lookup/host-store-name/host-orders as coming from the host
;; program below; they're just free identifiers, resolved by name against
;; whatever the C host registered before running this file. See
;; host_demo.c and icecreme/README.md's "Embedding" section.
(import (scheme base) (scheme write) (creme hash-table))

;; Prices/totals are integer cents (see host_demo.c's own comment on why)
;; -- this formats them back into a "$X.YZ" string for display.
(define (cents->string c)
  (let ((r (remainder c 100)))
    (string-append "$" (number->string (quotient c 100)) "."
                    (if (< r 10) (string-append "0" (number->string r)) (number->string r)))))

(display (host-welcome "Alice"))
(newline)
(host-log "generating receipt")

;; Tally quantities per item into the SCRIPT's own hash table — distinct
;; from the host's own price catalog (g_catalog, host_demo.c), a real
;; Scheme-side use of a real hash table, not a synthetic demo.
(define tallies (make-hash-table))
(for-each (lambda (order)
            (let* ((item (car order))
                   (qty (cdr order))
                   (prev (hash-table-ref tallies item 0)))
              (hash-table-set! tallies item (+ prev qty))))
          host-orders)

(define total 0)
(for-each (lambda (item)
            (let* ((qty (hash-table-ref tallies item 0))
                   (price (host-price-lookup item))
                   (line-total (* qty price)))
              (set! total (+ total line-total))
              (display item) (display ": ") (display qty)
              (display " x ") (display (cents->string price))
              (display " = ") (display (cents->string line-total))
              (newline)))
          (hash-table-keys tallies))

(display "total: ") (display (cents->string total))
(newline)
(display "thank you for shopping at ") (display host-store-name)
(newline)
(host-log "receipt complete")
