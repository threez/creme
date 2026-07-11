# ===========================================================================
# sql module: SQLite database access
#
# Connections are opaque LispDBConnection values, created by sql:open and
# threaded through sql:execute/query/scalar/close, the same "compile once,
# use many times" shape as regex:compile/LispRegex.
#
# Query results are materialized eagerly into a LispVector of rows, each row
# an alist of (column-name . value), mirroring how json.cr turns a JSON
# object into an alist of (key . value) conses.
# ===========================================================================

require "db"
require "sqlite3"

module LISP
  class LispDBConnection < LispValue
    getter value : DB::Database
    getter uri : String

    def initialize(@value : DB::Database, @uri : String)
    end

    def to_display(io : IO) : Nil
      io << "#<db-connection:" << @uri << '>'
    end
  end

  class Interpreter
    private def install_sql(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("open", 1, 1, ->(args : Array(LispValue)) : LispValue do
        path = sql_str_arg(args[0], "sql:open")
        begin
          LispDBConnection.new(DB.open(sql_uri(path)), path)
        rescue ex : Exception
          raise LispRuntimeError.new("sql:open: #{ex.message}")
        end
      end)

      reg.call("close", 1, 1, ->(args : Array(LispValue)) : LispValue do
        conn = sql_connection_arg(args[0], "sql:close")
        begin
          conn.close
        rescue ex : Exception
          raise LispRuntimeError.new("sql:close: #{ex.message}")
        end
        NIL.as(LispValue)
      end)

      reg.call("execute", 2, -1, ->(args : Array(LispValue)) : LispValue do
        conn = sql_connection_arg(args[0], "sql:execute")
        sql = sql_str_arg(args[1], "sql:execute")
        params = args[2..-1].map { |arg| lisp_to_db_any(arg, "sql:execute") }
        begin
          result = conn.exec(sql, args: params)
          LISP.a_to_list([
            Cons.new(LispStr.new("rows-affected"), LispInt.new(result.rows_affected)).as(LispValue),
            Cons.new(LispStr.new("last-insert-id"), LispInt.new(result.last_insert_id)).as(LispValue),
          ])
        rescue ex : Exception
          raise LispRuntimeError.new("sql:execute: #{ex.message}")
        end
      end)

      reg.call("query", 2, -1, ->(args : Array(LispValue)) : LispValue do
        conn = sql_connection_arg(args[0], "sql:query")
        sql = sql_str_arg(args[1], "sql:query")
        params = args[2..-1].map { |arg| lisp_to_db_any(arg, "sql:query") }
        begin
          rows = [] of LispValue
          conn.query(sql, args: params) do |result_set|
            cols = result_set.column_names
            result_set.each do
              pairs = cols.map { |name| Cons.new(LispStr.new(name), db_any_to_lisp(result_set.read)).as(LispValue) }
              rows << LISP.a_to_list(pairs)
            end
          end
          LispVector.new(rows)
        rescue ex : Exception
          raise LispRuntimeError.new("sql:query: #{ex.message}")
        end
      end)

      reg.call("scalar", 2, -1, ->(args : Array(LispValue)) : LispValue do
        conn = sql_connection_arg(args[0], "sql:scalar")
        sql = sql_str_arg(args[1], "sql:scalar")
        params = args[2..-1].map { |arg| lisp_to_db_any(arg, "sql:scalar") }
        begin
          db_any_to_lisp(conn.scalar(sql, args: params))
        rescue ex : Exception
          raise LispRuntimeError.new("sql:scalar: #{ex.message}")
        end
      end)

      reg.call("connection?", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispBool.of(args[0].is_a?(LispDBConnection))
      end)
    end

    private def sql_uri(path : String) : String
      path == ":memory:" ? "sqlite3://%3Amemory%3A" : "sqlite3://#{path}"
    end

    private def sql_str_arg(v : LispValue, who : String) : String
      raise LispRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(LispStr)
      v.value
    end

    private def sql_connection_arg(v : LispValue, who : String) : DB::Database
      raise LispRuntimeError.new("#{who}: expected db connection, got #{v.write_string}") unless v.is_a?(LispDBConnection)
      v.value
    end

    private def lisp_to_db_any(v : LispValue, who : String) : DB::Any
      case v
      when LispInt   then v.value
      when LispFloat then v.value
      when LispStr   then v.value
      when LispBool  then v.value
      when LispNil   then nil
      when LispChar  then v.value.to_s
      else
        raise LispRuntimeError.new("#{who}: unsupported parameter type: #{v.write_string}")
      end
    end

    private def db_any_to_lisp(v : DB::Any) : LispValue
      case v
      when Int64   then LispInt.new(v)
      when Int32   then LispInt.new(v.to_i64)
      when Float64 then LispFloat.new(v)
      when Float32 then LispFloat.new(v.to_f64)
      when String  then LispStr.new(v)
      when Bool    then LispBool.of(v)
      when Time    then LispStr.new(v.to_s)
      when Bytes   then LispStr.new(String.new(v))
      when Nil     then NIL
      else
        raise LispRuntimeError.new("sql: unsupported column value: #{v.inspect}")
      end
    end
  end
end
