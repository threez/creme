(require 'sql)
(require 'sxql)

(define conn (sql:open ":memory:"))

(define create-sql
  (first (sxql:yield (sxql:create-table 'sale
                        (list (sxql:column 'id "INTEGER" (sxql:primary-key) (sxql:autoincrement))
                              (sxql:column 'region "TEXT" (sxql:not-null))
                              (sxql:column 'amount "REAL" (sxql:not-null)))))))
(sql:execute conn create-sql)

(define (add-sale! region amount)
  (define built (sxql:yield (sxql:insert-into 'sale (sxql:set= 'region region 'amount amount))))
  (apply sql:execute conn (first built) (second built)))

(add-sale! "north" 120.0)
(add-sale! "north" 80.0)
(add-sale! "south" 45.0)
(add-sale! "south" 200.0)
(add-sale! "east" 30.0)

(define report-stmt
  (sxql:select (list 'region (sxql:as (sxql:raw "SUM(amount)") 'total))
    (sxql:from 'sale)
    (sxql:group-by 'region)
    (sxql:having (sxql:>= (sxql:raw "SUM(amount)") 50))
    (sxql:order-by (sxql:desc (sxql:raw "SUM(amount)")))))

(define built (sxql:yield report-stmt))
(println "Report SQL: " (first built))

(define rows (apply sql:query conn (first built) (second built)))
(for-each
  (lambda (row) (println (cdr (assoc "region" row)) ": " (cdr (assoc "total" row))))
  (vector->list rows))

(sql:close conn)
