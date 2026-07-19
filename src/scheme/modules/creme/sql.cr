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

module Scheme
  # One sql-open connection's pool(s) — see sql_open's own comment for why
  # a real file gets a genuine reader/writer split (multiple concurrent
  # readers safe under WAL, one serialized writer) while :memory: cannot:
  # `reader` and `writer` are literally the SAME DB::Database there, since
  # a second physical connection to ":memory:" is its own private, empty
  # database (see sql_uri).
  class SqlConnection
    getter writer : DB::Database
    getter reader : DB::Database

    def initialize(@writer : DB::Database, @reader : DB::Database)
    end

    def close : Nil
      writer.close
      reader.close unless reader.same?(writer)
    end
  end
end

module Scheme::Builtins::SqlLibrary
  extend self
  include Scheme::BuiltinHelpers

  # Default reader-pool size for a file-backed connection when sql-open's
  # 'reader keyword argument is omitted — comfortably above this project's
  # own default CRYSTAL_WORKERS-scale concurrency without leaving an
  # unbounded (max_pool_size=0) pool that could open one physical
  # connection per in-flight request under a request spike.
  DEFAULT_MAX_READERS = 8_i64

  # SQLite only ever allows one writer transaction at a time regardless of
  # how many writer connections exist, so 1 is the only value that buys
  # anything — kept overridable (not hardcoded) anyway since 'sql-open
  # takes the same 'reader/'writer keyword shape for both, and forcing a
  # asymmetry there would be a surprising API rather than a real
  # correctness requirement.
  DEFAULT_MAX_WRITERS = 1_i64

  # SQLite's own busy_timeout pragma (milliseconds a connection blocks
  # waiting for a lock before giving up), NOT crystal-db's connection-
  # pool checkout_timeout — different layer, both matter. Without this,
  # a real reader/writer split under real contention gets SQLITE_BUSY
  # back from SQLite immediately, which crystal-db's Pool then retries
  # at its OWN default pace (retry_attempts=1, retry_delay=1.0 SECOND) —
  # so every contended query pays a full extra second. Measured in
  # practice: a file-backed connection with an 8-wide reader pool and no
  # busy_timeout ran at ~460 req/s under concurrent load; the same pool
  # with busy_timeout set ran over 10x faster, because contended readers
  # now wait milliseconds inside SQLite instead of a full second inside
  # crystal-db's retry loop.
  BUSY_TIMEOUT_MS = 5000

  # (sql-open path) / (sql-open path 'reader N) / (sql-open path 'writer N)
  # / (sql-open path 'reader N 'writer N) — same 'keyword value ... pair
  # convention (creme dao)'s todo-create!/-update! use for their own
  # optional arguments. Pool sizes only matter for a real file (see
  # SqlConnection's own comment); passing them for ":memory:" is accepted
  # (so a script that parameterizes pool sizes doesn't need a special case
  # for the ":memory:" path) but has no effect, since ":memory:" is always
  # exactly one connection shared by both roles.
  @[Scheme::SchemeFn("sql-open", min: 1, max: -1)]
  def sql_open(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = sql_str_arg(args[0], "sql-open")
    max_readers, max_writers = sql_pool_sizes(args[1..-1], "sql-open")
    conn =
      if path == ":memory:"
        db = DB.open(memory_uri)
        Scheme::SqlConnection.new(db, db)
      else
        Scheme::SqlConnection.new(DB.open(writer_uri(path, max_writers)), DB.open(reader_uri(path, max_readers)))
      end
    SchemeBox.new("db-connection", conn, "#<db-connection:#{path}>")
  rescue ex : Exception
    raise SchemeRuntimeError.new("sql-open: #{ex.message}")
  end

  # Parses sql-open's trailing 'reader/'writer keyword-value pairs.
  private def sql_pool_sizes(rest : Array(SchemeValue), who : String) : {Int64, Int64}
    raise SchemeRuntimeError.new("#{who}: keyword arguments must come in 'keyword value pairs") if rest.size.odd?
    reader, writer = DEFAULT_MAX_READERS, DEFAULT_MAX_WRITERS
    rest.each_slice(2) do |pair|
      key, value = pair[0], pair[1]
      raise SchemeRuntimeError.new("#{who}: expected a keyword symbol ('reader or 'writer), got #{key.write_string}") unless key.is_a?(SchemeSym)
      n = int_arg(value, who)
      case key.name
      when "reader" then reader = n
      when "writer" then writer = n
      else               raise SchemeRuntimeError.new("#{who}: unknown keyword '#{key.name} (expected 'reader or 'writer)")
      end
    end
    {reader, writer}
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
    result = conn.writer.exec(sql, args: params)
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
    conn.reader.query(sql, args: params) do |result_set|
      # Column names are identical for every row, so build each key string
      # ONCE and share it across all rows' alists instead of allocating a
      # fresh SchemeStr per cell (the driver's biggest per-row allocation on
      # a large result set). Callers treat these keys as read-only alist
      # keys — the row shape contract never promised distinct key objects.
      keys = result_set.column_names.map { |name| SchemeStr.new(name).as(SchemeValue) }
      result_set.each do
        pairs = keys.map { |key| Cons.new(key, db_any_to_scheme(result_set.read)).as(SchemeValue) }
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
    db_any_to_scheme(conn.reader.scalar(sql, args: params))
  rescue ex : Exception
    raise SchemeRuntimeError.new("sql-scalar: #{ex.message}")
  end

  @[Scheme::SchemeFn("sql-connection?", min: 1, max: 1)]
  def sql_connection_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "db-connection")
  end

  # crystal-db's connection pool defaults to max_pool_size=0 (unlimited) —
  # fine for a real file, where every pooled connection opens the SAME
  # file, but fatal for :memory:, where each physical SQLite connection is
  # its OWN private, empty in-memory database. Under enough concurrent
  # query load the pool WILL open more than one connection, and any query
  # landing on connection #2+ sees a database with no tables at all
  # (reproduced in practice as "no such table" errors under concurrent
  # request load once mux-listen! gave each request its own Interpreter —
  # see competition/results.md). Forcing the pool to exactly one
  # connection makes every query for a given sql-open ":memory:" call
  # land on the same physical connection, matching what "one shared
  # in-memory database" actually requires — and rules out a genuine
  # reader/writer split too, since a second physical connection is a
  # second, disconnected in-memory database regardless of role.
  private def memory_uri : String
    "sqlite3://%3Amemory%3A?initial_pool_size=1&max_pool_size=1"
  end

  # WAL (write-ahead log) journal mode is what makes a real file's
  # reader/writer split actually safe and useful: under WAL, readers never
  # block the writer and the writer never blocks readers (each reader sees
  # a consistent snapshot as of when its statement started) — under the
  # default rollback-journal mode, a writer holds an exclusive lock over
  # the whole file for the duration of its transaction, so concurrent
  # "readers" would just serialize behind it anyway and multiple reader
  # connections would buy nothing.
  private def writer_uri(path : String, max_writers : Int64) : String
    "sqlite3://#{path}?journal_mode=WAL&busy_timeout=#{BUSY_TIMEOUT_MS}&initial_pool_size=1&max_pool_size=#{max_writers}"
  end

  # SQLite itself only ever allows one writer at a time no matter how the
  # writer pool above is sized — the default (1) just means crystal-db's
  # own Mutex+Channel queues concurrent writers instead of each one
  # retrying against SQLITE_BUSY. The reader pool has no such ceiling:
  # under WAL, N concurrent readers are genuinely safe, so max_readers is
  # caller-tunable (sql-open's 'reader keyword argument) rather than fixed.
  private def reader_uri(path : String, max_readers : Int64) : String
    "sqlite3://#{path}?journal_mode=WAL&busy_timeout=#{BUSY_TIMEOUT_MS}&max_pool_size=#{max_readers}"
  end

  private def sql_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end

  private def sql_connection_arg(v : SchemeValue, who : String) : Scheme::SqlConnection
    raise SchemeRuntimeError.new("#{who}: expected db connection, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "db-connection"
    v.get(Scheme::SqlConnection)
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
