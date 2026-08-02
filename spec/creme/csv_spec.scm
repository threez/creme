;; ===========================================================================
;; A (creme spec)-based port of (creme csv)'s own cases -- see
;; modules/creme/spec.sld's own header comment for the framework this
;; uses, and compiler_spec.scm's own header comment for the general
;; should-match-native? approach.
;;
;; (creme csv) used to be entirely absent from cvm. Implemented as a
;; small, self-contained RFC4180-ish parser/writer (cvm/csv.c) rather
;; than a port of native's own chunked-IO-optimized Creme::Csv (see that
;; file's own header comment on why the two designs differ) -- both bulk
;; (csv-read/csv-write/csv-read-headers/csv-write-headers) and streaming
;; (csv-reader-open/-read!/-?, csv-writer-open/-row!/-?) built on the same
;; generic row-parser, driven either over a plain buffer or over a Port
;; via the shared cvm_port_read_char/cvm_port_write_bytes helpers
;; introduced alongside this file.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/csv_spec.scm
;;   ./bin/creme --self-hosted spec/creme/csv_spec.scm
;;   ./cvm/cvm spec/creme/csv_spec.scm
;; ===========================================================================

;; See compiler_spec.scm's own comment on why the full toolchain import
;; list is still needed here even though (creme compiler spec-helper)
;; already imports all of it for itself.
(import (scheme base) (scheme write) (scheme process-context) (scheme eval)
        (scheme lazy) (creme csv) (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler) (creme spec) (creme compiler spec-helper))

(describe "(creme csv)"
  (it "csv-read parses rows of cells as strings"
    (should-match-native? '((csv-read "a,b,c\n1,2,3\n"))))

  (it "csv-read handles quoted cells containing the separator and doubled quotes"
    (should-match-native? '((csv-read "x,\"y,z\",\"a\"\"b\"\n"))))

  (it "csv-read-headers pairs each row's cells with the header row"
    (should-match-native? '((csv-read-headers "a,b\n1,2\n3,4\n"))))

  (it "csv-write quotes only cells that need it (rfc, the default)"
    (should-match-native? '((csv-write (vector (vector "x" "y,z" 1) (vector "q\"w" 2.5 #t))))))

  (it "csv-write's quoting mode can be none or all"
    (should-match-native? '((csv-write (vector (vector "a,b")) #\, 'none)))
    (should-match-native? '((csv-write (vector (vector "a" 1)) #\, 'all))))

  (it "csv-write-headers writes a header row ahead of the data rows"
    (should-match-native? '((csv-write-headers (vector "h1" "h2") (vector (vector "v1" "v2"))))))

  (it "csv-writer-open/csv-writer-row!/csv-writer? stream rows to a port"
    (should-match-native?
     '((define p (open-output-string))
       (define w (csv-writer-open p))
       (csv-writer-row! w "a" "b,c" 3)
       (list (get-output-string p) (csv-writer? w) (csv-writer? 5)))))

  (it "csv-reader-open/csv-reader-read!/csv-reader? stream rows from a port"
    (should-match-native?
     '((define ip (open-input-string "x,y\n1,2\n"))
       (define r (csv-reader-open ip))
       (list (csv-reader-read! r) (csv-reader-read! r) (eof-object? (csv-reader-read! r))
             (csv-reader? r) (csv-reader? 5))))))

(spec-summary!)
