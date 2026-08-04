;; ===========================================================================
;; (creme tsort): topological sort + strongly-connected-components
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme set)/(creme memoize) use) since every export here is expressible
;; in plain R7RS on top of (creme hash-table)'s primitives, with no opaque
;; foreign object or third-party Crystal library involved.
;;
;; Graph representation: a plain alist `((node . (dep ...)) ...)` — node's
;; own dependencies must appear BEFORE node in the sorted output (the
;; natural direction for "build order"/"load order"/"task scheduling" use
;; cases, e.g. `((deploy . (build test)) (test . (build)) (build . ()))`).
;; A node mentioned only as someone else's dependency, never as its own
;; key, is treated as a dependency-free node (an implicit `(node . ())`
;; entry) — the caller doesn't have to pad the alist with empty leaf
;; entries.
;;
;;   (tsort graph)  -> graph's nodes as a list, dependencies-first — every
;;                     node appears somewhere after all of its own
;;                     (transitive) dependencies. Raises via R7RS `error`
;;                     (message "tsort: graph has a cycle", irritant: the
;;                     list of nodes still unresolved when no further
;;                     progress could be made) if graph isn't a DAG —
;;                     Ruby's TSort::Cyclic.
;;   (tsort? graph) -> #t if graph is a DAG (tsort wouldn't raise), #f if
;;                     it has a cycle — for a caller that wants to check
;;                     first rather than catching an exception.
;;   (tsort-strongly-connected-components graph)
;;                  -> a list of strongly-connected components (each a
;;                     list of nodes), dependencies-first — the same order
;;                     tsort itself uses, so a graph with a cycle still
;;                     produces a full, useful answer here (each cycle
;;                     collapses into one multi-node component) rather
;;                     than raising. A DAG's components are all singletons,
;;                     in the same order tsort itself would return.
;;                     Computed via Tarjan's algorithm (recursive — no
;;                     explicit work-stack, so a pathologically deep
;;                     dependency chain could hit this interpreter's own
;;                     recursion limit; fine for ordinary build/load
;;                     graphs, not meant for huge synthetic inputs).
;;
;; Not auto-imported anywhere — every script that wants this must
;; (import (creme tsort)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme tsort)
  (export tsort tsort? tsort-strongly-connected-components)
  (import (scheme base) (creme hash-table) (only (creme extra) filter))
  (begin
    ;; (tsort-priv-nodes graph) -> every node mentioned anywhere in graph
    ;; (as a key or as someone's dependency), de-duplicated, in first-seen
    ;; order.
    (define (tsort-priv-nodes graph)
      (let ((seen (make-hash-table)) (order '()))
        (define (see! n)
          (if (not (hash-table-contains? seen n))
              (begin (hash-table-set! seen n #t) (set! order (cons n order)))))
        (for-each
         (lambda (entry)
           (see! (car entry))
           (for-each see! (cdr entry)))
         graph)
        (reverse order)))

    ;; (tsort-priv-deps-of graph node) -> node's declared dependency list,
    ;; or '() if node has no entry of its own (an implicit leaf).
    (define (tsort-priv-deps-of graph node)
      (let ((entry (assoc node graph)))
        (if entry (cdr entry) '())))

    ;; Kahn's algorithm. Returns two values: the sorted list, and the list
    ;; of nodes never reached (non-empty exactly when graph has a cycle,
    ;; since those nodes' in-degree could never reach 0).
    (define (tsort-priv-kahn graph)
      (let* ((nodes (tsort-priv-nodes graph))
             (indegree (make-hash-table))
             (dependents (make-hash-table)))
        (for-each (lambda (n) (hash-table-set! indegree n 0) (hash-table-set! dependents n '())) nodes)
        (for-each
         (lambda (n)
           (let ((deps (tsort-priv-deps-of graph n)))
             (hash-table-set! indegree n (length deps))
             (for-each
              (lambda (d) (hash-table-set! dependents d (cons n (hash-table-ref dependents d))))
              deps)))
         nodes)
        (let loop ((queue (filter (lambda (n) (= 0 (hash-table-ref indegree n))) nodes))
                   (result '()))
          (if (null? queue)
              (values (reverse result)
                      (filter (lambda (n) (> (hash-table-ref indegree n) 0)) nodes))
              (let* ((n (car queue))
                     (rest (cdr queue))
                     (freed
                      (filter
                       (lambda (d)
                         (hash-table-set! indegree d (- (hash-table-ref indegree d) 1))
                         (= 0 (hash-table-ref indegree d)))
                       (hash-table-ref dependents n))))
                (loop (append rest freed) (cons n result)))))))

    (define (tsort graph)
      (call-with-values
       (lambda () (tsort-priv-kahn graph))
       (lambda (sorted unresolved)
         (if (null? unresolved)
             sorted
             (error "tsort: graph has a cycle" unresolved)))))

    (define (tsort? graph)
      (call-with-values
       (lambda () (tsort-priv-kahn graph))
       (lambda (sorted unresolved) (null? unresolved))))

    ;; Tarjan's algorithm, walking dependency edges (node -> each of its
    ;; deps) so a component finishes (and is appended to the result) only
    ;; after all of its own dependencies' components already have —
    ;; giving the same dependencies-first order as tsort itself.
    (define (tsort-strongly-connected-components graph)
      (let ((nodes (tsort-priv-nodes graph))
            (indices (make-hash-table))
            (lowlink (make-hash-table))
            (on-stack (make-hash-table))
            (counter 0)
            (stack '())
            (components '()))
        (define (strongconnect! v)
          (hash-table-set! indices v counter)
          (hash-table-set! lowlink v counter)
          (set! counter (+ counter 1))
          (set! stack (cons v stack))
          (hash-table-set! on-stack v #t)
          (for-each
           (lambda (w)
             (cond
              ((not (hash-table-contains? indices w))
               (strongconnect! w)
               (hash-table-set! lowlink v (min (hash-table-ref lowlink v) (hash-table-ref lowlink w))))
              ((hash-table-contains? on-stack w)
               (hash-table-set! lowlink v (min (hash-table-ref lowlink v) (hash-table-ref indices w))))))
           (tsort-priv-deps-of graph v))
          (if (= (hash-table-ref lowlink v) (hash-table-ref indices v))
              (let loop ((scc '()))
                (let ((w (car stack)))
                  (set! stack (cdr stack))
                  (hash-table-delete! on-stack w)
                  (if (equal? w v)
                      (set! components (cons (reverse (cons w scc)) components))
                      (loop (cons w scc)))))))
        (for-each (lambda (v) (if (not (hash-table-contains? indices v)) (strongconnect! v))) nodes)
        (reverse components)))))
