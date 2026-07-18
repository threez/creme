;; ===========================================================================
;; (creme dao): a mini, Scheme-native DAO layer over (creme sxql)
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme sxql)/(creme surf)/(creme html) use) rather than compiled into the
;; interpreter binary, since it's pure Scheme on top of (creme sxql)/
;; (creme sql), no opaque foreign object of its own involved.
;;
;; The point of this library: a script using `define-dao` never needs to
;; write (or import) a single `sxql-*` call itself. Every SQL/(creme sxql)
;; detail — column DDL, WHERE-by-id, row shape — lives entirely inside this
;; file's own body; the code `define-dao` generates only ever calls this
;; library's own `dao-*`-exported procedures, so `(import (creme dao))`
;; alone is enough (no `(import (creme sxql))` needed for ordinary usage).
;;
;; One DAO = one table; the primary key is always a column named `id`. No
;; associations, no validations, no migrations beyond `CREATE TABLE IF NOT
;; EXISTS` at definition time — deliberately "mini".
;;
;; ---- declaring a DAO --------------------------------------------------
;;
;;   (define-dao name conn column-spec ...)
;;
;; `name` names the table and is prefixed onto every generated procedure
;; (`name-create!`, `name-all`, `name-find`, `name-update!`, `name-delete!`,
;; `name-count`, described below). `conn` is an ordinary evaluated
;; expression (typically a `sql-open` connection), evaluated once per
;; generated procedure call, exactly the way (creme sxql)'s own
;; `sxql-select!` splices its own `conn` argument. `define-dao` is a
;; `defmacro` (this interpreter's non-hygienic macro form) — needed because
;; it synthesizes new procedure names (e.g. "todo" -> `todo-create!`) via
;; string-append/string->symbol, which plain syntax-rules pattern
;; substitution has no way to do. Because a defmacro transformer body runs
;; against the single shared @global env (not this library's own env), the
;; NAMES ITS EXPANSION EMITS must be visible wherever `define-dao` is used —
;; every one of them (`dao-create-table!`/`dao-insert!`/`dao-select-all`/
;; `dao-select-one`/`dao-update!`/`dao-delete!`/`dao-count`) is exported by
;; this same library, so `(import (creme dao))` is sufficient at the call
;; site.
;;
;; Each `column-spec` is plain data (not evaluated, not `sxql-*` calls):
;;   (name type constraint ...)
;; `type` is one of: integer, text, real, blob, bool. `constraint` is one of:
;; primary-key, auto-increment, not-null, unique, or (default value). E.g.:
;;
;;   (define-dao todo conn
;;     (id integer primary-key auto-increment)
;;     (title text not-null)
;;     (done bool not-null (default #f)))
;;
;; generates:
;;   (todo-create! . kvs)   -> INSERT; kvs alternating column/value symbols
;;                             and values (same shape (creme sxql)'s own
;;                             sxql-set= takes), e.g.
;;                             (todo-create! 'title "Buy milk" 'done #f);
;;                             returns the new row's id.
;;   (todo-all)             -> every row, ordered by id, as a list of rows
;;                             (read with dao-ref below). No separate
;;                             ordering/filtering API on this end — a
;;                             caller wanting a different order or a subset
;;                             just sorts/filters the returned Scheme list
;;                             itself with ordinary Scheme code.
;;   (todo-find id)         -> the row with this id, or #f if none.
;;   (todo-update! id . kvs)-> UPDATE ... SET kvs WHERE id = id; returns id.
;;   (todo-delete! id)      -> DELETE WHERE id = id.
;;   (todo-count)           -> the total row count.
;;   (todo-count pred)      -> the count of rows for which
;;                             (pred row) is true, `pred` an ordinary
;;                             one-argument Scheme procedure (typically
;;                             built around dao-ref), e.g.
;;                             (todo-count (lambda (row) (not (todo-done? row)))).
;;                             This is what replaces a SQL WHERE clause for
;;                             filtered counts/aggregates: plain Scheme
;;                             filtering over already-fetched rows, not a
;;                             query-builder DSL exposed to the caller.
;;   (todo-<col>? row)      -> generated ONLY for columns declared `bool`
;;                             (e.g. `done` above generates `todo-done?`) —
;;                             SQLite has no native boolean storage class, so
;;                             a `bool` column is still stored/read back as
;;                             an INTEGER 0/1 under the hood (dao-ref on it
;;                             still returns 0/1, not #t/#f); this predicate
;;                             is the one place that 0/1 -> #t/#f translation
;;                             happens, e.g. (todo-done? row). Writing a
;;                             `bool` column's value (via todo-create!/
;;                             todo-update!'s kvs, or its own `(default ...)`
;;                             constraint) still takes a plain #t/#f directly
;;                             — only reading it back needs this accessor.
;;
;; ---- reading a row ------------------------------------------------------
;;
;;   (dao-ref row col) -> the value of column `col` (a symbol, e.g. 'title)
;;                        in `row`. Hides the fact that a row's actual
;;                        underlying shape is (creme sxql)'s own
;;                        `:col`-keyword-alist convention (see sxql.sld's
;;                        sxql-row->kw-alist) — callers never need to know
;;                        that detail, only `dao-ref`. For a `bool` column,
;;                        prefer the generated `<table>-<col>?` predicate
;;                        (above) over calling dao-ref directly, since
;;                        dao-ref itself has no per-column type information
;;                        to translate the stored 0/1 with.
;;
;; ---- escape hatch ---------------------------------------------------------
;;
;;   (dao-run-stmt! conn stmt) -> sxql-yield stmt, then apply sql-execute;
;;                        returns sql-execute's own alist
;;                        (("rows-affected" . N) ("last-insert-id" . N)).
;;                        For a script that wants to run one extra hand-built
;;                        (creme sxql) statement outside any DAO's generated
;;                        CRUD (e.g. a one-off migration) — a caller reaching
;;                        for this must (import (creme sxql)) itself to build
;;                        `stmt`; this is the one place this library's
;;                        "never need (creme sxql) yourself" promise is
;;                        opt-out rather than automatic.
;;
;; Not auto-imported anywhere — every script that wants any of this must
;; (import (creme dao)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme dao)
  (export define-dao dao-ref dao-run-stmt!
          dao-create-table! dao-insert! dao-select-all dao-select-one dao-update! dao-delete! dao-count)
  (import (scheme base) (scheme write) (creme sxql) (creme sql))
  (begin
    ;; SRFI-1's filter isn't an R7RS base export; kept as a small private
    ;; copy for dao-count's own use, same rationale (creme extra)'s header
    ;; comment gives for its own private filter -- keeps this library
    ;; self-contained rather than depending on (creme extra).
    (define (dao-filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (dao-filter pred (cdr lst))))
            (else (dao-filter pred (cdr lst)))))

    (define (dao-ref row col)
      (cdr (assoc (string->symbol (string-append ":" (symbol->string col))) row)))

    (define (dao-run-stmt! conn stmt)
      (let ((yielded (sxql-yield stmt)))
        (apply sql-execute conn (car yielded) (cadr yielded))))

    ;; ---- column mini-DSL -> (creme sxql) column nodes ----------------------

    (define (dao-column-type->sql type)
      (cond
       ((eq? type 'integer) "INTEGER")
       ((eq? type 'text) "TEXT")
       ((eq? type 'real) "REAL")
       ((eq? type 'blob) "BLOB")
       ((eq? type 'bool) "BOOLEAN")
       (else (error "define-dao: unknown column type" type))))

    (define (dao-constraint->sxql c)
      (cond
       ((eq? c 'primary-key) (sxql-primary-key))
       ((eq? c 'auto-increment) (sxql-autoincrement))
       ((eq? c 'not-null) (sxql-not-null))
       ((eq? c 'unique) (sxql-unique))
       ((and (pair? c) (eq? (car c) 'default)) (sxql-default (cadr c)))
       (else (error "define-dao: unknown column constraint" c))))

    (define (dao-column->sxql spec)
      (apply sxql-column (car spec) (dao-column-type->sql (cadr spec))
             (map dao-constraint->sxql (cddr spec))))

    (define (dao-create-table! conn table columns)
      (dao-run-stmt! conn (sxql-create-table table (map dao-column->sxql columns) (sxql-if-not-exists))))

    ;; ---- generic CRUD, shared by every generated DAO -----------------------

    (define (dao-insert! conn table kvs)
      (cdr (assoc "last-insert-id" (dao-run-stmt! conn (sxql-insert-into table (apply sxql-set= kvs))))))

    (define (dao-select-all conn table)
      (sxql-run conn (sxql-select (list '*) (sxql-from table) (sxql-order-by 'id))))

    (define (dao-select-one conn table id)
      (let ((rows (sxql-run conn (sxql-select (list '*) (sxql-from table) (sxql-where (sxql-= 'id id))))))
        (if (pair? rows) (car rows) #f)))

    (define (dao-update! conn table id kvs)
      (dao-run-stmt! conn (sxql-update table (apply sxql-set= kvs) (sxql-where (sxql-= 'id id)))))

    (define (dao-delete! conn table id)
      (dao-run-stmt! conn (sxql-delete-from table (sxql-where (sxql-= 'id id)))))

    (define (dao-count conn table . opt-pred)
      (let ((rows (dao-select-all conn table)))
        (length (if (pair? opt-pred) (dao-filter (car opt-pred) rows) rows))))

    ;; ---- define-dao ---------------------------------------------------------

    (defmacro define-dao (name conn . columns)
      (let* ((name-str (symbol->string name))
             (mk (lambda (suffix) (string->symbol (string-append name-str suffix))))
             ;; One (name-<col>? row) predicate per `bool` column, translating
             ;; its stored 0/1 to #t/#f -- see this file's header comment.
             ;; Filtered with a named `let` rather than this file's own
             ;; private dao-filter: a defmacro transformer body runs against
             ;; the single shared @global env, not this library's own env
             ;; (see this file's own header comment), so dao-filter -- an
             ;; ordinary, unexported binding in THIS library's env -- isn't
             ;; visible here even though it's visible to dao-count's body.
             (bool-cols
              (let loop ((specs columns) (acc '()))
                (cond ((null? specs) (reverse acc))
                      ((eq? (cadr (car specs)) 'bool) (loop (cdr specs) (cons (car specs) acc)))
                      (else (loop (cdr specs) acc)))))
             (bool-accessors
              (map (lambda (spec)
                     (list 'define (list (mk (string-append "-" (symbol->string (car spec)) "?")) 'row)
                           (list '= (list 'dao-ref 'row (list 'quote (car spec))) 1)))
                   bool-cols)))
        (cons 'begin
              (append
               (list
                (list 'dao-create-table! conn (list 'quote name) (list 'quote columns))
                (list 'define (cons (mk "-create!") 'kvs) (list 'dao-insert! conn (list 'quote name) 'kvs))
                (list 'define (list (mk "-all")) (list 'dao-select-all conn (list 'quote name)))
                (list 'define (list (mk "-find") 'id) (list 'dao-select-one conn (list 'quote name) 'id))
                (list 'define (cons (mk "-update!") (cons 'id 'kvs))
                      (list 'dao-update! conn (list 'quote name) 'id 'kvs) 'id)
                (list 'define (list (mk "-delete!") 'id) (list 'dao-delete! conn (list 'quote name) 'id))
                (list 'define (cons (mk "-count") 'opt-pred)
                      (list 'apply 'dao-count conn (list 'quote name) 'opt-pred)))
               bool-accessors))))))
