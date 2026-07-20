// Node.js/Express/Drizzle/Eta/SQLite equivalent of ../../ruby/demo-todo/app.rb,
// ../../crystal/demo-todo/src/app.cr, ../../racket/demo-todo/app.rkt,
// ../../go/demo-todo/main.go, and ../../scheme/demo-todo/app.scm, built for a
// head-to-head benchmark. Same storage (in-memory SQLite), same routes, same
// row-level memoization strategy, same JSON content-negotiation behavior --
// written in the idiomatic Express/Drizzle/Eta style rather than hand-porting
// another twin. Express plays Sinatra/Kemal/Fiber's role, Drizzle plays
// Sequel/Granite/GORM's (a thin, synchronous query builder over
// better-sqlite3 rather than a heavier async ORM), and Eta plays ERB/ECR's
// (a lightweight, precompiled template engine rather than EJS's fuller
// runtime).

const fs = require("fs");
const path = require("path");
const express = require("express");
const { Eta } = require("eta");
const Database = require("better-sqlite3");
const { drizzle } = require("drizzle-orm/better-sqlite3");
const { sqliteTable, integer, text } = require("drizzle-orm/sqlite-core");
const { eq, asc } = require("drizzle-orm");

// better-sqlite3 is a single, synchronous connection -- no pool to
// mis-configure the way the async drivers need capping to 1 (same
// single-connection constraint every other twin's in-memory SQLite has).
const sqlite = new Database(":memory:");
sqlite.exec(
  "CREATE TABLE todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)"
);

const todos = sqliteTable("todos", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  title: text("title").notNull(),
  done: integer("done", { mode: "boolean" }).notNull().default(false),
});

const db = drizzle(sqlite);

function addTodo(title) {
  db.insert(todos).values({ title, done: false }).run();
}

function todoAll() {
  return db.select().from(todos).orderBy(asc(todos.id)).all();
}

function todoCountRemaining() {
  return db.select().from(todos).where(eq(todos.done, false)).all().length;
}

// Mirrors the other twins' per-row cache: cache rendered row markup keyed on
// exactly (id, done, title), so re-rendering the list only recomputes rows
// whose fields actually changed.
const ROW_CACHE = new Map();
const rowCacheKey = (id, done, title) => `${id}:${done}:${title}`;

const eta = new Eta({ views: path.join(__dirname, "views") });
const rowTemplate = eta.compile(
  fs.readFileSync(path.join(__dirname, "views", "row.eta"), "utf8")
);

function cachedTodoRowHtml(id, done, title) {
  const key = rowCacheKey(id, done, title);
  let html = ROW_CACHE.get(key);
  if (html === undefined) {
    html = rowTemplate.call(eta, { id, done, title }, eta);
    ROW_CACHE.set(key, html);
  }
  return html;
}

function toggleTodo(id) {
  const row = db.select().from(todos).where(eq(todos.id, id)).get();
  if (!row) return;
  db.update(todos).set({ done: !row.done }).where(eq(todos.id, id)).run();
  ROW_CACHE.delete(rowCacheKey(id, row.done, row.title));
}

function deleteTodo(id) {
  db.delete(todos).where(eq(todos.id, id)).run();
}

// negotiate reproduces the twins' exact contract: split Accept on ",", strip
// ";..." params, trim, and return the FIRST entry that is exactly "text/html"
// or "application/json" (no "*/*" wildcard matching, client-order-first).
// null means neither was offered -> 406.
function negotiate(acceptHeader) {
  if (!acceptHeader) return null;
  for (const part of acceptHeader.split(",")) {
    const t = part.split(";")[0].trim();
    if (t === "text/html" || t === "application/json") return t;
  }
  return null;
}

const CSS = `body { font-family: sans-serif; }
  .todo-app { max-width: 28rem; margin: 2rem auto; }
  .todos { list-style: none; padding-left: 0; }
  .todos li { display: flex; align-items: center; gap: 0.5rem; padding: 4px 0; }
  .todos li .title { flex: 1; }
  .done .title { text-decoration: line-through; color: #888; }
  form.toggle, form.delete, form.add { display: inline; }
  form.add { display: flex; gap: 0.5rem; margin-bottom: 1rem; }`;

const pageTemplate = eta.compile(
  fs.readFileSync(path.join(__dirname, "views", "page.eta"), "utf8")
);

function pageHtml() {
  const rowsHtml = todoAll()
    .map((row) => cachedTodoRowHtml(row.id, row.done, row.title))
    .join("");
  return pageTemplate.call(eta, { css: CSS, rowsHtml, remaining: todoCountRemaining() }, eta);
}

const app = express();
app.use(express.urlencoded({ extended: false }));

app.get("/", (req, res) => {
  const type = negotiate(req.headers.accept);
  if (type === "text/html") {
    res.type("html").send(pageHtml());
  } else if (type === "application/json") {
    res.type("json").json(todoAll().map(({ id, title, done }) => ({ id, title, done })));
  } else {
    res
      .type("text/plain")
      .status(406)
      .send("Not Acceptable: this route serves text/html or application/json");
  }
});

app.post("/todos", (req, res) => {
  addTodo(req.body.title);
  res.redirect("/");
});

app.post("/todos/:id/complete", (req, res) => {
  toggleTodo(Number(req.params.id));
  res.redirect("/");
});

app.post("/todos/:id/delete", (req, res) => {
  deleteTodo(Number(req.params.id));
  res.redirect("/");
});

addTodo("Write report");
addTodo("Review PR");
addTodo("Ship release");
toggleTodo(2);

const port = process.env.PORT || "4567";
app.listen(Number(port), "127.0.0.1", () => {
  console.log(`Serving the todo list at http://127.0.0.1:${port} (pid ${process.pid})`);
});
