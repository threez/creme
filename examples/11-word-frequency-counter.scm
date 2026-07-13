(import (scheme base) (scheme write) (creme file) (creme string))

(define (filter-list pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (filter-list pred (cdr lst))))
        (else (filter-list pred (cdr lst)))))
(define (reduce-list f init lst)
  (if (null? lst) init (reduce-list f (f init (car lst)) (cdr lst))))

(define text-path "/tmp/creme-example-text.txt")

(file-write text-path
  "the quick brown fox jumps over the lazy dog. the dog barks at the fox.")

(define words
  (filter-list (lambda (w) (> (string-length w) 0))
          (string-split (string-downcase (string-replace (file-read text-path) "." "")) " ")))

(define (bump-count! table word)
  (let ((entry (assoc word table)))
    (if entry
        (begin (set-cdr! entry (+ 1 (cdr entry))) table)
        (cons (cons word 1) table))))

(define frequencies (reduce-list bump-count! '() words))

(display "Word count: ") (display (length words)) (newline)
(display "Frequencies: ") (display frequencies) (newline)

(define most-common
  (reduce-list (lambda (best entry) (if (> (cdr entry) (cdr best)) entry best))
          (car frequencies)
          (cdr frequencies)))
(display "Most common word: \"") (display (car most-common)) (display "\" (") (display (cdr most-common)) (display " times)") (newline)

(delete-file text-path)
