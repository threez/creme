;; ===========================================================================
;; cvm's "compiler mode" driver -- compiles and runs a plain .scm file
;; directly under cvm, with no live Crystal `creme` process involved.
;; ===========================================================================
;;
;; Precompiled once (bundling the self-hosted compiler, exactly like
;; cvm/repl.scm does), then used automatically by main.c whenever cvm is
;; pointed at a file that ISN'T already an SCB1 binary (main.c peeks the
;; first 4 bytes -- a plain .scm file can never coincidentally start with
;; "SCB1"): main.c stashes the real target path (cvm-target-path) and
;; loads+runs THIS chunk instead, which reads/compiles/runs the real
;; target itself.
;;
;; Build once, then run any script directly:
;;   ./bin/creme --emit-cvm cvm/compiler-run.scm cvm/compiler-run.cvmc
;;   ./cvm/cvm bench/creme.scm
;;
;; `include`/`include-ci`: the self-hosted compiler itself deliberately
;; doesn't support these (reader.sld's own header comment -- real support
;; needs a path-resolution design this project hasn't needed yet). Rather
;; than take that on, this driver expands them itself, entirely from
;; already-exported toolchain primitives (read-program/compile-program/
;; chunk->bytes -- no changes to reader.sld/compiler.sld/bytecode.sld):
;; parse the target into forms, recursively splice in each top-level
;; `(include "path" ...)`'s own parsed forms (resolved relative to the
;; INCLUDING file's own directory, so a nested include resolves against
;; wherever ITS OWN file lives), then compile the flattened list.
(import (scheme base) (scheme write) (scheme lazy)
        (creme peg) (creme regex) (creme bytecode) (creme bootstrap)
        (creme compiler reader) (creme compiler compiler))

(define (dirname path)
  (let loop ((i (- (string-length path) 1)))
    (cond
      ((< i 0) "")
      ((char=? (string-ref path i) #\/) (substring path 0 i))
      (else (loop (- i 1))))))

(define (path-join dir name)
  (if (string=? dir "") name (string-append dir "/" name)))

(define (expand-includes forms dir)
  (apply append
    (map (lambda (form)
           (if (and (pair? form) (or (eq? (car form) 'include) (eq? (car form) 'include-ci)))
               (apply append
                 (map (lambda (relpath)
                        (let ((full (path-join dir relpath)))
                          (expand-includes (read-program (read-whole-file full)) (dirname full))))
                      (cdr form)))
               (list form)))
         forms)))

(define target (cvm-target-path))
(define forms (expand-includes (read-program (read-whole-file target)) (dirname target)))
(load-chunk-bytes (chunk->bytes (compile-program forms)))
