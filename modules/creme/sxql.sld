;; ===========================================================================
;; (creme sxql): SQL statement builder DSL (ported from Common Lisp's sxql)
;;
;; File-based library (resolved via library_search_path, same mechanism a
;; user's own .sld libraries use) rather than compiled into the interpreter
;; binary, since it's pure data transformation with no opaque foreign
;; object, stateful handle, or third-party Crystal library involved.
;;
;; Statements/clauses/conditions are plain Scheme data: tagged lists whose
;; first element is a symbol naming the tag (e.g. (= age 18), (and c1 c2)); a
;; built statement is an alist of (key . value) pairs -- no new opaque value
;; type, so builder values print/inspect naturally, mirroring how json.cr
;; uses alists for object-shaped data.
;;
;; The one rendering rule that matters: a symbol operand renders as raw SQL
;; text (an identifier); anything else becomes a bound `?` parameter. DDL
;; column name/type/default text is a separate always-raw-text path, since
;; SQL has no syntax for binding an identifier or a type.
;;
;; Every export here is `sxql-`-prefixed (sxql-select, sxql-where, sxql-and,
;; sxql-=, sxql-+, ...) even where the bare name (=, <, +, and, or, not,
;; when, else, case, select, ...) would otherwise read naturally as SQL-DSL
;; vocabulary, so importing (creme sxql) can't collide with (scheme base)'s
;; own special forms/builtins.
;;
;; sxql-select! is a defmacro (this interpreter's non-hygienic macro form);
;; its expansion emits a literal (sxql-run conn 'stmt) call resolved via
;; ordinary lexical lookup at the macro's USE site, not this library's own
;; env -- so any caller using sxql-select! must also have sxql-run visible
;; (either via this same (import (creme sxql)), which exports both, or
;; already imported transitively).
;; ===========================================================================

(define-library (creme sxql)
  (export
    sxql-!=
    sxql-*
    sxql-+
    sxql--
    sxql-/
    sxql-<
    sxql-<=
    sxql-=
    sxql->
    sxql->=
    sxql-add-column
    sxql-alist-set
    sxql-alter-table
    sxql-and
    sxql-apply-clause
    sxql-apply-createindex-opts
    sxql-apply-dropindex-opts
    sxql-apply-droptable-opts
    sxql-apply-table-opt
    sxql-apply-table-opts
    sxql-as
    sxql-asc
    sxql-autoincrement
    sxql-case
    sxql-column
    sxql-compile-call
    sxql-compile-tree
    sxql-create-index
    sxql-create-table
    sxql-default
    sxql-delete-from
    sxql-desc
    sxql-distinct
    sxql-drop-column
    sxql-drop-index
    sxql-drop-table
    sxql-else
    sxql-escape-quotes
    sxql-escape-quotes-chars
    sxql-exists
    sxql-fold
    sxql-from
    sxql-get
    sxql-get-list
    sxql-group-by
    sxql-having
    sxql-if-exists
    sxql-if-not-exists
    sxql-in
    sxql-insert-into
    sxql-is-not-null
    sxql-is-null
    sxql-join
    sxql-join-strings
    sxql-left-join
    sxql-like
    sxql-limit
    sxql-lookup
    sxql-node
    sxql-not
    sxql-not-in
    sxql-not-null
    sxql-offset
    sxql-on-conflict-do-nothing
    sxql-on-conflict-do-update
    sxql-or
    sxql-order-by
    sxql-pairs
    sxql-params-add!
    sxql-payload
    sxql-primary-key
    sxql-raw
    sxql-rename-column
    sxql-rename-to
    sxql-render-alter-table
    sxql-render-case
    sxql-render-column-constraint
    sxql-render-column-def
    sxql-render-create-index
    sxql-render-create-table
    sxql-render-delete
    sxql-render-drop-index
    sxql-render-drop-table
    sxql-render-expr
    sxql-render-insert
    sxql-render-joins
    sxql-render-literal
    sxql-render-on-conflict
    sxql-render-operator
    sxql-render-order-item
    sxql-render-select
    sxql-render-statement
    sxql-render-union
    sxql-render-update
    sxql-require
    sxql-returning
    sxql-row->kw-alist
    sxql-run
    sxql-select
    sxql-select!
    sxql-set=
    sxql-strip-colon
    sxql-tag
    sxql-type
    sxql-union
    sxql-union-all
    sxql-unique
    sxql-update
    sxql-when
    sxql-where
    sxql-yield
  )
  (import (scheme base) (scheme write) (scheme cxr) (creme sql))
  (begin
    ;; SRFI-1's reduce isn't an R7RS base export, so this library defines
    ;; its own local copy for the one fold it needs internally.
    (define (sxql-reduce f init lst)
      (if (null? lst) init (sxql-reduce f (f init (car lst)) (cdr lst))))

    ;; ---- Tagged-node / alist helpers ----
    
    (define (sxql-node tag payload) (cons tag payload))
    
    (define (sxql-tag v)
      (if (and (pair? v) (symbol? (car v))) (car v) #f))
    
    (define (sxql-payload v) (cdr v))
    
    (define (sxql-get-list alist key)
      (cond ((null? alist) #f)
            ((eq? (caar alist) key) (cdar alist))
            (else (sxql-get-list (cdr alist) key))))
    
    (define (sxql-get stmt key)
      (if (pair? stmt) (sxql-get-list stmt key) #f))
    
    (define (sxql-require stmt key who)
      (let ((v (sxql-get stmt key)))
        (if (eq? v #f)
            (error (string-append who ": missing '" (symbol->string key) "'"))
            v)))
    
    (define (sxql-type stmt)
      (let ((t (sxql-get stmt 'type)))
        (if (eq? t #f)
            (error "sxql-yield: expected a built statement")
            (if (symbol? t) t (error "sxql-yield: expected a built statement")))))
    
    (define (sxql-alist-set alist key val)
      (cond ((null? alist) (list (cons key val)))
            ((eq? (caar alist) key) (cons (cons key val) (cdr alist)))
            (else (cons (car alist) (sxql-alist-set (cdr alist) key val)))))
    
    (define (sxql-join-strings sep strs)
      (if (null? strs)
          ""
          (sxql-reduce (lambda (acc s) (string-append acc sep s)) (car strs) (cdr strs))))
    
    (define (sxql-escape-quotes-chars chars)
      (cond ((null? chars) '())
            ((equal? (car chars) #\')
             (cons #\' (cons #\' (sxql-escape-quotes-chars (cdr chars)))))
            (else (cons (car chars) (sxql-escape-quotes-chars (cdr chars))))))
    
    (define (sxql-escape-quotes s) (list->string (sxql-escape-quotes-chars (string->list s))))
    
    (define (sxql-params-add! box v) (vector-set! box 0 (append (vector-ref box 0) (list v))))
    
    ;; ---- Clause folding: sxql-from/where/order-by/... into a statement's
    ;; accumulator alist. Repeated where/having AND-compose; repeated
    ;; order-by/group-by append; joins accumulate in call order.
    
    (define (sxql-fold h clauses who)
      (if (null? clauses)
          h
          (sxql-fold (sxql-apply-clause h (car clauses) who) (cdr clauses) who)))
    
    (define (sxql-apply-clause h clause who)
      (let ((tag (sxql-tag clause)))
        (if (eq? tag #f)
            (error (string-append who ": expected a clause"))
            (let ((payload (sxql-payload clause)))
              (cond
                ((eq? tag 'from) (sxql-alist-set h 'from (car payload)))
                ((or (eq? tag 'where) (eq? tag 'having))
                 (let ((existing (sxql-get h tag)))
                   (sxql-alist-set h tag (if existing (sxql-node 'and (list existing (car payload))) (car payload)))))
                ((or (eq? tag 'order-by) (eq? tag 'group-by))
                 (sxql-alist-set h tag (append (or (sxql-get h tag) '()) payload)))
                ((or (eq? tag 'limit) (eq? tag 'offset))
                 (sxql-alist-set h tag (car payload)))
                ((or (eq? tag 'join) (eq? tag 'left-join))
                 (let ((kind (if (eq? tag 'join) "INNER" "LEFT")))
                   (sxql-alist-set h 'joins (append (or (sxql-get h 'joins) '())
                                                     (list (sxql-node 'join (list kind (car payload) (cadr payload))))))))
                ((eq? tag 'distinct) (sxql-alist-set h 'distinct #t))
                ((eq? tag 'set) (sxql-alist-set h 'set payload))
                ((eq? tag 'do-nothing) (sxql-alist-set h 'on-conflict (sxql-node 'do-nothing payload)))
                ((eq? tag 'do-update) (sxql-alist-set h 'on-conflict (sxql-node 'do-update payload)))
                ((eq? tag 'returning) (sxql-alist-set h 'returning payload))
                (else (error (string-append who ": unrecognized clause '" (symbol->string tag) "'"))))))))
    
    ;; ---- Statement builders ----
    
    (define (sxql-select fields . clauses)
      (sxql-fold (list (cons 'type 'select) (cons 'fields fields)) clauses "sxql-select"))
    
    (define (sxql-insert-into table . clauses)
      (sxql-fold (list (cons 'type 'insert-into) (cons 'table table)) clauses "sxql-insert-into"))
    
    (define (sxql-update table . clauses)
      (sxql-fold (list (cons 'type 'update) (cons 'table table)) clauses "sxql-update"))
    
    (define (sxql-delete-from table . clauses)
      (sxql-fold (list (cons 'type 'delete-from) (cons 'table table)) clauses "sxql-delete-from"))
    
    (define (sxql-union . stmts) (list (cons 'type 'union) (cons 'kind "UNION") (cons 'statements stmts)))
    (define (sxql-union-all . stmts) (list (cons 'type 'union) (cons 'kind "UNION ALL") (cons 'statements stmts)))
    
    ;; ---- Query clauses ----
    
    (define (sxql-from x) (sxql-node 'from (list x)))
    (define (sxql-where c) (sxql-node 'where (list c)))
    (define (sxql-having c) (sxql-node 'having (list c)))
    (define (sxql-order-by . items) (sxql-node 'order-by items))
    (define (sxql-group-by . items) (sxql-node 'group-by items))
    (define (sxql-limit n) (sxql-node 'limit (list n)))
    (define (sxql-offset n) (sxql-node 'offset (list n)))
    (define (sxql-join tbl c) (sxql-node 'join (list tbl c)))
    (define (sxql-left-join tbl c) (sxql-node 'left-join (list tbl c)))
    (define (sxql-distinct) (sxql-node 'distinct '()))
    (define (sxql-asc x) (sxql-node 'asc (list x)))
    (define (sxql-desc x) (sxql-node 'desc (list x)))
    
    ;; ---- Write clauses ----
    
    (define (sxql-pairs args)
      (if (null? args) '() (cons (cons (car args) (cadr args)) (sxql-pairs (cddr args)))))
    
    (define (sxql-set= . args)
      (if (odd? (length args))
          (error "sxql-set=: expected an even number of column/value arguments")
          (sxql-node 'set (sxql-pairs args))))
    
    (define (sxql-on-conflict-do-nothing . cols) (sxql-node 'do-nothing cols))
    (define (sxql-on-conflict-do-update targets set-node) (sxql-node 'do-update (list targets set-node)))
    (define (sxql-returning . cols) (sxql-node 'returning cols))
    
    ;; ---- Condition / expression operators ----
    
    (define (sxql-= a b) (sxql-node '= (list a b)))
    (define (sxql-!= a b) (sxql-node '!= (list a b)))
    (define (sxql-< a b) (sxql-node '< (list a b)))
    (define (sxql-> a b) (sxql-node '> (list a b)))
    (define (sxql-<= a b) (sxql-node '<= (list a b)))
    (define (sxql->= a b) (sxql-node '>= (list a b)))
    (define (sxql-+ a b) (sxql-node '+ (list a b)))
    (define (sxql-- a b) (sxql-node '- (list a b)))
    (define (sxql-* a b) (sxql-node '* (list a b)))
    (define (sxql-/ a b) (sxql-node '/ (list a b)))
    (define (sxql-% a b) (sxql-node '% (list a b)))
    (define (sxql-like a b) (sxql-node 'like (list a b)))
    (define (sxql-and . conds) (sxql-node 'and conds))
    (define (sxql-or . conds) (sxql-node 'or conds))
    (define (sxql-not c) (sxql-node 'not (list c)))
    (define (sxql-in col vals) (sxql-node 'in (list col vals)))
    (define (sxql-not-in col vals) (sxql-node 'not-in (list col vals)))
    (define (sxql-is-null x) (sxql-node 'is-null (list x)))
    (define (sxql-is-not-null x) (sxql-node 'is-not-null (list x)))
    (define (sxql-as expr alias-name) (sxql-node 'as (list expr alias-name)))
    (define (sxql-exists stmt) (sxql-node 'exists (list stmt)))
    (define (sxql-case . clauses) (sxql-node 'case clauses))
    (define (sxql-when cond val) (sxql-node 'when (list cond val)))
    (define (sxql-else val) (sxql-node 'else (list val)))
    (define (sxql-raw text) (sxql-node 'raw (list text)))
    
    ;; ---- DDL: create-table / column constraints ----
    
    (define (sxql-column name type . constraints) (sxql-node 'column (cons name (cons type constraints))))
    (define (sxql-primary-key) (sxql-node 'primary-key '()))
    (define (sxql-not-null) (sxql-node 'not-null '()))
    (define (sxql-unique) (sxql-node 'unique '()))
    (define (sxql-autoincrement) (sxql-node 'autoincrement '()))
    (define (sxql-default v) (sxql-node 'default (list v)))
    (define (sxql-if-not-exists) (sxql-node 'if-not-exists '()))
    (define (sxql-if-exists) (sxql-node 'if-exists '()))
    
    (define (sxql-apply-table-opt h opt who)
      (let ((tag (sxql-tag opt)))
        (cond ((eq? tag 'if-not-exists) (sxql-alist-set h 'if-not-exists #t))
              (else (error (string-append who ": unknown option"))))))
    
    (define (sxql-apply-table-opts h opts who)
      (if (null? opts)
          h
          (sxql-apply-table-opts (sxql-apply-table-opt h (car opts) who) (cdr opts) who)))
    
    (define (sxql-create-table table columns . opts)
      (sxql-apply-table-opts (list (cons 'type 'create-table) (cons 'table table) (cons 'columns columns))
                              opts "sxql-create-table"))
    
    ;; ---- DDL: drop-table / alter-table ----
    
    (define (sxql-apply-droptable-opts h opts)
      (if (null? opts)
          h
          (let ((tag (sxql-tag (car opts))))
            (if (eq? tag 'if-exists)
                (sxql-apply-droptable-opts (sxql-alist-set h 'if-exists #t) (cdr opts))
                (error "sxql-drop-table: unknown option")))))
    
    (define (sxql-drop-table table . opts)
      (sxql-apply-droptable-opts (list (cons 'type 'drop-table) (cons 'table table)) opts))
    
    (define (sxql-rename-to name) (sxql-node 'rename-to (list name)))
    (define (sxql-add-column col) (sxql-node 'add-column (list col)))
    (define (sxql-rename-column old new) (sxql-node 'rename-column (list old new)))
    (define (sxql-drop-column name) (sxql-node 'drop-column (list name)))
    
    (define (sxql-alter-table table clause) (list (cons 'type 'alter-table) (cons 'table table) (cons 'clause clause)))
    
    ;; ---- DDL: create-index / drop-index ----
    
    (define (sxql-apply-createindex-opts h opts)
      (if (null? opts)
          h
          (let ((tag (sxql-tag (car opts))))
            (cond ((eq? tag 'unique) (sxql-apply-createindex-opts (sxql-alist-set h 'unique #t) (cdr opts)))
                  ((eq? tag 'if-not-exists) (sxql-apply-createindex-opts (sxql-alist-set h 'if-not-exists #t) (cdr opts)))
                  (else (error "sxql-create-index: unknown option"))))))
    
    (define (sxql-create-index name table columns . opts)
      (sxql-apply-createindex-opts
        (list (cons 'type 'create-index) (cons 'name name) (cons 'table table) (cons 'columns columns))
        opts))
    
    (define (sxql-apply-dropindex-opts h opts)
      (if (null? opts)
          h
          (let ((tag (sxql-tag (car opts))))
            (if (eq? tag 'if-exists)
                (sxql-apply-dropindex-opts (sxql-alist-set h 'if-exists #t) (cdr opts))
                (error "sxql-drop-index: unknown option")))))
    
    (define (sxql-drop-index name . opts)
      (sxql-apply-dropindex-opts (list (cons 'type 'drop-index) (cons 'name name)) opts))
    
    ;; ---- Rendering: statement dispatch ----
    
    (define (sxql-render-statement stmt box)
      (let ((type (sxql-type stmt)))
        (cond
          ((eq? type 'select) (sxql-render-select stmt box))
          ((eq? type 'insert-into) (sxql-render-insert stmt box))
          ((eq? type 'update) (sxql-render-update stmt box))
          ((eq? type 'delete-from) (sxql-render-delete stmt box))
          ((eq? type 'union) (sxql-render-union stmt box))
          ((eq? type 'create-table) (sxql-render-create-table stmt))
          ((eq? type 'drop-table) (sxql-render-drop-table stmt))
          ((eq? type 'alter-table) (sxql-render-alter-table stmt))
          ((eq? type 'create-index) (sxql-render-create-index stmt))
          ((eq? type 'drop-index) (sxql-render-drop-index stmt))
          (else (error (string-append "sxql-yield: unknown statement type '" (symbol->string type) "'"))))))
    
    (define (sxql-render-order-item o box)
      (let ((tag (sxql-tag o)))
        (cond ((eq? tag 'asc) (string-append (sxql-render-expr (car (sxql-payload o)) box) " ASC"))
              ((eq? tag 'desc) (string-append (sxql-render-expr (car (sxql-payload o)) box) " DESC"))
              (else (sxql-render-expr o box)))))
    
    (define (sxql-render-joins joins box)
      (apply string-append
        (map (lambda (j)
               (let ((jp (sxql-payload j)))
                 (string-append " " (car jp) " JOIN " (sxql-render-expr (cadr jp) box) " ON " (sxql-render-expr (caddr jp) box))))
             joins)))
    
    (define (sxql-render-select stmt box)
      (let* ((fields (sxql-require stmt 'fields "sxql-yield"))
             (distinct? (sxql-get stmt 'distinct))
             (fields-sql (sxql-join-strings ", " (map (lambda (f) (sxql-render-expr f box)) fields)))
             (from (sxql-get stmt 'from))
             (joins (sxql-get stmt 'joins))
             (where (sxql-get stmt 'where))
             (group-by (sxql-get stmt 'group-by))
             (having (sxql-get stmt 'having))
             (order-by (sxql-get stmt 'order-by))
             (limit (sxql-get stmt 'limit))
             (offset (sxql-get stmt 'offset)))
        (string-append
          "SELECT "
          (if distinct? "DISTINCT " "")
          fields-sql
          (if from (string-append " FROM " (sxql-render-expr from box)) "")
          (if joins (sxql-render-joins joins box) "")
          (if where (string-append " WHERE " (sxql-render-expr where box)) "")
          (if group-by (string-append " GROUP BY " (sxql-join-strings ", " (map (lambda (c) (sxql-render-expr c box)) group-by))) "")
          (if having (string-append " HAVING " (sxql-render-expr having box)) "")
          (if order-by (string-append " ORDER BY " (sxql-join-strings ", " (map (lambda (i) (sxql-render-order-item i box)) order-by))) "")
          (if limit (string-append " LIMIT " (sxql-render-expr limit box)) "")
          (if offset (string-append " OFFSET " (sxql-render-expr offset box)) ""))))
    
    (define (sxql-render-on-conflict node box)
      (let ((tag (sxql-tag node)) (payload (sxql-payload node)))
        (cond
          ((eq? tag 'do-nothing)
           (if (null? payload)
               "ON CONFLICT DO NOTHING"
               (string-append "ON CONFLICT (" (sxql-join-strings ", " (map (lambda (c) (sxql-render-expr c box)) payload)) ") DO NOTHING")))
          ((eq? tag 'do-update)
           (let* ((target-cols (sxql-join-strings ", " (map (lambda (c) (sxql-render-expr c box)) (car payload))))
                  (set-pairs (sxql-payload (cadr payload)))
                  (assigns (sxql-join-strings ", "
                             (map (lambda (pair) (string-append (symbol->string (car pair)) " = " (sxql-render-expr (cdr pair) box)))
                                  set-pairs))))
             (string-append "ON CONFLICT (" target-cols ") DO UPDATE SET " assigns)))
          (else (error "sxql-yield: unknown on-conflict kind")))))
    
    (define (sxql-render-insert stmt box)
      (let* ((table (sxql-require stmt 'table "sxql-yield"))
             (set-node (or (sxql-get stmt 'set) (error "sxql-yield: insert-into requires sxql-set=")))
             (cols (sxql-join-strings ", " (map (lambda (pair) (symbol->string (car pair))) set-node)))
             (placeholders (sxql-join-strings ", " (map (lambda (pair) (sxql-render-expr (cdr pair) box)) set-node)))
             (table-sql (sxql-render-expr table box))
             (oc (sxql-get stmt 'on-conflict))
             (returning (sxql-get stmt 'returning)))
        (string-append
          "INSERT INTO " table-sql " (" cols ") VALUES (" placeholders ")"
          (if oc (string-append " " (sxql-render-on-conflict oc box)) "")
          (if returning (string-append " RETURNING " (sxql-join-strings ", " (map (lambda (c) (sxql-render-expr c box)) returning))) ""))))
    
    (define (sxql-render-update stmt box)
      (let* ((table (sxql-require stmt 'table "sxql-yield"))
             (set-node (or (sxql-get stmt 'set) (error "sxql-yield: update requires sxql-set=")))
             (assigns (sxql-join-strings ", "
                        (map (lambda (pair) (string-append (symbol->string (car pair)) " = " (sxql-render-expr (cdr pair) box)))
                             set-node)))
             (table-sql (sxql-render-expr table box))
             (where (sxql-get stmt 'where))
             (returning (sxql-get stmt 'returning)))
        (string-append
          "UPDATE " table-sql " SET " assigns
          (if where (string-append " WHERE " (sxql-render-expr where box)) "")
          (if returning (string-append " RETURNING " (sxql-join-strings ", " (map (lambda (c) (sxql-render-expr c box)) returning))) ""))))
    
    (define (sxql-render-delete stmt box)
      (let* ((table (sxql-require stmt 'table "sxql-yield"))
             (table-sql (sxql-render-expr table box))
             (where (sxql-get stmt 'where))
             (returning (sxql-get stmt 'returning)))
        (string-append
          "DELETE FROM " table-sql
          (if where (string-append " WHERE " (sxql-render-expr where box)) "")
          (if returning (string-append " RETURNING " (sxql-join-strings ", " (map (lambda (c) (sxql-render-expr c box)) returning))) ""))))
    
    (define (sxql-render-union stmt box)
      (let* ((kind (sxql-require stmt 'kind "sxql-yield"))
             (stmts (sxql-require stmt 'statements "sxql-yield")))
        (sxql-join-strings (string-append " " kind " ") (map (lambda (s) (sxql-render-statement s box)) stmts))))
    
    ;; ---- Rendering: DDL (always raw text, never parameterized) ----
    
    (define (sxql-render-column-constraint node)
      (let ((tag (sxql-tag node)))
        (cond ((eq? tag 'primary-key) "PRIMARY KEY")
              ((eq? tag 'not-null) "NOT NULL")
              ((eq? tag 'unique) "UNIQUE")
              ((eq? tag 'autoincrement) "AUTOINCREMENT")
              ((eq? tag 'default) (string-append "DEFAULT " (sxql-render-literal (car (sxql-payload node)))))
              (else (error "sxql-column: unknown constraint")))))
    
    (define (sxql-render-column-def node)
      (let* ((payload (sxql-payload node))
             (name (symbol->string (car payload)))
             (type (cadr payload))
             (constraints (map sxql-render-column-constraint (cddr payload))))
        (sxql-join-strings " " (cons name (cons type constraints)))))
    
    (define (sxql-render-literal v)
      (cond ((string? v) (string-append "'" (sxql-escape-quotes v) "'"))
            ((number? v) (number->string v))
            ((boolean? v) (if v "1" "0"))
            ((null? v) "NULL")
            ((symbol? v) (symbol->string v))
            (else (error "sxql-column: cannot use value as a DEFAULT literal"))))
    
    (define (sxql-render-create-table stmt)
      (let* ((table (symbol->string (sxql-require stmt 'table "sxql-yield")))
             (columns (sxql-require stmt 'columns "sxql-yield"))
             (if-not-exists (if (sxql-get stmt 'if-not-exists) "IF NOT EXISTS " "")))
        (string-append "CREATE TABLE " if-not-exists table " (" (sxql-join-strings ", " (map sxql-render-column-def columns)) ")")))
    
    (define (sxql-render-drop-table stmt)
      (let* ((table (symbol->string (sxql-require stmt 'table "sxql-yield")))
             (if-exists (if (sxql-get stmt 'if-exists) "IF EXISTS " "")))
        (string-append "DROP TABLE " if-exists table)))
    
    (define (sxql-render-alter-table stmt)
      (let* ((table (symbol->string (sxql-require stmt 'table "sxql-yield")))
             (clause (sxql-require stmt 'clause "sxql-yield"))
             (tag (sxql-tag clause))
             (payload (sxql-payload clause))
             (action
               (cond ((eq? tag 'rename-to) (string-append "RENAME TO " (symbol->string (car payload))))
                     ((eq? tag 'add-column) (string-append "ADD COLUMN " (sxql-render-column-def (car payload))))
                     ((eq? tag 'rename-column)
                      (string-append "RENAME COLUMN " (symbol->string (car payload)) " TO " (symbol->string (cadr payload))))
                     ((eq? tag 'drop-column) (string-append "DROP COLUMN " (symbol->string (car payload))))
                     (else (error "sxql-alter-table: unknown clause")))))
        (string-append "ALTER TABLE " table " " action)))
    
    (define (sxql-render-create-index stmt)
      (let* ((name (symbol->string (sxql-require stmt 'name "sxql-yield")))
             (table (symbol->string (sxql-require stmt 'table "sxql-yield")))
             (cols (sxql-join-strings ", " (map symbol->string (sxql-require stmt 'columns "sxql-yield"))))
             (unique-str (if (sxql-get stmt 'unique) "UNIQUE " ""))
             (if-not-exists (if (sxql-get stmt 'if-not-exists) "IF NOT EXISTS " "")))
        (string-append "CREATE " unique-str "INDEX " if-not-exists name " ON " table " (" cols ")")))
    
    (define (sxql-render-drop-index stmt)
      (let* ((name (symbol->string (sxql-require stmt 'name "sxql-yield")))
             (if-exists (if (sxql-get stmt 'if-exists) "IF EXISTS " "")))
        (string-append "DROP INDEX " if-exists name)))
    
    ;; ---- Rendering: expressions/conditions ----
    ;;
    ;; The core rule: a symbol operand is a raw identifier; anything else is a
    ;; bound parameter. Recognized operator tags recurse; an unrecognized plain
    ;; list is treated as a value list.
    
    (define (sxql-render-expr node box)
      (cond
        ((symbol? node) (symbol->string node))
        ((pair? node)
         (let ((tag (sxql-tag node)))
           (if (eq? tag #f)
               (string-append "(" (sxql-join-strings ", " (map (lambda (v) (sxql-render-expr v box)) node)) ")")
               (sxql-render-operator tag (sxql-payload node) box))))
        (else (sxql-params-add! box node) "?")))
    
    (define (sxql-render-case payload box)
      (sxql-join-strings " "
        (append (list "CASE")
                (append
                  (map (lambda (clause)
                         (let ((tag (sxql-tag clause)) (cp (sxql-payload clause)))
                           (cond ((eq? tag 'when) (string-append "WHEN " (sxql-render-expr (car cp) box) " THEN " (sxql-render-expr (cadr cp) box)))
                                 ((eq? tag 'else) (string-append "ELSE " (sxql-render-expr (car cp) box)))
                                 (else (error "sxql-case: expected sxql-when/sxql-else")))))
                       payload)
                  (list "END")))))
    
    (define (sxql-render-operator tag payload box)
      (cond
        ((member tag '(= != < > <= >= + - * / %))
         (string-append (sxql-render-expr (car payload) box) " " (symbol->string tag) " " (sxql-render-expr (cadr payload) box)))
        ((eq? tag 'like) (string-append (sxql-render-expr (car payload) box) " LIKE " (sxql-render-expr (cadr payload) box)))
        ((eq? tag 'and) (string-append "(" (sxql-join-strings " AND " (map (lambda (c) (sxql-render-expr c box)) payload)) ")"))
        ((eq? tag 'or) (string-append "(" (sxql-join-strings " OR " (map (lambda (c) (sxql-render-expr c box)) payload)) ")"))
        ((eq? tag 'not) (string-append "NOT (" (sxql-render-expr (car payload) box) ")"))
        ((or (eq? tag 'in) (eq? tag 'not-in))
         (let ((col (sxql-render-expr (car payload) box))
               (vals (sxql-join-strings ", " (map (lambda (v) (sxql-render-expr v box)) (cadr payload)))))
           (string-append col " " (if (eq? tag 'in) "IN" "NOT IN") " (" vals ")")))
        ((eq? tag 'is-null) (string-append (sxql-render-expr (car payload) box) " IS NULL"))
        ((eq? tag 'is-not-null) (string-append (sxql-render-expr (car payload) box) " IS NOT NULL"))
        ((eq? tag 'as) (string-append (sxql-render-expr (car payload) box) " AS " (sxql-render-expr (cadr payload) box)))
        ((eq? tag 'exists) (string-append "EXISTS (" (sxql-render-statement (car payload) box) ")"))
        ((eq? tag 'case) (sxql-render-case payload box))
        ((eq? tag 'raw) (car payload))
        (else (error (string-append "sxql-yield: unknown operator '" (symbol->string tag) "'")))))
    
    ;; ---- Render ----
    
    (define (sxql-yield stmt)
      (let ((box (vector '())))
        (let ((sql (sxql-render-statement stmt box)))
          (list sql (vector-ref box 0)))))
    
    ;; ===========================================================================
    ;; sxql-select!: a macro-based, connection-executing entry point on top of
    ;; the builder above, mirroring the original CL sxql keyword-tree syntax,
    ;; e.g.
    ;;
    ;;   (sxql-select! conn (:title :author :year)
    ;;     (from :books)
    ;;     (where (:and (:>= :year 1995) (:< :year 2010)))
    ;;     (order-by (:desc :year)))
    ;;
    ;; sxql-select! is a macro: its fields/clause arguments are raw, unevaluated
    ;; s-expressions (never looked up or called), which sxql-compile-tree walks
    ;; and turns into calls against the *existing* builder functions above --
    ;; nothing about the builder/renderer changes. Only `conn` is an ordinary,
    ;; evaluated argument (spliced into the expansion as-is, so it evaluates
    ;; normally, once, when the expanded code runs) -- there is no "current
    ;; connection" box or other shared/global state.
    ;; ===========================================================================
    
    ;; A leading ':' is stripped so both :year and year identify the same raw
    ;; SQL identifier once rendered (sxql-render-expr already treats any symbol
    ;; as raw identifier text via symbol->string).
    (define (sxql-strip-colon sym)
      (let ((s (symbol->string sym)))
        (if (equal? s "")
            sym
            (if (equal? (substring s 0 1) ":")
                (string->symbol (substring s 1 (string-length s)))
                sym))))
    
    ;; Fetches the existing builder for a (stripped) tag, e.g. tag 'from ->
    ;; the function bound to sxql-from. Since a define-library body is its
    ;; own isolated Env (not @global), and `eval` in this interpreter always
    ;; runs against @global (no first-class environment type to target this
    ;; library's own Env instead), the old string->symbol + eval trick can no
    ;; longer resolve sxql-*-prefixed names -- replaced with an explicit
    ;; tag -> builder alist built once from the actual bindings in scope
    ;; here, covering every DSL-usable builder (excludes internal-only
    ;; helpers and the sxql-render-* functions, which are never a user-
    ;; written tag).
    (define sxql-dispatch-table
      (list
        (cons (quote !=) sxql-!=)
        (cons (quote *) sxql-*)
        (cons (quote +) sxql-+)
        (cons (quote -) sxql--)
        (cons (quote /) sxql-/)
        (cons (quote <) sxql-<)
        (cons (quote <=) sxql-<=)
        (cons (quote =) sxql-=)
        (cons (quote >) sxql->)
        (cons (quote >=) sxql->=)
        (cons (quote add-column) sxql-add-column)
        (cons (quote alter-table) sxql-alter-table)
        (cons (quote and) sxql-and)
        (cons (quote as) sxql-as)
        (cons (quote asc) sxql-asc)
        (cons (quote autoincrement) sxql-autoincrement)
        (cons (quote case) sxql-case)
        (cons (quote column) sxql-column)
        (cons (quote create-index) sxql-create-index)
        (cons (quote create-table) sxql-create-table)
        (cons (quote default) sxql-default)
        (cons (quote delete-from) sxql-delete-from)
        (cons (quote desc) sxql-desc)
        (cons (quote distinct) sxql-distinct)
        (cons (quote drop-column) sxql-drop-column)
        (cons (quote drop-index) sxql-drop-index)
        (cons (quote drop-table) sxql-drop-table)
        (cons (quote else) sxql-else)
        (cons (quote exists) sxql-exists)
        (cons (quote from) sxql-from)
        (cons (quote group-by) sxql-group-by)
        (cons (quote having) sxql-having)
        (cons (quote if-exists) sxql-if-exists)
        (cons (quote if-not-exists) sxql-if-not-exists)
        (cons (quote in) sxql-in)
        (cons (quote insert-into) sxql-insert-into)
        (cons (quote is-not-null) sxql-is-not-null)
        (cons (quote is-null) sxql-is-null)
        (cons (quote join) sxql-join)
        (cons (quote left-join) sxql-left-join)
        (cons (quote like) sxql-like)
        (cons (quote limit) sxql-limit)
        (cons (quote not) sxql-not)
        (cons (quote not-in) sxql-not-in)
        (cons (quote not-null) sxql-not-null)
        (cons (quote offset) sxql-offset)
        (cons (quote on-conflict-do-nothing) sxql-on-conflict-do-nothing)
        (cons (quote on-conflict-do-update) sxql-on-conflict-do-update)
        (cons (quote or) sxql-or)
        (cons (quote order-by) sxql-order-by)
        (cons (quote pairs) sxql-pairs)
        (cons (quote primary-key) sxql-primary-key)
        (cons (quote raw) sxql-raw)
        (cons (quote rename-column) sxql-rename-column)
        (cons (quote rename-to) sxql-rename-to)
        (cons (quote returning) sxql-returning)
        (cons (quote select) sxql-select)
        (cons (quote set=) sxql-set=)
        (cons (quote union) sxql-union)
        (cons (quote union-all) sxql-union-all)
        (cons (quote unique) sxql-unique)
        (cons (quote update) sxql-update)
        (cons (quote when) sxql-when)
        (cons (quote where) sxql-where)
        ))

    (define (sxql-lookup tag)
      (let ((entry (assq tag sxql-dispatch-table)))
        (if entry (cdr entry) (error (string-append "sxql: unknown operator '" (symbol->string tag) "'")))))
    
    ;; in/not-in's second operand is a literal list of values (e.g. ("a" "b")),
    ;; not a nested tagged expression -- compile its elements individually
    ;; instead of recursing into it as an operator call.
    (define (sxql-compile-call tag args)
      (if (or (eq? tag 'in) (eq? tag 'not-in))
          (apply (sxql-lookup tag) (list (sxql-compile-tree (car args)) (map sxql-compile-tree (cadr args))))
          (apply (sxql-lookup tag) (map sxql-compile-tree args))))
    
    ;; Recursively compiles a raw, unevaluated s-expression from a
    ;; sxql-select! clause/field position into the same tagged-node/statement
    ;; shapes the existing builder functions above already produce. A bare
    ;; symbol (:year or year) becomes a plain identifier symbol; a list (tag
    ;; arg...) — tag written either as `from` or `:from` — strips the tag's
    ;; leading ':', compiles its args, and calls the existing builder of the
    ;; same name, e.g. (from :books) -> (sxql-from 'books). Anything else (a
    ;; literal number/string) passes through unchanged.
    (define (sxql-compile-tree form)
      (cond
        ((symbol? form) (sxql-strip-colon form))
        ((pair? form) (sxql-compile-call (sxql-strip-colon (car form)) (cdr form)))
        (else form)))
    
    ;; Converts one sql-query row (an alist of (SchemeStr-column-name . value),
    ;; per src/scheme/modules/sql.cr) into an alist of (keyword-symbol . value)
    ;; pairs, e.g. (("title" . "...")) -> ((:title . "...")).
    (define (sxql-row->kw-alist row)
      (map (lambda (pair) (cons (string->symbol (string-append ":" (car pair))) (cdr pair))) row))

    ;; Builds one row's (:col . value) alist reusing the pre-interned `keys`
    ;; (the :col symbols) instead of re-deriving them from the column names
    ;; per row -- the values come from `row` positionally (a SQL result set's
    ;; rows all share the first row's column order).
    (define (sxql-zip-kw-row keys row)
      (if (null? keys)
          '()
          (cons (cons (car keys) (cdar row)) (sxql-zip-kw-row (cdr keys) (cdr row)))))

    ;; Executes an already-built statement against `conn` and returns the
    ;; converted rows. A plain function of its two arguments -- no hidden
    ;; state -- reusing the exact sxql-yield + sql-query call shape. The
    ;; :col keyword symbols are interned ONCE from the first row's column
    ;; names and shared across every row (rather than string-append'd and
    ;; re-interned per cell by sxql-row->kw-alist), since a result set's
    ;; columns are the same for every row.
    (define (sxql-run conn stmt)
      (let* ((yielded (sxql-yield stmt))
             (sql-str (car yielded))
             (params (cadr yielded))
             (rows (vector->list (apply sql-query conn sql-str params))))
        (if (null? rows)
            '()
            (let ((keys (map (lambda (pair) (string->symbol (string-append ":" (car pair)))) (car rows))))
              (map (lambda (row) (sxql-zip-kw-row keys row)) rows)))))
    
    (defmacro sxql-select! (conn fields . clauses)
      (let ((stmt (apply sxql-select (map sxql-compile-tree fields) (map sxql-compile-tree clauses))))
        ;; The expansion below is evaluated back at the macro call site's own
        ;; env (typically the caller's top-level env, not this file's env), so
        ;; `sxql-run` must resolve there too -- but since require now defines
        ;; sxql's exports as ordinary @global bindings (not isolated to this
        ;; file's own env), the bare name `sxql-run` already resolves correctly
        ;; from any calling env that chains up to @global, same as any other
        ;; global binding.
        (list 'sxql-run conn (list 'quote stmt))))
    ))
