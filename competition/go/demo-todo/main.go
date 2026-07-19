// Go / Fiber+GORM+html-template/SQLite equivalent of ../../ruby/demo-todo/app.rb,
// ../../crystal/demo-todo/src/app.cr, ../../racket/demo-todo/app.rkt, and
// ../../scheme/demo-todo/app.scm, built for a head-to-head benchmark. Same
// storage (in-memory SQLite), same routes, same JSON content-negotiation
// behavior -- written in idiomatic Fiber+GORM style rather than hand-porting a
// twin. Fiber plays Sinatra's role, GORM plays Sequel/Granite's, and
// html/template plays ERB/ECR's.
package main

import (
	"bytes"
	"fmt"
	"html/template"
	"os"
	"runtime"
	"strconv"
	"strings"

	"github.com/gofiber/fiber/v2"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// Todo is the ORM model; GORM's default pluralized table name is "todos", and
// the json tags fix the response object's key order/casing (id, title, done)
// with done as a real boolean rather than SQLite's stored 0/1.
type Todo struct {
	ID    uint   `gorm:"primaryKey;autoIncrement" json:"id"`
	Title string `gorm:"not null" json:"title"`
	Done  bool   `gorm:"not null;default:0" json:"done"`
}

var db *gorm.DB

// The row/page markup mirrors the Crystal twin's views/row.ecr + views/page.ecr
// structure. template.CSS keeps the stylesheet from being escaped inside
// <style>; .Title is auto-escaped by html/template in its text context.
const pageSource = `<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Todo List</title>
    <style>{{.CSS}}</style>
  </head>
  <body>
    <div class="todo-app">
      <h1>Todo List</h1>
      <form method="post" action="/todos" class="add">
        <input type="text" name="title" placeholder="New todo" required>
        <button type="submit">Add</button>
      </form>
      <ul class="todos">
        {{range .Todos}}<li class="{{if .Done}}done{{else}}pending{{end}}">
  <form method="post" action="/todos/{{.ID}}/complete" class="toggle">
    <button type="submit">{{if .Done}}Undo{{else}}Done{{end}}</button>
  </form>
  <span class="title">{{.Title}}</span>
  <form method="post" action="/todos/{{.ID}}/delete" class="delete">
    <button type="submit">Delete</button>
  </form>
</li>
{{end}}
      </ul>
      <p class="count">{{.Remaining}} remaining</p>
    </div>
  </body>
</html>
`

const css = `body { font-family: sans-serif; }
  .todo-app { max-width: 28rem; margin: 2rem auto; }
  .todos { list-style: none; padding-left: 0; }
  .todos li { display: flex; align-items: center; gap: 0.5rem; padding: 4px 0; }
  .todos li .title { flex: 1; }
  .done .title { text-decoration: line-through; color: #888; }
  form.toggle, form.delete, form.add { display: inline; }
  form.add { display: flex; gap: 0.5rem; margin-bottom: 1rem; }`

var pageTmpl = template.Must(template.New("page").Parse(pageSource))

func todoAll() []Todo {
	todos := []Todo{}
	db.Order("id").Find(&todos)
	return todos
}

func remainingCount() int64 {
	var n int64
	db.Model(&Todo{}).Where("done = ?", false).Count(&n)
	return n
}

func addTodo(title string) {
	db.Create(&Todo{Title: title, Done: false})
}

// toggleTodo flips done (so it doubles as "undo"), no-op if the row is missing.
func toggleTodo(id int) {
	var row Todo
	if err := db.First(&row, id).Error; err != nil {
		return
	}
	db.Model(&row).Update("done", !row.Done)
}

func deleteTodo(id int) {
	db.Delete(&Todo{}, id)
}

func pageHTML() (string, error) {
	var buf bytes.Buffer
	data := struct {
		CSS       template.CSS
		Todos     []Todo
		Remaining int64
	}{template.CSS(css), todoAll(), remainingCount()}
	if err := pageTmpl.Execute(&buf, data); err != nil {
		return "", err
	}
	return buf.String(), nil
}

// negotiate reproduces the twins' exact contract: split Accept on ",", strip
// ";..." params, trim, and return the FIRST entry that is exactly "text/html"
// or "application/json" (no "*/*" wildcard matching, client-order-first).
// "" means neither was offered -> 406.
func negotiate(accept string) string {
	for _, part := range strings.Split(accept, ",") {
		t := strings.TrimSpace(strings.SplitN(part, ";", 2)[0])
		if t == "text/html" || t == "application/json" {
			return t
		}
	}
	return ""
}

func handleIndex(c *fiber.Ctx) error {
	switch negotiate(c.Get("Accept")) {
	case "text/html":
		html, err := pageHTML()
		if err != nil {
			return err
		}
		c.Set("Content-Type", "text/html")
		return c.SendString(html)
	case "application/json":
		return c.JSON(todoAll())
	default:
		c.Set("Content-Type", "text/plain")
		return c.Status(fiber.StatusNotAcceptable).
			SendString("Not Acceptable: this route serves text/html or application/json")
	}
}

func idParam(c *fiber.Ctx) int {
	id, _ := strconv.Atoi(c.Params("id"))
	return id
}

func main() {
	// Pin to a single OS thread for request handling: the other twins are all
	// effectively single-core (Ruby's GIL + single Puma process, Kemal without
	// -Dpreview_mt, Racket's default servlet, the single-threaded creme
	// interpreter), so this keeps the comparison about the stack rather than
	// letting fasthttp fan out across every core.
	runtime.GOMAXPROCS(1)

	var err error
	// A private in-memory SQLite DB is per-connection, so cap the pool at one
	// connection -- otherwise a second pooled connection sees an empty DB
	// (same reason the Crystal twin pins max_pool_size=1).
	db, err = gorm.Open(sqlite.Open("file::memory:?cache=shared"),
		&gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		panic(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		panic(err)
	}
	sqlDB.SetMaxOpenConns(1)

	if err := db.AutoMigrate(&Todo{}); err != nil {
		panic(err)
	}

	// Seed the same 3 rows as the twins, then toggle id 2 done -> 2 remaining.
	addTodo("Write report")
	addTodo("Review PR")
	addTodo("Ship release")
	toggleTodo(2)

	app := fiber.New(fiber.Config{DisableStartupMessage: true})

	app.Get("/", handleIndex)
	app.Post("/todos", func(c *fiber.Ctx) error {
		addTodo(c.FormValue("title"))
		return c.Redirect("/", fiber.StatusFound)
	})
	app.Post("/todos/:id/complete", func(c *fiber.Ctx) error {
		toggleTodo(idParam(c))
		return c.Redirect("/", fiber.StatusFound)
	})
	app.Post("/todos/:id/delete", func(c *fiber.Ctx) error {
		deleteTodo(idParam(c))
		return c.Redirect("/", fiber.StatusFound)
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "4567"
	}
	fmt.Printf("Serving the todo list at http://127.0.0.1:%s (pid %d)\n", port, os.Getpid())
	if err := app.Listen("127.0.0.1:" + port); err != nil {
		panic(err)
	}
}
