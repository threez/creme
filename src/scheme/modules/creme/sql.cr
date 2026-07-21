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

  # (csv-import! conn table csv-path ['columns '(("name" . "TYPE") ...)]
  #              ['types '(("name" . "TYPE") ...)] ['create-table "SQL"]
  #              ['separator #\x] ['quote #\x]) -> row count
  #
  # Bulk-loads a CSV file straight into a SQLite table via CREATE TABLE IF
  # NOT EXISTS + one prepared INSERT statement reused for every row, all
  # inside a single transaction (the standard fast-bulk-insert pattern --
  # without a transaction, SQLite's default fsync-per-statement behavior
  # makes inserting even a few hundred thousand rows painfully slow). A
  # genuinely native-Crystal alternative to loading the same data through
  # (creme csvquery)'s interpreted engine, for a real apples-to-apples
  # comparison against SQLite's own (C, compiled, query-planned) engine.
  #
  # Without an explicit 'columns alist, column names come from the CSV's
  # own header row and every column is declared TEXT by default --
  # SQLite's manifest typing still converts a numeric-looking TEXT
  # parameter into the column's declared storage class on insert, so
  # getting the right storage class matters for correct numeric
  # comparison/aggregation semantics, not just cosmetically. Three ways to
  # declare it:
  #  - 'columns '(("name" . "TYPE") ...) -- the full column list, name AND
  #    type together, and (matching (creme csvquery)'s own "schema"
  #    clause) implies a HEADERLESS CSV: every row, including the first,
  #    is data.
  #  - 'types '(("name" . "TYPE") ...) -- only for use WITHOUT 'columns:
  #    column names still come from the CSV's own header row (which is
  #    still consumed/skipped as usual), but any name present in this
  #    alist gets its declared TYPE instead of the TEXT default; a header
  #    name not mentioned here still defaults to TEXT. Combining 'types
  #    with 'columns is redundant (columns already declares a type per
  #    column directly) and raises a clear error rather than silently
  #    picking one.
  #  - 'create-table "SQL" -- a fully custom CREATE TABLE statement (any
  #    constraints, indexes-via-DDL, non-default column order, etc.), run
  #    VERBATIM instead of the auto-generated one; its column NAMES must
  #    match whatever csv-import! resolves them to itself (from the
  #    header row, or from 'columns), since the INSERT statement is still
  #    built from that same resolved name list. 'types has no effect on
  #    the actual table then (there's no generated CREATE TABLE for it to
  #    influence) and combining the two raises a clear error rather than
  #    silently ignoring 'types.
  @[Scheme::SchemeFn("csv-import!", min: 3, max: -1)]
  def csv_import(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    conn = sql_connection_arg(args[0], "csv-import!")
    table = sql_str_arg(args[1], "csv-import!")
    path = sql_str_arg(args[2], "csv-import!")
    opts = csv_import_options(args[3..-1], "csv-import!")
    if opts[:columns] && opts[:types]
      raise SchemeRuntimeError.new("csv-import!: 'types cannot be combined with 'columns (which already declares a type per column directly)")
    end
    if opts[:create_table] && opts[:types]
      raise SchemeRuntimeError.new("csv-import!: 'types cannot be combined with 'create-table (there's no generated CREATE TABLE for it to affect)")
    end

    io = File.open(path)
    begin
      parser = Scheme::Csv::Parser.new(io, opts[:separator], opts[:quote], opts[:chunk_size])
      columns, types =
        if cols = opts[:columns]
          {cols.map(&.first), cols.map(&.last)}
        else
          header = parser.next_row
          raise SchemeRuntimeError.new("csv-import!: empty CSV file") unless header
          type_overrides = (opts[:types] || [] of {String, String}).to_h
          {header, header.map { |name| type_overrides[name]? || "TEXT" }}
        end

      quoted_cols = columns.map { |col| %("#{col}") }
      create_sql = opts[:create_table] || "CREATE TABLE IF NOT EXISTS \"#{table}\" (#{quoted_cols.zip(types).map { |col, type| "#{col} #{type}" }.join(", ")})"
      insert_sql = "INSERT INTO \"#{table}\" (#{quoted_cols.join(", ")}) VALUES (#{columns.map { "?" }.join(", ")})"
      conn.writer.exec(create_sql)

      count = 0
      conn.writer.transaction do |tx|
        stmt = tx.connection.build(insert_sql)
        while row = parser.next_row
          stmt.exec(args: row.map(&.as(DB::Any)))
          count += 1
        end
      end
      SchemeInt.new(count.to_i64)
    ensure
      io.close
    end
  rescue ex : Exception
    raise SchemeRuntimeError.new("csv-import!: #{ex.message}")
  end

  private def csv_import_options(rest : Array(SchemeValue), who : String) : {columns: Array({String, String})?, types: Array({String, String})?, create_table: String?, separator: Char, quote: Char, chunk_size: Int32}
    raise SchemeRuntimeError.new("#{who}: keyword arguments must come in 'keyword value pairs") if rest.size.odd?
    columns = nil
    types = nil
    create_table = nil
    separator = ','
    quote = '"'
    chunk_size = Scheme::Csv::DEFAULT_CHUNK_SIZE
    rest.each_slice(2) do |pair|
      key, value = pair[0], pair[1]
      raise SchemeRuntimeError.new("#{who}: expected a keyword symbol, got #{key.write_string}") unless key.is_a?(SchemeSym)
      case key.name
      when "columns"      then columns = csv_import_columns_arg(value, who, "columns")
      when "types"        then types = csv_import_columns_arg(value, who, "types")
      when "create-table" then create_table = sql_str_arg(value, who)
      when "separator"    then separator = csv_import_char_arg(value, who)
      when "quote"        then quote = csv_import_char_arg(value, who)
      when "chunk-size"   then chunk_size = int_arg(value, who).to_i32
      else                     raise SchemeRuntimeError.new("#{who}: unknown keyword '#{key.name} (expected 'columns, 'types, 'create-table, 'separator, 'quote, or 'chunk-size)")
      end
    end
    {columns: columns, types: types, create_table: create_table, separator: separator, quote: quote, chunk_size: chunk_size}
  end

  private def csv_import_columns_arg(v : SchemeValue, who : String, keyword : String) : Array({String, String})
    Scheme.list_to_a(v).map do |entry|
      raise SchemeRuntimeError.new("#{who}: expected an alist of (name . type) pairs for '#{keyword}") unless entry.is_a?(Cons)
      name, type = entry.car, entry.cdr
      raise SchemeRuntimeError.new("#{who}: column name/type must be strings") unless name.is_a?(SchemeStr) && type.is_a?(SchemeStr)
      {name.value, type.value}
    end
  end

  private def csv_import_char_arg(v : SchemeValue, who : String) : Char
    raise SchemeRuntimeError.new("#{who}: expected a character, got #{v.write_string}") unless v.is_a?(SchemeChar)
    v.value
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
