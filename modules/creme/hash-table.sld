;; (creme hash-table): thin re-export frontend over (creme builtin hash-table)
(define-library (creme hash-table)
  (import (creme builtin hash-table))
  (export hash-table->alist hash-table-contains? hash-table-delete!
          hash-table-keys hash-table-ref hash-table-set! hash-table-values
          hash-table? make-hash-table eq-hash))
