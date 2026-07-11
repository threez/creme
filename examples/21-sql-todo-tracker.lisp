(require 'sql)
(require 'file)

(define db-path "/tmp/crisp-example-todos.db")
(if (file:exists? db-path) (file:delete db-path))

(define conn (sql:open db-path))
(sql:execute conn "CREATE TABLE todo (id INTEGER PRIMARY KEY, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)")

(sql:execute conn "INSERT INTO todo (title, done) VALUES (?, ?)" "Write report" 0)
(sql:execute conn "INSERT INTO todo (title, done) VALUES (?, ?)" "Review PR" 0)
(sql:execute conn "INSERT INTO todo (title, done) VALUES (?, ?)" "Ship release" 0)

(sql:execute conn "UPDATE todo SET done = 1 WHERE title = ?" "Review PR")

(define (todo-line row)
  (string-append (if (= (cdr (assoc "done" row)) 1) "[x] " "[ ] ") (cdr (assoc "title" row))))

(println "All todos:")
(for-each (lambda (row) (println (todo-line row)))
          (vector->list (sql:query conn "SELECT title, done FROM todo ORDER BY id")))

(println "Remaining: " (sql:scalar conn "SELECT COUNT(*) FROM todo WHERE done = 0"))

(sql:close conn)
(file:delete db-path)
