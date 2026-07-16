# ===========================================================================
# sql module: SQLite database access
#
# Connections are opaque SchemeBox values (tag "db-connection"), created by
# sql-open and threaded through sql-execute/query/scalar/close, the same
# "compile once, use many times" shape as regexp.
#
# Query results are materialized eagerly into a SchemeVector of rows, each row
# an alist of (column-name . value), mirroring how json.cr turns a JSON
# object into an alist of (key . value) conses.
# ===========================================================================

require "db"
require "sqlite3"

module Scheme::Builtins::SqlLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("sql-open", min: 1, max: 1)]
  def sql_open(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = sql_str_arg(args[0], "sql-open")
    SchemeBox.new("db-connection", DB.open(sql_uri(path)), "#<db-connection:#{path}>")
  rescue ex : Exception
    raise SchemeRuntimeError.new("sql-open: #{ex.message}")
  end

  @[Scheme::SchemeFn("sql-close", min: 1, max: 1)]
  def sql_close(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    conn = sql_connection_arg(args[0], "sql-close")
    begin
      conn.close
    rescue ex : Exception
      raise SchemeRuntimeError.new("sql-close: #{ex.message}")
    end
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("sql-execute", min: 2, max: -1)]
  def sql_execute(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    conn = sql_connection_arg(args[0], "sql-execute")
    sql = sql_str_arg(args[1], "sql-execute")
    params = args[2..-1].map { |arg| lisp_to_db_any(arg, "sql-execute") }
    result = conn.exec(sql, args: params)
    Scheme.a_to_list([
      Cons.new(SchemeStr.new("rows-affected"), SchemeInt.new(result.rows_affected)).as(SchemeValue),
      Cons.new(SchemeStr.new("last-insert-id"), SchemeInt.new(result.last_insert_id)).as(SchemeValue),
    ])
  rescue ex : Exception
    raise SchemeRuntimeError.new("sql-execute: #{ex.message}")
  end

  @[Scheme::SchemeFn("sql-query", min: 2, max: -1)]
  def sql_query(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    conn = sql_connection_arg(args[0], "sql-query")
    sql = sql_str_arg(args[1], "sql-query")
    params = args[2..-1].map { |arg| lisp_to_db_any(arg, "sql-query") }
    rows = [] of SchemeValue
    conn.query(sql, args: params) do |result_set|
      cols = result_set.column_names
      result_set.each do
        pairs = cols.map { |name| Cons.new(SchemeStr.new(name), db_any_to_scheme(result_set.read)).as(SchemeValue) }
        rows << Scheme.a_to_list(pairs)
      end
    end
    SchemeVector.new(rows)
  rescue ex : Exception
    raise SchemeRuntimeError.new("sql-query: #{ex.message}")
  end

  @[Scheme::SchemeFn("sql-scalar", min: 2, max: -1)]
  def sql_scalar(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    conn = sql_connection_arg(args[0], "sql-scalar")
    sql = sql_str_arg(args[1], "sql-scalar")
    params = args[2..-1].map { |arg| lisp_to_db_any(arg, "sql-scalar") }
    db_any_to_scheme(conn.scalar(sql, args: params))
  rescue ex : Exception
    raise SchemeRuntimeError.new("sql-scalar: #{ex.message}")
  end

  @[Scheme::SchemeFn("sql-connection?", min: 1, max: 1)]
  def sql_connection_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "db-connection")
  end

  private def sql_uri(path : String) : String
    path == ":memory:" ? "sqlite3://%3Amemory%3A" : "sqlite3://#{path}"
  end

  private def sql_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end

  private def sql_connection_arg(v : SchemeValue, who : String) : DB::Database
    raise SchemeRuntimeError.new("#{who}: expected db connection, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "db-connection"
    v.get(DB::Database)
  end

  private def lisp_to_db_any(v : SchemeValue, who : String) : DB::Any
    case v
    when SchemeInt   then v.value
    when SchemeFloat then v.value
    when SchemeStr   then v.value
    when SchemeBool  then v.value?
    when SchemeNil   then nil
    when SchemeChar  then v.value.to_s
    else
      raise SchemeRuntimeError.new("#{who}: unsupported parameter type: #{v.write_string}")
    end
  end

  private def db_any_to_scheme(v : DB::Any) : SchemeValue
    Scheme.to_scheme(v)
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "sql"], Scheme::Builtins::SqlLibrary
  end
end
