(require 'clos)

(defclass book ()
  ((title :reader book-title
          :initarg :title)
   (author :reader book-author
           :initarg :author)
   (checked-out :accessor book-checked-out
                :initarg :checked-out
                :initform #f)))

(defclass ebook (book)
  ((file-size-mb :reader ebook-file-size-mb
                 :initarg :file-size-mb)))

(defgeneric describe-item (item))

(defmethod describe-item ((b book))
  (string-append (book-title b) " by " (book-author b)))

(defmethod describe-item ((b ebook))
  (string-append (call-next-method) " (ebook, " (number->string (ebook-file-size-mb b)) "MB)"))

(define catalog
  (list
    (make-instance 'book :title "ANSI Common Lisp" :author "Paul Graham")
    (make-instance 'ebook :title "The Little Schemer" :author "Friedman & Felleisen" :file-size-mb 4)))

(for-each
  (lambda (item) (println (describe-item item)))
  catalog)

(define first-book (car catalog))
(set-book-checked-out! first-book #t)
(println (book-title first-book) " checked out? " (book-checked-out first-book))
(println (book-title first-book) " is a book? " (instance-of? first-book 'book))
(println (book-title (second catalog)) " is a book? " (instance-of? (second catalog) 'book))
