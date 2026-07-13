; Demonstrates loading a dynamically-generated file-based library. Unlike
; the old (require "some/path.scm") mechanism (arbitrary absolute path,
; no name/content check), (import ...) only resolves libraries by NAME,
; searched across library_search_path (here: ./modules) — so a generated
; library must be written to a matching path under that search path, and
; must itself be a (define-library (name) ...) form whose declared name
; matches where it was found.
(import (creme file) (scheme base) (scheme write))

(define module-path "./modules/greeter.sld")

(file-write module-path
  "(define-library (greeter)
     (export greet shout-all)
     (import (scheme base))
     (begin
       (define (greet name) (string-append \"Hello, \" name \"!\"))
       (define (shout-all names) (map greet names))))")

(import (greeter))

(display (greet "Ada"))
(newline)
(display (shout-all '("Grace" "Alan")))
(newline)

(delete-file module-path)
