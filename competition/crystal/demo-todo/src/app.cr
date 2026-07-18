# Crystal/Kemal/Granite/ECR/SQLite equivalent of ../../ruby/demo-todo/app.rb
# and ../../scheme/demo-todo/app.scm, built for a head-to-head benchmark.
# Same storage (in-memory SQLite), same routes, same row-level memoization
# strategy, same JSON content-negotiation behavior -- written in the
# idiomatic Crystal/Kemal style rather than hand-porting either twin.

require "kemal"
require "granite"
require "granite/adapter/sqlite"
require "ecr"

# max_pool_size=1 keeps every query on the *same* sqlite3 connection --
# an in-memory DB is private per-connection, so a second pooled connection
# would silently see an empty database.
Granite::Connections << Granite::Adapter::Sqlite.new(name: "sqlite", url: "sqlite3::memory:?max_pool_size=1&initial_pool_size=1")

# ORM layer, mirroring (creme dao)'s define-dao / Sequel::Model: a
# Granite::Base model gives us the same declarative create!/find/update!/
# delete!/all/count surface, rather than hand-written SQL.
class Todo < Granite::Base
  connection sqlite
  table todos

  column id : Int64, primary: true
  column title : String
  column done : Bool = false
end

Todo.adapter.open do |db|
  db.exec "CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, done BOOLEAN NOT NULL DEFAULT 0)"
end

def add_todo!(title : String)
  Todo.create(title: title, done: false)
end

def todo_all
  Todo.all("ORDER BY id")
end

def todo_find(id : Int64)
  Todo.find(id)
end

def todo_count_remaining
  todo_all.count { |row| !row.done }
end

# Mirrors (creme memoize)'s per-row cache in the Scheme version / Ruby's
# ROW_CACHE: cache rendered row markup keyed on exactly (id, done, title),
# so re-rendering the list only recomputes rows whose fields actually changed.
ROW_CACHE = {} of {Int64, Bool, String} => String

def toggle_todo!(id : Int64)
  row = todo_find(id)
  return unless row
  old_done = row.done
  title = row.title
  row.update(done: !old_done)
  ROW_CACHE.delete({id, old_done, title})
end

def delete_todo!(id : Int64)
  row = todo_find(id)
  row.destroy if row
end

class RowView
  getter id, done, title

  def initialize(@id : Int64, @done : Bool, @title : String)
  end

  ECR.def_to_s "#{__DIR__}/../views/row.ecr"
end

def cached_todo_row_html(id : Int64, done : Bool, title : String)
  ROW_CACHE[{id, done, title}] ||= RowView.new(id, done, HTML.escape(title)).to_s
end

CSS = <<-CSS
  body { font-family: sans-serif; }
  .todo-app { max-width: 28rem; margin: 2rem auto; }
  .todos { list-style: none; padding-left: 0; }
  .todos li { display: flex; align-items: center; gap: 0.5rem; padding: 4px 0; }
  .todos li .title { flex: 1; }
  .done .title { text-decoration: line-through; color: #888; }
  form.toggle, form.delete, form.add { display: inline; }
  form.add { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
  CSS

class PageView
  getter css, rows_html, remaining

  def initialize(@css : String, @rows_html : String, @remaining : Int32)
  end

  ECR.def_to_s "#{__DIR__}/../views/page.ecr"
end

def page_html
  rows = todo_all.map { |row| cached_todo_row_html(row.id.not_nil!, row.done, row.title) }.join
  PageView.new(CSS, rows, todo_count_remaining).to_s
end

def todo_json(row : Todo)
  {id: row.id, title: row.title, done: row.done}
end

def todos_json
  todo_all.map { |row| todo_json(row) }.to_json
end

get "/" do |env|
  accept = env.request.headers["Accept"]?
  types = accept ? accept.split(',').map { |t| t.split(';').first.strip } : [] of String
  case types.find { |t| t == "text/html" || t == "application/json" }
  when "text/html"
    env.response.content_type = "text/html"
    page_html
  when "application/json"
    env.response.content_type = "application/json"
    todos_json
  else
    halt env, status_code: 406, response: "Not Acceptable: this route serves text/html or application/json"
  end
end

post "/todos" do |env|
  add_todo!(env.params.body["title"])
  env.redirect "/"
end

post "/todos/:id/complete" do |env|
  toggle_todo!(env.params.url["id"].to_i64)
  env.redirect "/"
end

post "/todos/:id/delete" do |env|
  delete_todo!(env.params.url["id"].to_i64)
  env.redirect "/"
end

add_todo!("Write report")
add_todo!("Review PR")
add_todo!("Ship release")
toggle_todo!(2_i64)

port = ENV.fetch("PORT", "4567").to_i
Kemal.config.host_binding = "127.0.0.1"
Kemal.config.port = port
Kemal.config.logging = false

puts "Serving the todo list at http://127.0.0.1:#{port} (pid #{Process.pid})"
Kemal.run(port, args: [] of String)
