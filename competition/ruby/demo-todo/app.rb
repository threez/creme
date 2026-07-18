# Ruby/Sinatra/ERB/SQLite equivalent of ../../../examples/demo-todo.scm,
# built for a head-to-head benchmark against the Scheme version. Same
# storage (in-memory SQLite), same routes, same row-level memoization
# strategy, same JSON content-negotiation behavior -- written in the
# idiomatic Ruby/Sinatra/ERB style rather than hand-porting the Scheme.

require "sinatra"
require "sequel"
require "json"
require "erb"

set :port, ENV.fetch("PORT", 4567).to_i
set :bind, "127.0.0.1"
set :server, "puma"
set :threads, [4, 4]
set :lock, false

# ORM layer, mirroring (creme dao)'s define-dao: a Sequel::Model gives us
# the same declarative create!/find/update!/delete!/all/count surface the
# Scheme version's DAO macro generates, rather than hand-written SQL.
#
# TODO_DB_PATH lets a clustered (puma -w N) run point every forked worker
# at the same on-disk SQLite file instead of a private in-memory DB --
# :memory: is per-process, so under `preload_app!` + fork each worker
# would otherwise see its own disconnected copy of the data. Single-process
# runs (the default) keep the zero-file-cleanup :memory: behavior that
# matches examples/demo-todo.scm.
DB_PATH = ENV.fetch("TODO_DB_PATH", ":memory:")
DB = Sequel.connect(DB_PATH == ":memory:" ? "sqlite::memory:" : "sqlite://#{DB_PATH}")

unless DB.table_exists?(:todos)
  DB.create_table?(:todos) do
    primary_key :id
    String :title, null: false
    Integer :done, null: false, default: 0
  end
end

class Todo < Sequel::Model(:todos)
end

# Under a clustered Puma boot, each forked worker calls this again (see
# puma.rb's on_worker_boot) to get its own connection to the same file --
# Sequel::Database/sqlite3 connections aren't safe to share across a fork.
def reconnect_db!
  return if DB_PATH == ":memory:"
  DB.disconnect
  Sequel::DATABASES.delete(DB)
end

def add_todo!(title)
  Todo.create(title: title, done: 0)
end

def todo_all
  Todo.order(:id).all
end

def todo_find(id)
  Todo[id]
end

def todo_count_remaining
  Todo.where(done: 0).count
end

# Mirrors (creme memoize)'s per-row cache in the Scheme version: cache
# rendered row markup keyed on exactly (id, done, title), so re-rendering
# the list only recomputes rows whose fields actually changed.
ROW_CACHE = {}

def toggle_todo!(id)
  row = todo_find(id)
  old_done = row.done == 1
  title = row.title
  row.update(done: old_done ? 0 : 1)
  ROW_CACHE.delete([id, old_done, title])
end

def delete_todo!(id)
  Todo[id].delete
end

ROW_TEMPLATE = ERB.new(<<~ERB)
  <li class="<%= done ? "done" : "pending" %>">
    <form method="post" action="/todos/<%= id %>/complete" class="toggle">
      <button type="submit"><%= done ? "Undo" : "Done" %></button>
    </form>
    <span class="title"><%= ERB::Util.html_escape(title) %></span>
    <form method="post" action="/todos/<%= id %>/delete" class="delete">
      <button type="submit">Delete</button>
    </form>
  </li>
ERB

def cached_todo_row_html(id, done, title)
  ROW_CACHE[[id, done, title]] ||= ROW_TEMPLATE.result_with_hash(id: id, done: done, title: title)
end

CSS = <<~CSS
  body { font-family: sans-serif; }
  .todo-app { max-width: 28rem; margin: 2rem auto; }
  .todos { list-style: none; padding-left: 0; }
  .todos li { display: flex; align-items: center; gap: 0.5rem; padding: 4px 0; }
  .todos li .title { flex: 1; }
  .done .title { text-decoration: line-through; color: #888; }
  form.toggle, form.delete, form.add { display: inline; }
  form.add { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
CSS

PAGE_TEMPLATE = ERB.new(<<~ERB)
  <!DOCTYPE html>
  <html>
    <head>
      <meta charset="utf-8">
      <title>Todo List</title>
      <style><%= css %></style>
    </head>
    <body>
      <div class="todo-app">
        <h1>Todo List</h1>
        <form method="post" action="/todos" class="add">
          <input type="text" name="title" placeholder="New todo" required>
          <button type="submit">Add</button>
        </form>
        <ul class="todos">
          <% rows.each do |row| %><%= cached_todo_row_html(row.id, row.done == 1, row.title) %><% end %>
        </ul>
        <p class="count"><%= remaining %> remaining</p>
      </div>
    </body>
  </html>
ERB

def page_html
  PAGE_TEMPLATE.result_with_hash(css: CSS, rows: todo_all, remaining: todo_count_remaining)
end

def todo_json(row)
  { id: row.id, title: row.title, done: row.done == 1 }
end

def todos_json
  JSON.generate(todo_all.map { |row| todo_json(row) })
end

get "/" do
  case request.accept.map(&:to_s).find { |t| t == "text/html" || t == "application/json" }
  when "text/html"
    content_type :html
    page_html
  when "application/json"
    content_type :json
    todos_json
  else
    halt 406, "Not Acceptable: this route serves text/html or application/json"
  end
end

post "/todos" do
  add_todo!(params["title"])
  redirect "/"
end

post "/todos/:id/complete" do
  toggle_todo!(params["id"].to_i)
  redirect "/"
end

post "/todos/:id/delete" do
  delete_todo!(params["id"].to_i)
  redirect "/"
end

# Guarded so a clustered boot (each worker requiring this file independently
# against the same shared file DB) seeds exactly once rather than once per
# worker.
if Todo.count.zero?
  add_todo!("Write report")
  add_todo!("Review PR")
  add_todo!("Ship release")
  toggle_todo!(2)
end

puts "Serving the todo list at http://127.0.0.1:#{settings.port} (pid #{Process.pid})"
