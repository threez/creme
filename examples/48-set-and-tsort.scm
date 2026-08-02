(import (scheme base) (scheme write) (creme set) (creme tsort) (creme sort))

;; A small build graph: each entry's dependencies must build first.
(define build-graph
  '((deploy . (bundle test))
    (test . (compile))
    (bundle . (compile))
    (compile . (fetch-deps))
    (fetch-deps . ())))

(display "build order: ") (display (tsort build-graph)) (newline)
(newline)

;; Which targets are independent, dependency-wise? Group into strongly
;; connected components -- a DAG's components are all singletons.
(display "components: ") (display (tsort-strongly-connected-components build-graph)) (newline)
(newline)

;; Sets: track which targets have already been built in this run.
(define built (set 'fetch-deps 'compile))
(define all-targets (list->set (map car build-graph)))
(define remaining (set-difference all-targets built))

(define (sym<? a b) (string<? (symbol->string a) (symbol->string b)))

(display "already built: ") (display (list-sort sym<? (set->list built))) (newline)
(display "still remaining: ") (display (list-sort sym<? (set->list remaining))) (newline)
(display "is 'deploy remaining? ") (display (set-member? remaining 'deploy)) (newline)
