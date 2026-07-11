(require 'file)
(require 'string)

(define text-path "/tmp/crisp-example-text.txt")

(file:write text-path
  "the quick brown fox jumps over the lazy dog. the dog barks at the fox.")

(define words
  (filter (lambda (w) (> (string-length w) 0))
          (string:split (string:downcase (string:replace (file:read text-path) "." "")) " ")))

(define (bump-count! table word)
  (let ((entry (assoc word table)))
    (if entry
        (begin (set-cdr! entry (+ 1 (cdr entry))) table)
        (cons (cons word 1) table))))

(define frequencies (reduce bump-count! '() words))

(println "Word count: " (length words))
(println "Frequencies: " frequencies)

(define most-common
  (reduce (lambda (best entry) (if (> (cdr entry) (cdr best)) entry best))
          (car frequencies)
          (cdr frequencies)))
(println "Most common word: \"" (car most-common) "\" (" (cdr most-common) " times)")

(file:delete text-path)
