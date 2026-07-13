; Complex numbers: a tiny ASCII Mandelbrot set renderer, using
; make-rectangular/real-part/imag-part/magnitude and complex +/* directly
; -- the classic showcase for a numeric tower that actually has complex
; numbers in it.

(import (scheme base) (scheme write) (scheme complex))

(define (mandelbrot-escape-count c max-iter)
  (let loop ((z (make-rectangular 0 0)) (n 0))
    (cond
      ((>= n max-iter) max-iter)
      ((> (magnitude z) 2) n)
      (else (loop (+ (* z z) c) (+ n 1))))))

(define (shade n max-iter)
  (cond
    ((= n max-iter) #\#)
    ((> n (quotient max-iter 2)) #\+)
    ((> n (quotient max-iter 4)) #\.)
    (else #\space)))

(define (render width height max-iter)
  (do ((row 0 (+ row 1)))
      ((= row height))
    (do ((col 0 (+ col 1)))
        ((= col width))
      (let* ((re (- (/ (* col 3.0) width) 2.0))
             (im (- (/ (* row 2.0) height) 1.0))
             (c (make-rectangular re im))
             (n (mandelbrot-escape-count c max-iter)))
        (write-char (shade n max-iter))))
    (newline)))

(render 60 20 30)

(newline)
(display "A few sample points and their escape counts:") (newline)
(for-each
  (lambda (c)
    (display "  ") (display c)
    (display " -> ") (display (mandelbrot-escape-count c 50))
    (newline))
  (list (make-rectangular 0 0)
        (make-rectangular -1 0)
        (make-rectangular 1 1)
        (make-rectangular -0.5 0.5)))
