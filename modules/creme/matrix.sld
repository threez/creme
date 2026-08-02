;; ===========================================================================
;; (creme matrix): basic dense-matrix linear algebra, matching Ruby's
;; bundled Matrix/Vector library (a bundled gem, not core stdlib -- the
;; closest stdlib-adjacent analog, per this project's own creme-vs-ruby
;; comparison doc)
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme pstore)/(creme tempfile) use) since every export here is
;; expressible in plain R7RS vector arithmetic, with no opaque foreign
;; object or third-party Crystal library of its own involved.
;;
;; A <matrix> is a fixed-size 2D numeric array: a vector of row-vectors.
;; Every operation below builds a NEW matrix rather than mutating its
;; argument(s), except matrix-set! itself (an explicit in-place element
;; update, same as vector-set!'s own convention).
;;
;;   (make-matrix rows)          -> rows: a list of rows, each row a
;;                                  list OR vector of numbers, all the
;;                                  same length
;;   (matrix row ...)            -> variadic sugar for make-matrix,
;;                                  e.g. (matrix '(1 2) '(3 4))
;;   (list->matrix rows)         -> an alias of make-matrix
;;   (matrix? x)
;;   (matrix-rows m) / (matrix-cols m)  -> row/column counts
;;   (matrix-ref m i j)          -> the element at row i, column j
;;                                  (0-indexed)
;;   (matrix-set! m i j v)       -> sets that element, in place
;;   (matrix-row m i)            -> row i as a fresh vector (a copy, not
;;                                  a view into m)
;;   (matrix-column m j)         -> column j as a fresh vector
;;   (matrix-identity n)         -> the n x n identity matrix
;;   (matrix-zero rows cols)     -> a rows x cols matrix of all 0
;;   (matrix-add a b) / (matrix-sub a b)  -> elementwise sum/difference
;;                                  (a and b must have identical
;;                                  dimensions, or this raises)
;;   (matrix-scale m k)          -> every element of m times k
;;   (matrix-multiply a b)       -> the matrix product (a's column
;;                                  count must equal b's row count, or
;;                                  this raises)
;;   (matrix-transpose m)
;;   (matrix-trace m)            -> the sum of m's diagonal (m must be
;;                                  square)
;;   (matrix-determinant m)      -> m's determinant, via recursive
;;                                  cofactor expansion along row 0 (m
;;                                  must be square) -- O(n!) time, same
;;                                  honest complexity tradeoff as (creme
;;                                  lr) raising on any parser conflict
;;                                  rather than resolving it: fine for
;;                                  small matrices, impractical much
;;                                  past n=10 or so. No LU-decomposition
;;                                  fast path.
;;   (matrix-equal? a b)         -> #t iff same dimensions and every
;;                                  element is =
;;   (matrix->list m)            -> m as a list of row-lists
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme matrix)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme matrix)
  (export make-matrix matrix list->matrix matrix? matrix-rows matrix-cols
          matrix-ref matrix-set! matrix-row matrix-column matrix-identity
          matrix-zero matrix-add matrix-sub matrix-scale matrix-multiply
          matrix-transpose matrix-trace matrix-determinant matrix-equal?
          matrix->list)
  (import (scheme base))
  (begin
    (define-record-type <matrix>
      (make-matrix-record rows cols data)
      matrix?
      (rows matrix-rows)
      (cols matrix-cols)
      (data matrix-data))

    (define (matrix-priv-row->vector row) (if (vector? row) row (list->vector row)))

    (define (make-matrix rows-list)
      (let* ((data (list->vector (map matrix-priv-row->vector rows-list)))
             (nrows (vector-length data))
             (ncols (if (= nrows 0) 0 (vector-length (vector-ref data 0)))))
        (make-matrix-record nrows ncols data)))

    (define (matrix . rows) (make-matrix rows))
    (define (list->matrix rows) (make-matrix rows))

    (define (matrix-ref m i j) (vector-ref (vector-ref (matrix-data m) i) j))
    (define (matrix-set! m i j v) (vector-set! (vector-ref (matrix-data m) i) j v))
    (define (matrix-row m i) (vector-copy (vector-ref (matrix-data m) i)))

    (define (matrix-column m j)
      (let ((v (make-vector (matrix-rows m))))
        (let loop ((i 0))
          (if (< i (matrix-rows m))
              (begin (vector-set! v i (matrix-ref m i j)) (loop (+ i 1)))))
        v))

    (define (matrix-zero nrows ncols)
      (let ((data (make-vector nrows)))
        (let loop ((i 0))
          (if (< i nrows)
              (begin (vector-set! data i (make-vector ncols 0)) (loop (+ i 1)))))
        (make-matrix-record nrows ncols data)))

    (define (matrix-identity n)
      (let ((m (matrix-zero n n)))
        (let loop ((i 0))
          (if (< i n) (begin (matrix-set! m i i 1) (loop (+ i 1)))))
        m))

    (define (matrix-priv-elementwise op a b who)
      (if (not (and (= (matrix-rows a) (matrix-rows b)) (= (matrix-cols a) (matrix-cols b))))
          (error (string-append who ": dimension mismatch") a b))
      (let ((result (matrix-zero (matrix-rows a) (matrix-cols a))))
        (let loop-i ((i 0))
          (if (< i (matrix-rows a))
              (begin
                (let loop-j ((j 0))
                  (if (< j (matrix-cols a))
                      (begin (matrix-set! result i j (op (matrix-ref a i j) (matrix-ref b i j))) (loop-j (+ j 1)))))
                (loop-i (+ i 1)))))
        result))

    (define (matrix-add a b) (matrix-priv-elementwise + a b "matrix-add"))
    (define (matrix-sub a b) (matrix-priv-elementwise - a b "matrix-sub"))

    (define (matrix-scale m k)
      (let ((result (matrix-zero (matrix-rows m) (matrix-cols m))))
        (let loop-i ((i 0))
          (if (< i (matrix-rows m))
              (begin
                (let loop-j ((j 0))
                  (if (< j (matrix-cols m))
                      (begin (matrix-set! result i j (* k (matrix-ref m i j))) (loop-j (+ j 1)))))
                (loop-i (+ i 1)))))
        result))

    (define (matrix-transpose m)
      (let ((result (matrix-zero (matrix-cols m) (matrix-rows m))))
        (let loop-i ((i 0))
          (if (< i (matrix-rows m))
              (begin
                (let loop-j ((j 0))
                  (if (< j (matrix-cols m))
                      (begin (matrix-set! result j i (matrix-ref m i j)) (loop-j (+ j 1)))))
                (loop-i (+ i 1)))))
        result))

    (define (matrix-multiply a b)
      (if (not (= (matrix-cols a) (matrix-rows b)))
          (error "matrix-multiply: dimension mismatch" a b))
      (let ((result (matrix-zero (matrix-rows a) (matrix-cols b))))
        (let loop-i ((i 0))
          (if (< i (matrix-rows a))
              (begin
                (let loop-j ((j 0))
                  (if (< j (matrix-cols b))
                      (begin
                        (let loop-k ((k 0) (sum 0))
                          (if (< k (matrix-cols a))
                              (loop-k (+ k 1) (+ sum (* (matrix-ref a i k) (matrix-ref b k j))))
                              (matrix-set! result i j sum)))
                        (loop-j (+ j 1)))))
                (loop-i (+ i 1)))))
        result))

    (define (matrix-trace m)
      (let loop ((i 0) (sum 0))
        (if (< i (matrix-rows m)) (loop (+ i 1) (+ sum (matrix-ref m i i))) sum)))

    (define (matrix-priv-row-without m i skip-col)
      (let loop ((j 0) (acc '()))
        (if (>= j (matrix-cols m))
            (reverse acc)
            (loop (+ j 1) (if (= j skip-col) acc (cons (matrix-ref m i j) acc))))))

    (define (matrix-priv-minor m skip-row skip-col)
      (make-matrix
       (let loop ((i 0) (acc '()))
         (if (>= i (matrix-rows m))
             (reverse acc)
             (loop (+ i 1) (if (= i skip-row) acc (cons (matrix-priv-row-without m i skip-col) acc)))))))

    (define (matrix-determinant m)
      (if (not (= (matrix-rows m) (matrix-cols m)))
          (error "matrix-determinant: matrix must be square" m))
      (let ((n (matrix-rows m)))
        (cond
         ((= n 0) 1)
         ((= n 1) (matrix-ref m 0 0))
         ((= n 2) (- (* (matrix-ref m 0 0) (matrix-ref m 1 1)) (* (matrix-ref m 0 1) (matrix-ref m 1 0))))
         (else
          (let loop ((j 0) (sum 0) (sign 1))
            (if (>= j n)
                sum
                (loop (+ j 1)
                      (+ sum (* sign (matrix-ref m 0 j) (matrix-determinant (matrix-priv-minor m 0 j))))
                      (- sign))))))))

    (define (matrix-equal? a b)
      (and (= (matrix-rows a) (matrix-rows b)) (= (matrix-cols a) (matrix-cols b))
           (let loop-i ((i 0))
             (or (>= i (matrix-rows a))
                 (and (let loop-j ((j 0))
                        (or (>= j (matrix-cols a))
                            (and (= (matrix-ref a i j) (matrix-ref b i j)) (loop-j (+ j 1)))))
                      (loop-i (+ i 1)))))))

    (define (matrix->list m)
      (let loop-i ((i 0) (acc '()))
        (if (>= i (matrix-rows m))
            (reverse acc)
            (loop-i (+ i 1) (cons (vector->list (matrix-row m i)) acc)))))))
