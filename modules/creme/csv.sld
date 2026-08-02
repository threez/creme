;; (creme csv): thin re-export frontend over (creme builtin csv)
(define-library (creme csv)
  (import (creme builtin csv))
  (export csv-read csv-read-headers csv-reader-open csv-reader-read!
          csv-reader? csv-write csv-write-headers csv-writer-open
          csv-writer-row! csv-writer?))
