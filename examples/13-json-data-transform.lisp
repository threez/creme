(require 'json)

(define people-json "[{\"name\":\"Ada\",\"age\":36,\"active\":true},{\"name\":\"Grace\",\"age\":85,\"active\":false},{\"name\":\"Alan\",\"age\":41,\"active\":true}]")

(define people (vector->list (json:parse people-json)))

(define (field person key) (cdr (assoc key person)))
(define (summarize p) (list (cons "name" (field p "name")) (cons "age" (field p "age"))))

(define active-people (filter (lambda (p) (field p "active")) people))

(println "All names: " (map (lambda (p) (field p "name")) people))
(println "Active count: " (length active-people))
(println "Active summary JSON: " (json:stringify (list->vector (map summarize active-people))))
