(define (matrix rows) (list->vector (map list->vector rows)))

(define (matrix-ref m i j) (vector-ref (vector-ref m i) j))
(define (matrix-rows m) (vector-length m))
(define (matrix-cols m) (vector-length (vector-ref m 0)))

(define (transpose m)
  (let ((rows (matrix-rows m)) (cols (matrix-cols m)))
    (list->vector
      (map (lambda (j)
             (list->vector (map (lambda (i) (matrix-ref m i j)) (range 0 rows))))
           (range 0 cols)))))

(define m (matrix (list (list 1 2 3) (list 4 5 6))))
(println "Matrix:    " m)
(println "Transpose: " (transpose m))
(println "Element (1,2): " (matrix-ref m 1 2))
