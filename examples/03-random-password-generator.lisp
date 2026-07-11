(require 'random)

(define charset
  #("a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m"
    "n" "o" "p" "q" "r" "s" "t" "u" "v" "w" "x" "y" "z"
    "A" "B" "C" "D" "E" "F" "G" "H" "I" "J" "K" "L" "M"
    "N" "O" "P" "Q" "R" "S" "T" "U" "V" "W" "X" "Y" "Z"
    "0" "1" "2" "3" "4" "5" "6" "7" "8" "9"
    "!" "@" "#" "$" "%"))

(define (random-char) (vector-ref charset (random:int 0 (- (vector-length charset) 1))))

(define (generate-password length)
  (apply string-append (map (lambda (_) (random-char)) (range 0 length))))

(random:seed 12345)
(println "16-char password: " (generate-password 16))
(println "12-char password: " (generate-password 12))
(println "8-char PIN-ish:   " (generate-password 8))
