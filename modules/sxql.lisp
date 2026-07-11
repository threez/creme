;; ===========================================================================
;; sxql module: SQL statement builder DSL (ported from Common Lisp's sxql)
;;
;; Unlike Crystal-native modules, sxql is pure data transformation with no
;; opaque foreign object, stateful handle, or third-party Crystal library
;; involved -- so it's authored as plain Lisp source and loaded via a
;; file-based (require "...") style mechanism (interp.module_search_path),
;; the same way a user's own file-based modules load, rather than compiled
;; into the interpreter binary. Its Env chains to @global so this source can
;; use car/map/assoc/reduce/string-append/etc. the same way prelude.cr's own
;; definitions do.
;;
;; Statements/clauses/conditions are plain Lisp data: tagged lists whose
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
;; Several exported names here (=, <, +, and, or, not, when, else, case, ...)
;; are ordinary identifiers, not the host special forms/builtins of the same
;; name -- (and ...)/(or ...)/(when ...) are always intercepted by eval_core
;; on the literal symbol name "and"/"or"/"when" before any env lookup, so
;; redefining them here only shadows them for *qualified* access
;; (sxql:and, sxql:when, ...) from outside; bare (and ...)/(or ...) calls
;; inside this file still reach the real special forms. `not`, `=`, `<`,
;; `>`, `<=`, `>=`, `+`, `-`, `*`, `/`, `%` ARE ordinary builtins (not
;; special forms), so redefining them *does* shadow the real ones for any
;; bare call inside this file -- the rendering code below deliberately
;; avoids using them internally (arithmetic/negation needs are expressed via
;; recursion, cond, and eq?/equal? instead).
;; ===========================================================================

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
        (error "sxql:yield: expected a built statement")
        (if (symbol? t) t (error "sxql:yield: expected a built statement")))))

(define (alist-set alist key val)
  (cond ((null? alist) (list (cons key val)))
        ((eq? (caar alist) key) (cons (cons key val) (cdr alist)))
        (else (cons (car alist) (alist-set (cdr alist) key val)))))

(define (join-strings sep strs)
  (if (null? strs)
      ""
      (reduce (lambda (acc s) (string-append acc sep s)) (car strs) (cdr strs))))

(define (escape-quotes-chars chars)
  (cond ((null? chars) '())
        ((equal? (car chars) #\')
         (cons #\' (cons #\' (escape-quotes-chars (cdr chars)))))
        (else (cons (car chars) (escape-quotes-chars (cdr chars))))))

(define (escape-quotes s) (list->string (escape-quotes-chars (string->list s))))

(define (params-add! box v) (vector-set! box 0 (append (vector-ref box 0) (list v))))

;; ---- Clause folding: sxql:from/where/order-by/... into a statement's
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
            ((eq? tag 'from) (alist-set h 'from (car payload)))
            ((or (eq? tag 'where) (eq? tag 'having))
             (let ((existing (sxql-get h tag)))
               (alist-set h tag (if existing (sxql-node 'and (list existing (car payload))) (car payload)))))
            ((or (eq? tag 'order-by) (eq? tag 'group-by))
             (alist-set h tag (append (or (sxql-get h tag) '()) payload)))
            ((or (eq? tag 'limit) (eq? tag 'offset))
             (alist-set h tag (car payload)))
            ((or (eq? tag 'join) (eq? tag 'left-join))
             (let ((kind (if (eq? tag 'join) "INNER" "LEFT")))
               (alist-set h 'joins (append (or (sxql-get h 'joins) '())
                                            (list (sxql-node 'join (list kind (car payload) (cadr payload))))))))
            ((eq? tag 'distinct) (alist-set h 'distinct #t))
            ((eq? tag 'set) (alist-set h 'set payload))
            ((eq? tag 'do-nothing) (alist-set h 'on-conflict (sxql-node 'do-nothing payload)))
            ((eq? tag 'do-update) (alist-set h 'on-conflict (sxql-node 'do-update payload)))
            ((eq? tag 'returning) (alist-set h 'returning payload))
            (else (error (string-append who ": unrecognized clause '" (symbol->string tag) "'"))))))))

;; ---- Statement builders ----

(define (select fields . clauses)
  (sxql-fold (list (cons 'type 'select) (cons 'fields fields)) clauses "sxql:select"))

(define (insert-into table . clauses)
  (sxql-fold (list (cons 'type 'insert-into) (cons 'table table)) clauses "sxql:insert-into"))

(define (update table . clauses)
  (sxql-fold (list (cons 'type 'update) (cons 'table table)) clauses "sxql:update"))

(define (delete-from table . clauses)
  (sxql-fold (list (cons 'type 'delete-from) (cons 'table table)) clauses "sxql:delete-from"))

(define (union . stmts) (list (cons 'type 'union) (cons 'kind "UNION") (cons 'statements stmts)))
(define (union-all . stmts) (list (cons 'type 'union) (cons 'kind "UNION ALL") (cons 'statements stmts)))

;; ---- Query clauses ----

(define (from x) (sxql-node 'from (list x)))
(define (where c) (sxql-node 'where (list c)))
(define (having c) (sxql-node 'having (list c)))
(define (order-by . items) (sxql-node 'order-by items))
(define (group-by . items) (sxql-node 'group-by items))
(define (limit n) (sxql-node 'limit (list n)))
(define (offset n) (sxql-node 'offset (list n)))
(define (join tbl c) (sxql-node 'join (list tbl c)))
(define (left-join tbl c) (sxql-node 'left-join (list tbl c)))
(define (distinct) (sxql-node 'distinct '()))
(define (asc x) (sxql-node 'asc (list x)))
(define (desc x) (sxql-node 'desc (list x)))

;; ---- Write clauses ----

(define (sxql-pairs args)
  (if (null? args) '() (cons (cons (car args) (cadr args)) (sxql-pairs (cddr args)))))

(define (set= . args)
  (if (odd? (length args))
      (error "sxql:set=: expected an even number of column/value arguments")
      (sxql-node 'set (sxql-pairs args))))

(define (on-conflict-do-nothing . cols) (sxql-node 'do-nothing cols))
(define (on-conflict-do-update targets set-node) (sxql-node 'do-update (list targets set-node)))
(define (returning . cols) (sxql-node 'returning cols))

;; ---- Condition / expression operators ----

(define (= a b) (sxql-node '= (list a b)))
(define (!= a b) (sxql-node '!= (list a b)))
(define (< a b) (sxql-node '< (list a b)))
(define (> a b) (sxql-node '> (list a b)))
(define (<= a b) (sxql-node '<= (list a b)))
(define (>= a b) (sxql-node '>= (list a b)))
(define (+ a b) (sxql-node '+ (list a b)))
(define (- a b) (sxql-node '- (list a b)))
(define (* a b) (sxql-node '* (list a b)))
(define (/ a b) (sxql-node '/ (list a b)))
(define (% a b) (sxql-node '% (list a b)))
(define (like a b) (sxql-node 'like (list a b)))
(define (and . conds) (sxql-node 'and conds))
(define (or . conds) (sxql-node 'or conds))
(define (not c) (sxql-node 'not (list c)))
(define (in col vals) (sxql-node 'in (list col vals)))
(define (not-in col vals) (sxql-node 'not-in (list col vals)))
(define (is-null x) (sxql-node 'is-null (list x)))
(define (is-not-null x) (sxql-node 'is-not-null (list x)))
(define (as expr alias-name) (sxql-node 'as (list expr alias-name)))
(define (exists stmt) (sxql-node 'exists (list stmt)))
(define (case . clauses) (sxql-node 'case clauses))
(define (when cond val) (sxql-node 'when (list cond val)))
(define (else val) (sxql-node 'else (list val)))
(define (raw text) (sxql-node 'raw (list text)))

;; ---- DDL: create-table / column constraints ----

(define (column name type . constraints) (sxql-node 'column (cons name (cons type constraints))))
(define (primary-key) (sxql-node 'primary-key '()))
(define (not-null) (sxql-node 'not-null '()))
(define (unique) (sxql-node 'unique '()))
(define (autoincrement) (sxql-node 'autoincrement '()))
(define (default v) (sxql-node 'default (list v)))
(define (if-not-exists) (sxql-node 'if-not-exists '()))
(define (if-exists) (sxql-node 'if-exists '()))

(define (sxql-apply-table-opt h opt who)
  (let ((tag (sxql-tag opt)))
    (cond ((eq? tag 'if-not-exists) (alist-set h 'if-not-exists #t))
          (else (error (string-append who ": unknown option"))))))

(define (sxql-apply-table-opts h opts who)
  (if (null? opts)
      h
      (sxql-apply-table-opts (sxql-apply-table-opt h (car opts) who) (cdr opts) who)))

(define (create-table table columns . opts)
  (sxql-apply-table-opts (list (cons 'type 'create-table) (cons 'table table) (cons 'columns columns))
                          opts "sxql:create-table"))

;; ---- DDL: drop-table / alter-table ----

(define (sxql-apply-droptable-opts h opts)
  (if (null? opts)
      h
      (let ((tag (sxql-tag (car opts))))
        (if (eq? tag 'if-exists)
            (sxql-apply-droptable-opts (alist-set h 'if-exists #t) (cdr opts))
            (error "sxql:drop-table: unknown option")))))

(define (drop-table table . opts)
  (sxql-apply-droptable-opts (list (cons 'type 'drop-table) (cons 'table table)) opts))

(define (rename-to name) (sxql-node 'rename-to (list name)))
(define (add-column col) (sxql-node 'add-column (list col)))
(define (rename-column old new) (sxql-node 'rename-column (list old new)))
(define (drop-column name) (sxql-node 'drop-column (list name)))

(define (alter-table table clause) (list (cons 'type 'alter-table) (cons 'table table) (cons 'clause clause)))

;; ---- DDL: create-index / drop-index ----

(define (sxql-apply-createindex-opts h opts)
  (if (null? opts)
      h
      (let ((tag (sxql-tag (car opts))))
        (cond ((eq? tag 'unique) (sxql-apply-createindex-opts (alist-set h 'unique #t) (cdr opts)))
              ((eq? tag 'if-not-exists) (sxql-apply-createindex-opts (alist-set h 'if-not-exists #t) (cdr opts)))
              (else (error "sxql:create-index: unknown option"))))))

(define (create-index name table columns . opts)
  (sxql-apply-createindex-opts
    (list (cons 'type 'create-index) (cons 'name name) (cons 'table table) (cons 'columns columns))
    opts))

(define (sxql-apply-dropindex-opts h opts)
  (if (null? opts)
      h
      (let ((tag (sxql-tag (car opts))))
        (if (eq? tag 'if-exists)
            (sxql-apply-dropindex-opts (alist-set h 'if-exists #t) (cdr opts))
            (error "sxql:drop-index: unknown option")))))

(define (drop-index name . opts)
  (sxql-apply-dropindex-opts (list (cons 'type 'drop-index) (cons 'name name)) opts))

;; ---- Rendering: statement dispatch ----

(define (render-statement stmt box)
  (let ((type (sxql-type stmt)))
    (cond
      ((eq? type 'select) (render-select stmt box))
      ((eq? type 'insert-into) (render-insert stmt box))
      ((eq? type 'update) (render-update stmt box))
      ((eq? type 'delete-from) (render-delete stmt box))
      ((eq? type 'union) (render-union stmt box))
      ((eq? type 'create-table) (render-create-table stmt))
      ((eq? type 'drop-table) (render-drop-table stmt))
      ((eq? type 'alter-table) (render-alter-table stmt))
      ((eq? type 'create-index) (render-create-index stmt))
      ((eq? type 'drop-index) (render-drop-index stmt))
      (else (error (string-append "sxql:yield: unknown statement type '" (symbol->string type) "'"))))))

(define (render-order-item o box)
  (let ((tag (sxql-tag o)))
    (cond ((eq? tag 'asc) (string-append (render-expr (car (sxql-payload o)) box) " ASC"))
          ((eq? tag 'desc) (string-append (render-expr (car (sxql-payload o)) box) " DESC"))
          (else (render-expr o box)))))

(define (render-joins joins box)
  (apply string-append
    (map (lambda (j)
           (let ((jp (sxql-payload j)))
             (string-append " " (car jp) " JOIN " (render-expr (cadr jp) box) " ON " (render-expr (caddr jp) box))))
         joins)))

(define (render-select stmt box)
  (let* ((fields (sxql-require stmt 'fields "sxql:yield"))
         (distinct? (sxql-get stmt 'distinct))
         (fields-sql (join-strings ", " (map (lambda (f) (render-expr f box)) fields)))
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
      (if from (string-append " FROM " (render-expr from box)) "")
      (if joins (render-joins joins box) "")
      (if where (string-append " WHERE " (render-expr where box)) "")
      (if group-by (string-append " GROUP BY " (join-strings ", " (map (lambda (c) (render-expr c box)) group-by))) "")
      (if having (string-append " HAVING " (render-expr having box)) "")
      (if order-by (string-append " ORDER BY " (join-strings ", " (map (lambda (i) (render-order-item i box)) order-by))) "")
      (if limit (string-append " LIMIT " (render-expr limit box)) "")
      (if offset (string-append " OFFSET " (render-expr offset box)) ""))))

(define (render-on-conflict node box)
  (let ((tag (sxql-tag node)) (payload (sxql-payload node)))
    (cond
      ((eq? tag 'do-nothing)
       (if (null? payload)
           "ON CONFLICT DO NOTHING"
           (string-append "ON CONFLICT (" (join-strings ", " (map (lambda (c) (render-expr c box)) payload)) ") DO NOTHING")))
      ((eq? tag 'do-update)
       (let* ((target-cols (join-strings ", " (map (lambda (c) (render-expr c box)) (car payload))))
              (set-pairs (sxql-payload (cadr payload)))
              (assigns (join-strings ", "
                         (map (lambda (pair) (string-append (symbol->string (car pair)) " = " (render-expr (cdr pair) box)))
                              set-pairs))))
         (string-append "ON CONFLICT (" target-cols ") DO UPDATE SET " assigns)))
      (else (error "sxql:yield: unknown on-conflict kind")))))

(define (render-insert stmt box)
  (let* ((table (sxql-require stmt 'table "sxql:yield"))
         (set-node (or (sxql-get stmt 'set) (error "sxql:yield: insert-into requires sxql:set=")))
         (cols (join-strings ", " (map (lambda (pair) (symbol->string (car pair))) set-node)))
         (placeholders (join-strings ", " (map (lambda (pair) (render-expr (cdr pair) box)) set-node)))
         (table-sql (render-expr table box))
         (oc (sxql-get stmt 'on-conflict))
         (returning (sxql-get stmt 'returning)))
    (string-append
      "INSERT INTO " table-sql " (" cols ") VALUES (" placeholders ")"
      (if oc (string-append " " (render-on-conflict oc box)) "")
      (if returning (string-append " RETURNING " (join-strings ", " (map (lambda (c) (render-expr c box)) returning))) ""))))

(define (render-update stmt box)
  (let* ((table (sxql-require stmt 'table "sxql:yield"))
         (set-node (or (sxql-get stmt 'set) (error "sxql:yield: update requires sxql:set=")))
         (assigns (join-strings ", "
                    (map (lambda (pair) (string-append (symbol->string (car pair)) " = " (render-expr (cdr pair) box)))
                         set-node)))
         (table-sql (render-expr table box))
         (where (sxql-get stmt 'where))
         (returning (sxql-get stmt 'returning)))
    (string-append
      "UPDATE " table-sql " SET " assigns
      (if where (string-append " WHERE " (render-expr where box)) "")
      (if returning (string-append " RETURNING " (join-strings ", " (map (lambda (c) (render-expr c box)) returning))) ""))))

(define (render-delete stmt box)
  (let* ((table (sxql-require stmt 'table "sxql:yield"))
         (table-sql (render-expr table box))
         (where (sxql-get stmt 'where))
         (returning (sxql-get stmt 'returning)))
    (string-append
      "DELETE FROM " table-sql
      (if where (string-append " WHERE " (render-expr where box)) "")
      (if returning (string-append " RETURNING " (join-strings ", " (map (lambda (c) (render-expr c box)) returning))) ""))))

(define (render-union stmt box)
  (let* ((kind (sxql-require stmt 'kind "sxql:yield"))
         (stmts (sxql-require stmt 'statements "sxql:yield")))
    (join-strings (string-append " " kind " ") (map (lambda (s) (render-statement s box)) stmts))))

;; ---- Rendering: DDL (always raw text, never parameterized) ----

(define (render-column-constraint node)
  (let ((tag (sxql-tag node)))
    (cond ((eq? tag 'primary-key) "PRIMARY KEY")
          ((eq? tag 'not-null) "NOT NULL")
          ((eq? tag 'unique) "UNIQUE")
          ((eq? tag 'autoincrement) "AUTOINCREMENT")
          ((eq? tag 'default) (string-append "DEFAULT " (render-literal (car (sxql-payload node)))))
          (else (error "sxql:column: unknown constraint")))))

(define (render-column-def node)
  (let* ((payload (sxql-payload node))
         (name (symbol->string (car payload)))
         (type (cadr payload))
         (constraints (map render-column-constraint (cddr payload))))
    (join-strings " " (cons name (cons type constraints)))))

(define (render-literal v)
  (cond ((string? v) (string-append "'" (escape-quotes v) "'"))
        ((number? v) (number->string v))
        ((boolean? v) (if v "1" "0"))
        ((null? v) "NULL")
        ((symbol? v) (symbol->string v))
        (else (error "sxql:column: cannot use value as a DEFAULT literal"))))

(define (render-create-table stmt)
  (let* ((table (symbol->string (sxql-require stmt 'table "sxql:yield")))
         (columns (sxql-require stmt 'columns "sxql:yield"))
         (if-not-exists (if (sxql-get stmt 'if-not-exists) "IF NOT EXISTS " "")))
    (string-append "CREATE TABLE " if-not-exists table " (" (join-strings ", " (map render-column-def columns)) ")")))

(define (render-drop-table stmt)
  (let* ((table (symbol->string (sxql-require stmt 'table "sxql:yield")))
         (if-exists (if (sxql-get stmt 'if-exists) "IF EXISTS " "")))
    (string-append "DROP TABLE " if-exists table)))

(define (render-alter-table stmt)
  (let* ((table (symbol->string (sxql-require stmt 'table "sxql:yield")))
         (clause (sxql-require stmt 'clause "sxql:yield"))
         (tag (sxql-tag clause))
         (payload (sxql-payload clause))
         (action
           (cond ((eq? tag 'rename-to) (string-append "RENAME TO " (symbol->string (car payload))))
                 ((eq? tag 'add-column) (string-append "ADD COLUMN " (render-column-def (car payload))))
                 ((eq? tag 'rename-column)
                  (string-append "RENAME COLUMN " (symbol->string (car payload)) " TO " (symbol->string (cadr payload))))
                 ((eq? tag 'drop-column) (string-append "DROP COLUMN " (symbol->string (car payload))))
                 (else (error "sxql:alter-table: unknown clause")))))
    (string-append "ALTER TABLE " table " " action)))

(define (render-create-index stmt)
  (let* ((name (symbol->string (sxql-require stmt 'name "sxql:yield")))
         (table (symbol->string (sxql-require stmt 'table "sxql:yield")))
         (cols (join-strings ", " (map symbol->string (sxql-require stmt 'columns "sxql:yield"))))
         (unique-str (if (sxql-get stmt 'unique) "UNIQUE " ""))
         (if-not-exists (if (sxql-get stmt 'if-not-exists) "IF NOT EXISTS " "")))
    (string-append "CREATE " unique-str "INDEX " if-not-exists name " ON " table " (" cols ")")))

(define (render-drop-index stmt)
  (let* ((name (symbol->string (sxql-require stmt 'name "sxql:yield")))
         (if-exists (if (sxql-get stmt 'if-exists) "IF EXISTS " "")))
    (string-append "DROP INDEX " if-exists name)))

;; ---- Rendering: expressions/conditions ----
;;
;; The core rule: a symbol operand is a raw identifier; anything else is a
;; bound parameter. Recognized operator tags recurse; an unrecognized plain
;; list is treated as a value list.

(define (render-expr node box)
  (cond
    ((symbol? node) (symbol->string node))
    ((pair? node)
     (let ((tag (sxql-tag node)))
       (if (eq? tag #f)
           (string-append "(" (join-strings ", " (map (lambda (v) (render-expr v box)) node)) ")")
           (render-operator tag (sxql-payload node) box))))
    (else (params-add! box node) "?")))

(define (render-case payload box)
  (join-strings " "
    (append (list "CASE")
            (append
              (map (lambda (clause)
                     (let ((tag (sxql-tag clause)) (cp (sxql-payload clause)))
                       (cond ((eq? tag 'when) (string-append "WHEN " (render-expr (car cp) box) " THEN " (render-expr (cadr cp) box)))
                             ((eq? tag 'else) (string-append "ELSE " (render-expr (car cp) box)))
                             (else (error "sxql:case: expected sxql:when/sxql:else")))))
                   payload)
              (list "END")))))

(define (render-operator tag payload box)
  (cond
    ((member tag '(= != < > <= >= + - * / %))
     (string-append (render-expr (car payload) box) " " (symbol->string tag) " " (render-expr (cadr payload) box)))
    ((eq? tag 'like) (string-append (render-expr (car payload) box) " LIKE " (render-expr (cadr payload) box)))
    ((eq? tag 'and) (string-append "(" (join-strings " AND " (map (lambda (c) (render-expr c box)) payload)) ")"))
    ((eq? tag 'or) (string-append "(" (join-strings " OR " (map (lambda (c) (render-expr c box)) payload)) ")"))
    ((eq? tag 'not) (string-append "NOT (" (render-expr (car payload) box) ")"))
    ((or (eq? tag 'in) (eq? tag 'not-in))
     (let ((col (render-expr (car payload) box))
           (vals (join-strings ", " (map (lambda (v) (render-expr v box)) (cadr payload)))))
       (string-append col " " (if (eq? tag 'in) "IN" "NOT IN") " (" vals ")")))
    ((eq? tag 'is-null) (string-append (render-expr (car payload) box) " IS NULL"))
    ((eq? tag 'is-not-null) (string-append (render-expr (car payload) box) " IS NOT NULL"))
    ((eq? tag 'as) (string-append (render-expr (car payload) box) " AS " (render-expr (cadr payload) box)))
    ((eq? tag 'exists) (string-append "EXISTS (" (render-statement (car payload) box) ")"))
    ((eq? tag 'case) (render-case payload box))
    ((eq? tag 'raw) (car payload))
    (else (error (string-append "sxql:yield: unknown operator '" (symbol->string tag) "'")))))

;; ---- Render ----

(define (yield stmt)
  (let ((box (vector '())))
    (let ((sql (render-statement stmt box)))
      (list sql (vector-ref box 0)))))
