;; ===========================================================================
;; (creme lr): a small, from-scratch SLR(1) parser generator + driver
;;
;; File-based (no FFI of its own — same rationale as modules/creme/numfmt.sld's
;; header comment). Deliberately built as ordinary higher-order functions and
;; plain data, not macros: this Scheme's define-syntax/syntax-rules is
;; unhygienic (see the README's Known caveats and (creme peg)'s own header
;; comment for the same reasoning) — a grammar-construction DSL is exactly
;; where a hygiene bug would be most likely to bite silently.
;;
;; This is a PLAIN SLR(1) generator: no precedence/associativity declarations
;; (no bison-style %left/%right/%prec) — every grammar must already be
;; unambiguous on its own. The standard way to get there is the same trick
;; any hand-written recursive-descent parser already uses: encode operator
;; precedence structurally, via layered nonterminals, e.g.
;;   (add-expr -> add-expr '+ mul-expr | add-expr '- mul-expr | mul-expr)
;;   (mul-expr -> mul-expr '* unary    | mul-expr '/ unary    | unary)
;; instead of one flat, ambiguous (expr -> expr OP expr) rule. A shift/reduce
;; or reduce/reduce conflict at build-parser time always means the grammar
;; itself is ambiguous (or not SLR(1)) — never something this library papers
;; over with a precedence table — so build-parser raises immediately, naming
;; the offending state/symbol/actions, rather than silently picking one.
;;
;; ---- grammar representation ----
;;
;;   (make-rule lhs rhs action)  -> one production, `lhs` a nonterminal
;;                                   symbol, `rhs` a list of symbols
;;                                   (terminals and nonterminals are told
;;                                   apart purely by whether a symbol ever
;;                                   appears as some rule's own `lhs` --
;;                                   there's no separate terminal/nonterminal
;;                                   declaration), `action` a procedure of
;;                                   (length rhs) arguments -- each rhs
;;                                   symbol's own semantic value, in order --
;;                                   returning lhs's semantic value. `rhs`
;;                                   '() is a valid epsilon production (e.g.
;;                                   an optional/repeatable clause's empty
;;                                   base case); its action takes zero
;;                                   arguments.
;;   (make-grammar start rules)  -> bundles a start symbol with the full
;;                                   rule list (a plain list of make-rule
;;                                   results) into a grammar value.
;;
;; ---- building and running a parser ----
;;
;;   (build-parser grammar)      -> the actual generator: computes FIRST/
;;                                   FOLLOW sets, the canonical LR(0) item
;;                                   sets (closure/goto), and the resulting
;;                                   SLR(1) ACTION/GOTO tables, raising on any
;;                                   conflict. Returns an opaque parser-table
;;                                   value.
;;   (lr-parse table tokens token-symbol token-value)
;;                               -> runs the shift-reduce driver over
;;                                   `tokens` (a list, in any caller-chosen
;;                                   token representation -- `token-symbol`/
;;                                   `token-value` are procedures pulling the
;;                                   grammar terminal symbol and the semantic
;;                                   value out of one, so this library never
;;                                   needs to know a token's shape), calling
;;                                   each reduced rule's `action` with its
;;                                   matched symbols' values in left-to-right
;;                                   order, and returns the start symbol's
;;                                   final semantic value. `eof` is a
;;                                   reserved terminal symbol implicitly
;;                                   supplied once `tokens` is exhausted --
;;                                   don't use it as an ordinary grammar
;;                                   symbol. Raises on an unexpected token
;;                                   (naming the offending terminal symbol).
;;   (debug-states grammar)      -> (list rules-vec states transitions),
;;                                   skipping table-building/conflict-
;;                                   checking -- for inspecting exactly
;;                                   which items ended up sharing a state
;;                                   while tracking down a build-parser
;;                                   conflict (see its own doc comment).
;;
;; Example -- a tiny tiered-precedence arithmetic grammar (`expr -> add-expr`,
;; `add-expr -> add-expr '+ mul-expr | mul-expr`, `mul-expr -> mul-expr '*
;; num | num`), evaluating directly as its own semantic action:
;;   (define g
;;     (make-grammar 'expr
;;       (list (make-rule 'expr (list 'add-expr) (lambda (v) v))
;;             (make-rule 'add-expr (list 'add-expr 'plus 'mul-expr) (lambda (a _ b) (+ a b)))
;;             (make-rule 'add-expr (list 'mul-expr) (lambda (v) v))
;;             (make-rule 'mul-expr (list 'mul-expr 'star 'num) (lambda (a _ b) (* a b)))
;;             (make-rule 'mul-expr (list 'num) (lambda (v) v)))))
;;   (define pt (build-parser g))
;;   ;; tokens for "2 + 3 * 4": a plain (kind . value) pair per token here
;;   (lr-parse pt (list (cons 'num 2) (cons 'plus #f) (cons 'num 3) (cons 'star #f) (cons 'num 4))
;;             car cdr)
;;   ;; => 14 (3 * 4 first, then + 2 -- '*' binds tighter, exactly because
;;   ;;        mul-expr is the lower/tighter-binding tier)
;;
;; Not auto-imported anywhere — every dialect that wants this must (import
;; (creme lr)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme lr)
  (export make-rule make-grammar build-parser lr-parse debug-states)
  (import (scheme base) (scheme cxr) (creme hash-table) (creme sort))
  (begin
    ;; ------------------------------------------------------------------
    ;; small local helpers (deliberately not (creme extra) -- this stays a
    ;; self-contained, minimal-dependency library, same convention (creme
    ;; syntax scss)/(creme syntax slim) already follow for their own small
    ;; helpers like a local `filter`)
    ;; ------------------------------------------------------------------

    (define (all? pred lst) (or (null? lst) (and (pred (car lst)) (all? pred (cdr lst)))))

    (define (filter-truthy lst)
      (cond ((null? lst) '())
            ((car lst) (cons (car lst) (filter-truthy (cdr lst))))
            (else (filter-truthy (cdr lst)))))

    (define (filter-new seen items)
      (cond ((null? items) '())
            ((hash-table-contains? seen (car items)) (filter-new seen (cdr items)))
            (else (cons (car items) (filter-new seen (cdr items))))))

    (define (dedup-symbols lst)
      (cond ((null? lst) '())
            ((memq (car lst) (cdr lst)) (dedup-symbols (cdr lst)))
            (else (cons (car lst) (dedup-symbols (cdr lst))))))

    ;; Set union over two lists of symbols (order/dups don't matter to any
    ;; caller here, only membership) -- O(n*m), fine at this grammar's scale.
    (define (set-union a b)
      (if (null? b) a (set-union (if (memq (car b) a) a (cons (car b) a)) (cdr b))))

    (define (take-n lst n) (if (or (= n 0) (null? lst)) '() (cons (car lst) (take-n (cdr lst) (- n 1)))))
    (define (drop-n lst n) (if (or (= n 0) (null? lst)) lst (drop-n (cdr lst) (- n 1))))

    ;; ------------------------------------------------------------------
    ;; grammar representation
    ;; ------------------------------------------------------------------

    ;; (make-rule lhs rhs action) -- see this file's own header comment.
    (define (make-rule lhs rhs action) (list lhs rhs action))
    (define (rule-lhs r) (vector-ref r 0))
    (define (rule-rhs r) (vector-ref r 1))
    (define (rule-action r) (vector-ref r 2))

    ;; (make-grammar start rules) -- see this file's own header comment.
    (define (make-grammar start rules) (cons start rules))
    (define (grammar-start g) (car g))
    (define (grammar-rules g) (cdr g))

    ;; nt-idx: a (creme hash-table) mapping every nonterminal symbol to the
    ;; list of rule-indices (into rules-vec) whose own lhs it is -- this
    ;; single table doubles as both "is sym a nonterminal at all?" (via
    ;; hash-table-contains?) and "which productions does it expand to?" (via
    ;; hash-table-ref) throughout the rest of this file.
    (define (build-nonterm-index rules-vec)
      (let ((table (make-hash-table)))
        (let loop ((i 0))
          (when (< i (vector-length rules-vec))
            (let ((lhs (rule-lhs (vector-ref rules-vec i))))
              (hash-table-set! table lhs (append (hash-table-ref table lhs (lambda () '())) (list i))))
            (loop (+ i 1))))
        table))

    ;; ------------------------------------------------------------------
    ;; FIRST / nullable / FOLLOW (fixpoint computations over rules-vec)
    ;; ------------------------------------------------------------------

    (define (nullable-of-symbol nullable nt-idx sym)
      (and (hash-table-contains? nt-idx sym) (hash-table-ref nullable sym (lambda () #f))))

    (define (nullable-of-seq nullable nt-idx seq)
      (all? (lambda (s) (nullable-of-symbol nullable nt-idx s)) seq))

    (define (compute-nullable rules-vec nt-idx)
      (let ((table (make-hash-table)))
        (for-each (lambda (nt) (hash-table-set! table nt #f)) (hash-table-keys nt-idx))
        (let loop ((changed #t))
          (if (not changed)
              table
              (loop
               (let scan ((i 0) (any-changed #f))
                 (if (>= i (vector-length rules-vec))
                     any-changed
                     (let* ((r (vector-ref rules-vec i)) (lhs (rule-lhs r)))
                       (if (and (not (hash-table-ref table lhs (lambda () #f)))
                                (all? (lambda (s) (nullable-of-symbol table nt-idx s)) (rule-rhs r)))
                           (begin (hash-table-set! table lhs #t) (scan (+ i 1) #t))
                           (scan (+ i 1) any-changed))))))))))

    (define (first-of-symbol table nt-idx sym)
      (if (hash-table-contains? nt-idx sym) (hash-table-ref table sym (lambda () '())) (list sym)))

    ;; FIRST of a whole symbol sequence: FIRST(s1), plus FIRST(s2) too if s1
    ;; is nullable, plus FIRST(s3) too if s1 AND s2 are both nullable, etc.
    (define (first-of-seq table nt-idx nullable seq)
      (if (null? seq)
          '()
          (let ((f1 (first-of-symbol table nt-idx (car seq))))
            (if (nullable-of-symbol nullable nt-idx (car seq))
                (set-union f1 (first-of-seq table nt-idx nullable (cdr seq)))
                f1))))

    (define (compute-first rules-vec nt-idx nullable)
      (let ((table (make-hash-table)))
        (for-each (lambda (nt) (hash-table-set! table nt '())) (hash-table-keys nt-idx))
        (let loop ((changed #t))
          (if (not changed)
              table
              (loop
               (let scan ((i 0) (any-changed #f))
                 (if (>= i (vector-length rules-vec))
                     any-changed
                     (let* ((r (vector-ref rules-vec i)) (lhs (rule-lhs r))
                            (old (hash-table-ref table lhs (lambda () '())))
                            (new (set-union old (first-of-seq table nt-idx nullable (rule-rhs r)))))
                       (if (> (length new) (length old))
                           (begin (hash-table-set! table lhs new) (scan (+ i 1) #t))
                           (scan (+ i 1) any-changed))))))))))

    ;; One left-to-right scan of a single rule's rhs for FOLLOW purposes:
    ;; for A -> alpha B beta (every nonterminal B in rhs, beta = whatever
    ;; comes after it), FIRST(beta) (minus epsilon) flows into FOLLOW(B), and
    ;; FOLLOW(A) itself flows into FOLLOW(B) too whenever beta is empty or
    ;; nullable. Returns #t iff this scan grew some FOLLOW set.
    (define (follow-scan-rhs nt-idx first-table nullable follow lhs rhs)
      (if (null? rhs)
          #f
          (let* ((b (car rhs)) (beta (cdr rhs)))
            (let ((changed
                   (if (hash-table-contains? nt-idx b)
                       (let* ((old (hash-table-ref follow b (lambda () '())))
                              (first-beta (first-of-seq first-table nt-idx nullable beta))
                              (u1 (set-union old first-beta))
                              (grew1 (> (length u1) (length old))))
                         (when grew1 (hash-table-set! follow b u1))
                         (if (nullable-of-seq nullable nt-idx beta)
                             (let* ((old2 (hash-table-ref follow b (lambda () '())))
                                    (follow-lhs (hash-table-ref follow lhs (lambda () '())))
                                    (u2 (set-union old2 follow-lhs))
                                    (grew2 (> (length u2) (length old2))))
                               (when grew2 (hash-table-set! follow b u2))
                               (or grew1 grew2))
                             grew1))
                       #f)))
              (or changed (follow-scan-rhs nt-idx first-table nullable follow lhs beta))))))

    (define (compute-follow rules-vec nt-idx start first-table nullable)
      (let ((follow (make-hash-table)))
        (for-each (lambda (nt) (hash-table-set! follow nt '())) (hash-table-keys nt-idx))
        (hash-table-set! follow start (list 'eof))
        (let loop ((changed #t))
          (if (not changed)
              follow
              (loop
               (let scan ((i 0) (any-changed #f))
                 (if (>= i (vector-length rules-vec))
                     any-changed
                     (let ((r (vector-ref rules-vec i)))
                       (scan (+ i 1)
                             (or (follow-scan-rhs nt-idx first-table nullable follow (rule-lhs r) (rule-rhs r))
                                 any-changed))))))))))

    ;; ------------------------------------------------------------------
    ;; canonical LR(0) item sets: closure / goto / the state graph
    ;; ------------------------------------------------------------------

    ;; An item is (rule-index . dot-position). item-next-symbol is the
    ;; symbol immediately after the dot, or #f once the dot has reached the
    ;; end of that rule's rhs (a "completed" item -- a candidate reduction).
    (define (item-next-symbol rules-vec item)
      (let* ((rhs (rule-rhs (vector-ref rules-vec (car item)))) (dot (cdr item)))
        (if (< dot (length rhs)) (list-ref rhs dot) #f)))

    (define (item<? a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cdr a) (cdr b)))))

    (define (dedup-sorted-items lst)
      (cond ((or (null? lst) (null? (cdr lst))) lst)
            ((equal? (car lst) (cadr lst)) (dedup-sorted-items (cdr lst)))
            (else (cons (car lst) (dedup-sorted-items (cdr lst))))))

    ;; Canonical form of an item set: sorted + deduped, so two closures that
    ;; reach the same set of items always compare `equal?` -- required for
    ;; the state-table hash-table below to correctly recognize an
    ;; already-seen state instead of creating a duplicate one.
    (define (canonicalize-items items) (dedup-sorted-items (list-sort item<? items)))

    ;; Expands an item set to its closure: wherever the dot sits just before
    ;; some nonterminal B, every one of B's own productions (dot at 0) is
    ;; added too, to a fixpoint (a worklist over newly-added items only).
    (define (closure rules-vec nt-idx items0)
      (let ((seen (make-hash-table)))
        (for-each (lambda (it) (hash-table-set! seen it #t)) items0)
        (let loop ((worklist items0) (acc items0))
          (if (null? worklist)
              (canonicalize-items acc)
              (let* ((item (car worklist)) (sym (item-next-symbol rules-vec item)))
                (if (and sym (hash-table-contains? nt-idx sym))
                    (let* ((rule-idxs (hash-table-ref nt-idx sym (lambda () '())))
                           (candidates (map (lambda (ri) (cons ri 0)) rule-idxs))
                           (new-items (filter-new seen candidates)))
                      (for-each (lambda (it) (hash-table-set! seen it #t)) new-items)
                      (loop (append (cdr worklist) new-items) (append acc new-items)))
                    (loop (cdr worklist) acc)))))))

    ;; goto(items, sym): every item with `sym` right after its dot, dot
    ;; advanced one position, then closure -- the transition target state
    ;; for `sym` out of the state `items` belongs to. '() (no transition) if
    ;; nothing in `items` has `sym` next.
    (define (goto rules-vec nt-idx items sym)
      (let ((advanced (filter-truthy
                        (map (lambda (it)
                               (if (equal? (item-next-symbol rules-vec it) sym)
                                   (cons (car it) (+ (cdr it) 1))
                                   #f))
                             items))))
        (if (null? advanced) '() (closure rules-vec nt-idx advanced))))

    (define (next-symbols rules-vec items)
      (dedup-symbols (filter-truthy (map (lambda (it) (item-next-symbol rules-vec it)) items))))

    ;; BFS over the canonical collection of LR(0) item sets, from the
    ;; initial state (closure of the augmented start item). Returns (list
    ;; states-vector transitions), transitions a list of (from-state symbol
    ;; to-state) triples covering every discovered shift/goto edge.
    (define (compute-states rules-vec nt-idx)
      (let* ((state0 (closure rules-vec nt-idx (list (cons 0 0))))
             (seen (make-hash-table)))
        (hash-table-set! seen state0 0)
        (let loop ((queue (list (cons 0 state0))) (states-acc (list state0)) (next-idx 1) (trans '()))
          (if (null? queue)
              (list (list->vector (reverse states-acc)) trans)
              (let* ((cur (car queue)) (cur-idx (car cur)) (cur-items (cdr cur))
                     (syms (next-symbols rules-vec cur-items)))
                (let sym-loop ((syms syms) (q (cdr queue)) (sacc states-acc) (nidx next-idx) (tr trans))
                  (if (null? syms)
                      (loop q sacc nidx tr)
                      (let ((target (goto rules-vec nt-idx cur-items (car syms))))
                        (if (null? target)
                            (sym-loop (cdr syms) q sacc nidx tr)
                            (let ((existing (hash-table-ref seen target (lambda () #f))))
                              (if existing
                                  (sym-loop (cdr syms) q sacc nidx (cons (list cur-idx (car syms) existing) tr))
                                  (begin
                                    (hash-table-set! seen target nidx)
                                    (sym-loop (cdr syms)
                                              (append q (list (cons nidx target)))
                                              (cons target sacc)
                                              (+ nidx 1)
                                              (cons (list cur-idx (car syms) nidx) tr))))))))))))))

    ;; ------------------------------------------------------------------
    ;; ACTION/GOTO table construction
    ;; ------------------------------------------------------------------

    ;; Both ACTION (terminal columns: shift/reduce/accept) and GOTO
    ;; (nonterminal columns) live in one hash-table keyed by (state . symbol)
    ;; -- safe to share since a symbol is consistently either a terminal or a
    ;; nonterminal across the whole grammar, never both, so the two column
    ;; kinds never collide on the same key.
    (define (set-table-cell! table key action)
      (let ((existing (hash-table-ref table key (lambda () #f))))
        (if (and existing (not (equal? existing action)))
            (error "lr: grammar conflict (not SLR(1) -- encode precedence via layered nonterminals instead)"
                   key existing action)
            (hash-table-set! table key action))))

    ;; (debug-states grammar) -> (list rules-vec states transitions),
    ;; skipping table-building/conflict-checking entirely -- for a grammar
    ;; author iterating on a `build-parser` conflict, to inspect exactly
    ;; which items ended up sharing a state (states is a vector of item
    ;; lists; each item is (rule-index . dot-position), rule-index into
    ;; rules-vec -- (vector-ref rules-vec rule-index) is #(lhs rhs
    ;; action)). A `build-parser` conflict error names a specific
    ;; (state . symbol) pair; look up that state here to see every item
    ;; competing there and work out which production is pulling in an
    ;; unwanted one.
    (define (debug-states grammar)
      (let* ((start (grammar-start grammar))
             (user-rules (grammar-rules grammar))
             (augmented (cons (make-rule '%lr-start (list start) (lambda (v) v)) user-rules))
             (rules-vec (list->vector (map (lambda (r) (list->vector r)) augmented)))
             (nt-idx (build-nonterm-index rules-vec))
             (built (compute-states rules-vec nt-idx)))
        (list rules-vec (car built) (cadr built))))

    (define (build-parser grammar)
      (let* ((start (grammar-start grammar))
             (user-rules (grammar-rules grammar))
             (augmented (cons (make-rule '%lr-start (list start) (lambda (v) v)) user-rules))
             (rules-vec (list->vector (map (lambda (r) (list->vector r)) augmented)))
             (nt-idx (build-nonterm-index rules-vec))
             (nullable (compute-nullable rules-vec nt-idx))
             (first-table (compute-first rules-vec nt-idx nullable))
             (follow (compute-follow rules-vec nt-idx start first-table nullable))
             (built (compute-states rules-vec nt-idx))
             (states (car built))
             (transitions (cadr built))
             (cell-table (make-hash-table)))
        (for-each
         (lambda (tr)
           (let* ((s (car tr)) (sym (cadr tr)) (target (caddr tr))
                  (kind (if (hash-table-contains? nt-idx sym) (list 'goto target) (list 'shift target))))
             (set-table-cell! cell-table (cons s sym) kind)))
         transitions)
        (let loop ((i 0))
          (when (< i (vector-length states))
            (for-each
             (lambda (item)
               (let* ((r (vector-ref rules-vec (car item))) (rhs (rule-rhs r)))
                 (when (= (cdr item) (length rhs))
                   (if (= (car item) 0)
                       (set-table-cell! cell-table (cons i 'eof) (list 'accept))
                       (for-each (lambda (t) (set-table-cell! cell-table (cons i t) (list 'reduce (car item))))
                                 (hash-table-ref follow (rule-lhs r) (lambda () '())))))))
             (vector-ref states i))
            (loop (+ i 1))))
        (list cell-table rules-vec)))

    ;; ------------------------------------------------------------------
    ;; the shift-reduce driver
    ;; ------------------------------------------------------------------

    (define (table-lookup pt s sym) (hash-table-ref (car pt) (cons s sym) (lambda () #f)))
    (define (table-rules pt) (cadr pt))

    ;; (lr-parse table tokens token-symbol token-value) -- see this file's
    ;; own header comment. Stack entries are (state . value) pairs; `value`
    ;; on a shifted terminal is that token's own token-value, on a reduced
    ;; nonterminal it's whatever the rule's action returned.
    (define (lr-parse pt tokens token-symbol token-value)
      (let loop ((stack (list (cons 0 #f))) (remaining tokens))
        (let* ((cur-state (car (car stack)))
               (at-eof (null? remaining))
               (sym (if at-eof 'eof (token-symbol (car remaining))))
               (val (if at-eof #f (token-value (car remaining))))
               (action (table-lookup pt cur-state sym)))
          (cond
            ((not action) (error "lr-parse: unexpected token" sym))
            ((eq? (car action) 'shift) (loop (cons (cons (cadr action) val) stack) (cdr remaining)))
            ((eq? (car action) 'accept) (cdr (car stack)))
            ((eq? (car action) 'reduce)
             (let* ((rule (vector-ref (table-rules pt) (cadr action)))
                    (n (length (rule-rhs rule)))
                    (popped (take-n stack n))
                    (arg-values (reverse (map cdr popped)))
                    (rest-stack (drop-n stack n))
                    (goto-entry (table-lookup pt (car (car rest-stack)) (rule-lhs rule)))
                    (result (apply (rule-action rule) arg-values)))
               (loop (cons (cons (cadr goto-entry) result) rest-stack) remaining)))
            (else (error "lr-parse: internal error, unknown action" action))))))))
