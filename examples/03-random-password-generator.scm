(import (scheme base) (scheme write) (creme random))

(define (range-list a b) (if (>= a b) '() (cons a (range-list (+ a 1) b))))

(define charset
  #("a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m"
    "n" "o" "p" "q" "r" "s" "t" "u" "v" "w" "x" "y" "z"
    "A" "B" "C" "D" "E" "F" "G" "H" "I" "J" "K" "L" "M"
    "N" "O" "P" "Q" "R" "S" "T" "U" "V" "W" "X" "Y" "Z"
    "0" "1" "2" "3" "4" "5" "6" "7" "8" "9"
    "!" "@" "#" "$" "%"))

(define (random-char) (vector-ref charset (random-integer (vector-length charset))))

(define (generate-password length)
  (apply string-append (map (lambda (_) (random-char)) (range-list 0 length))))

(random-seed! 12345)
(display "16-char password: ") (display (generate-password 16)) (newline)
(display "12-char password: ") (display (generate-password 12)) (newline)
(display "8-char PIN-ish:   ") (display (generate-password 8)) (newline)
