# ===========================================================================
# sxql module: SQL statement builder DSL (ported from Common Lisp's sxql)
#
# Statements/clauses/conditions are plain Lisp data: tagged lists whose first
# element is a LispSym naming the tag (e.g. (= age 18), (and c1 c2), a built
# statement is an alist of (key . value) pairs) -- no new opaque value type,
# so builder values print/inspect naturally, mirroring how json.cr uses
# alists for object-shaped data.
#
# The one rendering rule that matters: a LispSym operand renders as raw SQL
# text (an identifier); anything else becomes a bound `?` parameter. DDL
# column name/type/default text is a separate always-raw-text path, since
# SQL has no syntax for binding an identifier or a type.
# ===========================================================================

module LISP
  class Interpreter
    private def install_sxql(env : Env) : Nil
      # sxql has many small builtins whose renderers do type-narrowing casts;
      # wrap every one here once instead of repeating begin/rescue per closure.
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx) do |args|
          begin
            fn.call(args)
          rescue ex : LispError
            raise ex
          rescue ex : Exception
            raise LispRuntimeError.new("sxql:#{name}: #{ex.message}")
          end
        end)
      end

      # ---- Statement builders ----

      reg.call("select", 1, -1, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("select").as(LispValue)
        h["fields"] = args[0]
        sxql_fold_clauses(h, args[1..-1], "sxql:select")
        sxql_statement(h)
      end)

      reg.call("insert-into", 1, -1, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("insert-into").as(LispValue)
        h["table"] = args[0]
        sxql_fold_clauses(h, args[1..-1], "sxql:insert-into")
        sxql_statement(h)
      end)

      reg.call("update", 1, -1, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("update").as(LispValue)
        h["table"] = args[0]
        sxql_fold_clauses(h, args[1..-1], "sxql:update")
        sxql_statement(h)
      end)

      reg.call("delete-from", 1, -1, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("delete-from").as(LispValue)
        h["table"] = args[0]
        sxql_fold_clauses(h, args[1..-1], "sxql:delete-from")
        sxql_statement(h)
      end)

      reg.call("union", 1, -1, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("union").as(LispValue)
        h["kind"] = LispStr.new("UNION").as(LispValue)
        h["statements"] = LISP.a_to_list(args)
        sxql_statement(h)
      end)

      reg.call("union-all", 1, -1, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("union").as(LispValue)
        h["kind"] = LispStr.new("UNION ALL").as(LispValue)
        h["statements"] = LISP.a_to_list(args)
        sxql_statement(h)
      end)

      # ---- Query clauses ----

      reg.call("from", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("from", [args[0]]) })
      reg.call("where", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("where", [args[0]]) })
      reg.call("having", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("having", [args[0]]) })
      reg.call("order-by", 1, -1, ->(args : Array(LispValue)) : LispValue { sxql_node("order-by", args) })
      reg.call("group-by", 1, -1, ->(args : Array(LispValue)) : LispValue { sxql_node("group-by", args) })
      reg.call("limit", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("limit", [args[0]]) })
      reg.call("offset", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("offset", [args[0]]) })
      reg.call("join", 2, 2, ->(args : Array(LispValue)) : LispValue { sxql_node("join", args) })
      reg.call("left-join", 2, 2, ->(args : Array(LispValue)) : LispValue { sxql_node("left-join", args) })
      reg.call("distinct", 0, 0, ->(_args : Array(LispValue)) : LispValue { sxql_node("distinct", [] of LispValue) })
      reg.call("asc", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("asc", [args[0]]) })
      reg.call("desc", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("desc", [args[0]]) })

      # ---- Write clauses ----

      reg.call("set=", 2, -1, ->(args : Array(LispValue)) : LispValue do
        raise LispRuntimeError.new("sxql:set=: expected an even number of column/value arguments") if args.size.odd?
        pairs = [] of LispValue
        i = 0
        while i < args.size
          pairs << Cons.new(args[i], args[i + 1]).as(LispValue)
          i += 2
        end
        sxql_node("set", pairs)
      end)

      reg.call("on-conflict-do-nothing", 0, -1, ->(args : Array(LispValue)) : LispValue { sxql_node("do-nothing", args) })
      reg.call("on-conflict-do-update", 2, 2, ->(args : Array(LispValue)) : LispValue { sxql_node("do-update", args) })
      reg.call("returning", 1, -1, ->(args : Array(LispValue)) : LispValue { sxql_node("returning", args) })

      # ---- Condition / expression operators ----

      ["=", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "%"].each do |op|
        reg.call(op, 2, 2, ->(args : Array(LispValue)) : LispValue { sxql_node(op, args) })
      end
      reg.call("like", 2, 2, ->(args : Array(LispValue)) : LispValue { sxql_node("like", args) })
      reg.call("and", 1, -1, ->(args : Array(LispValue)) : LispValue { sxql_node("and", args) })
      reg.call("or", 1, -1, ->(args : Array(LispValue)) : LispValue { sxql_node("or", args) })
      reg.call("not", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("not", args) })
      reg.call("in", 2, 2, ->(args : Array(LispValue)) : LispValue { sxql_node("in", args) })
      reg.call("not-in", 2, 2, ->(args : Array(LispValue)) : LispValue { sxql_node("not-in", args) })
      reg.call("is-null", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("is-null", args) })
      reg.call("is-not-null", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("is-not-null", args) })
      reg.call("as", 2, 2, ->(args : Array(LispValue)) : LispValue { sxql_node("as", args) })
      reg.call("exists", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("exists", args) })
      reg.call("case", 1, -1, ->(args : Array(LispValue)) : LispValue { sxql_node("case", args) })
      reg.call("when", 2, 2, ->(args : Array(LispValue)) : LispValue { sxql_node("when", args) })
      reg.call("else", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("else", args) })
      reg.call("raw", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("raw", args) })

      # ---- DDL: create-table / column constraints ----

      reg.call("create-table", 2, -1, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("create-table").as(LispValue)
        h["table"] = args[0]
        h["columns"] = args[1]
        args[2..-1].each do |opt|
          case sxql_tag_name(opt)
          when "if-not-exists" then h["if-not-exists"] = TRUE.as(LispValue)
          else                      raise LispRuntimeError.new("sxql:create-table: unknown option #{opt.write_string}")
          end
        end
        sxql_statement(h)
      end)

      reg.call("column", 2, -1, ->(args : Array(LispValue)) : LispValue { sxql_node("column", args) })
      reg.call("primary-key", 0, 0, ->(_args : Array(LispValue)) : LispValue { sxql_node("primary-key", [] of LispValue) })
      reg.call("not-null", 0, 0, ->(_args : Array(LispValue)) : LispValue { sxql_node("not-null", [] of LispValue) })
      reg.call("unique", 0, 0, ->(_args : Array(LispValue)) : LispValue { sxql_node("unique", [] of LispValue) })
      reg.call("autoincrement", 0, 0, ->(_args : Array(LispValue)) : LispValue { sxql_node("autoincrement", [] of LispValue) })
      reg.call("default", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("default", args) })
      reg.call("if-not-exists", 0, 0, ->(_args : Array(LispValue)) : LispValue { sxql_node("if-not-exists", [] of LispValue) })
      reg.call("if-exists", 0, 0, ->(_args : Array(LispValue)) : LispValue { sxql_node("if-exists", [] of LispValue) })

      # ---- DDL: drop-table / alter-table ----

      reg.call("drop-table", 1, -1, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("drop-table").as(LispValue)
        h["table"] = args[0]
        args[1..-1].each do |opt|
          case sxql_tag_name(opt)
          when "if-exists" then h["if-exists"] = TRUE.as(LispValue)
          else                  raise LispRuntimeError.new("sxql:drop-table: unknown option #{opt.write_string}")
          end
        end
        sxql_statement(h)
      end)

      reg.call("rename-to", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("rename-to", args) })
      reg.call("add-column", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("add-column", args) })
      reg.call("rename-column", 2, 2, ->(args : Array(LispValue)) : LispValue { sxql_node("rename-column", args) })
      reg.call("drop-column", 1, 1, ->(args : Array(LispValue)) : LispValue { sxql_node("drop-column", args) })

      reg.call("alter-table", 2, 2, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("alter-table").as(LispValue)
        h["table"] = args[0]
        h["clause"] = args[1]
        sxql_statement(h)
      end)

      # ---- DDL: create-index / drop-index ----

      reg.call("create-index", 3, -1, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("create-index").as(LispValue)
        h["name"] = args[0]
        h["table"] = args[1]
        h["columns"] = args[2]
        args[3..-1].each do |opt|
          case sxql_tag_name(opt)
          when "unique"        then h["unique"] = TRUE.as(LispValue)
          when "if-not-exists" then h["if-not-exists"] = TRUE.as(LispValue)
          else                      raise LispRuntimeError.new("sxql:create-index: unknown option #{opt.write_string}")
          end
        end
        sxql_statement(h)
      end)

      reg.call("drop-index", 1, -1, ->(args : Array(LispValue)) : LispValue do
        h = {} of String => LispValue
        h["type"] = LispSym.of("drop-index").as(LispValue)
        h["name"] = args[0]
        args[1..-1].each do |opt|
          case sxql_tag_name(opt)
          when "if-exists" then h["if-exists"] = TRUE.as(LispValue)
          else                  raise LispRuntimeError.new("sxql:drop-index: unknown option #{opt.write_string}")
          end
        end
        sxql_statement(h)
      end)

      # ---- Render ----

      reg.call("yield", 1, 1, ->(args : Array(LispValue)) : LispValue do
        params = [] of LispValue
        sql = render_statement(args[0], params)
        LISP.a_to_list([LispStr.new(sql).as(LispValue), LISP.a_to_list(params)])
      end)
    end

    # ---- Tagged-node helpers ----
    #
    # Every clause/condition/statement is a proper list `(tag payload...)`
    # where tag is a LispSym; a built statement is an alist `((key . val) ...)`
    # with LispSym keys, distinct from the tagged-node shape.

    private def sxql_node(tag : String, payload : Array(LispValue)) : LispValue
      LISP.a_to_list([LispSym.of(tag).as(LispValue)] + payload)
    end

    private def sxql_tag_name(v : LispValue) : String?
      return nil unless v.is_a?(Cons)
      car = v.car
      car.is_a?(LispSym) ? car.name : nil
    end

    private def sxql_payload(v : LispValue) : Array(LispValue)
      LISP.list_to_a(v)[1..-1]
    end

    private def sxql_statement(h : Hash(String, LispValue)) : LispValue
      LISP.a_to_list(h.map { |k, v| Cons.new(LispSym.of(k), v).as(LispValue) }.to_a)
    end

    private def sxql_get(stmt : LispValue, key : String) : LispValue?
      return nil unless stmt.is_a?(Cons)
      LISP.list_to_a(stmt).each do |pair|
        next unless pair.is_a?(Cons)
        k = pair.car
        return pair.cdr if k.is_a?(LispSym) && k.name == key
      end
      nil
    end

    private def sxql_require(stmt : LispValue, key : String, who : String) : LispValue
      sxql_get(stmt, key) || raise LispRuntimeError.new("#{who}: missing '#{key}' in #{stmt.write_string}")
    end

    private def sxql_type(stmt : LispValue) : String
      t = sxql_get(stmt, "type")
      raise LispRuntimeError.new("sxql:yield: expected a built statement, got #{stmt.write_string}") unless t.is_a?(LispSym)
      t.name
    end

    # Folds sxql:from/where/order-by/... clause nodes into a statement's
    # accumulator hash. Repeated where/having AND-compose; repeated
    # order-by/group-by append; joins accumulate in call order.
    private def sxql_fold_clauses(h : Hash(String, LispValue), clauses : Array(LispValue), who : String) : Nil
      clauses.each do |clause|
        tag = sxql_tag_name(clause)
        raise LispRuntimeError.new("#{who}: expected a clause, got #{clause.write_string}") unless tag
        payload = sxql_payload(clause)
        case tag
        when "from"
          h["from"] = payload[0]
        when "where", "having"
          h[tag] = (existing = h[tag]?) ? sxql_node("and", [existing, payload[0]]) : payload[0]
        when "order-by", "group-by"
          prior = h[tag]? ? LISP.list_to_a(h[tag]) : [] of LispValue
          h[tag] = LISP.a_to_list(prior + payload)
        when "limit", "offset"
          h[tag] = payload[0]
        when "join", "left-join"
          kind = tag == "join" ? "INNER" : "LEFT"
          joins = h["joins"]? ? LISP.list_to_a(h["joins"]) : [] of LispValue
          joins << sxql_node("join", [LispStr.new(kind).as(LispValue), payload[0], payload[1]])
          h["joins"] = LISP.a_to_list(joins)
        when "distinct"
          h["distinct"] = TRUE.as(LispValue)
        when "set"
          h["set"] = LISP.a_to_list(payload)
        when "do-nothing"
          h["on-conflict"] = sxql_node("do-nothing", payload)
        when "do-update"
          h["on-conflict"] = sxql_node("do-update", payload)
        when "returning"
          h["returning"] = LISP.a_to_list(payload)
        else
          raise LispRuntimeError.new("#{who}: unrecognized clause '#{tag}'")
        end
      end
    end

    # ---- Rendering: statement dispatch ----

    private def render_statement(stmt : LispValue, params : Array(LispValue)) : String
      case sxql_type(stmt)
      when "select"       then render_select(stmt, params)
      when "insert-into"  then render_insert(stmt, params)
      when "update"       then render_update(stmt, params)
      when "delete-from"  then render_delete(stmt, params)
      when "union"        then render_union(stmt, params)
      when "create-table" then render_create_table(stmt)
      when "drop-table"   then render_drop_table(stmt)
      when "alter-table"  then render_alter_table(stmt)
      when "create-index" then render_create_index(stmt)
      when "drop-index"   then render_drop_index(stmt)
      else
        raise LispRuntimeError.new("sxql:yield: unknown statement type '#{sxql_type(stmt)}'")
      end
    end

    private def render_select(stmt : LispValue, params : Array(LispValue)) : String
      fields = LISP.list_to_a(sxql_require(stmt, "fields", "sxql:yield"))
      sql = String::Builder.new
      sql << "SELECT "
      sql << "DISTINCT " if sxql_get(stmt, "distinct")
      sql << fields.map { |field| render_expr(field, params) }.join(", ")
      if from = sxql_get(stmt, "from")
        sql << " FROM " << render_expr(from, params)
      end
      if joins = sxql_get(stmt, "joins")
        LISP.list_to_a(joins).each do |j|
          jp = sxql_payload(j)
          sql << " #{jp[0].as(LispStr).value} JOIN " << render_expr(jp[1], params) << " ON " << render_expr(jp[2], params)
        end
      end
      if where = sxql_get(stmt, "where")
        sql << " WHERE " << render_expr(where, params)
      end
      if group_by = sxql_get(stmt, "group-by")
        sql << " GROUP BY " << LISP.list_to_a(group_by).map { |col| render_expr(col, params) }.join(", ")
      end
      if having = sxql_get(stmt, "having")
        sql << " HAVING " << render_expr(having, params)
      end
      if order_by = sxql_get(stmt, "order-by")
        sql << " ORDER BY " << LISP.list_to_a(order_by).map { |item| render_order_item(item, params) }.join(", ")
      end
      if limit = sxql_get(stmt, "limit")
        sql << " LIMIT " << render_expr(limit, params)
      end
      if offset = sxql_get(stmt, "offset")
        sql << " OFFSET " << render_expr(offset, params)
      end
      sql.to_s
    end

    private def render_order_item(o : LispValue, params : Array(LispValue)) : String
      case sxql_tag_name(o)
      when "asc"  then "#{render_expr(sxql_payload(o)[0], params)} ASC"
      when "desc" then "#{render_expr(sxql_payload(o)[0], params)} DESC"
      else             render_expr(o, params)
      end
    end

    private def render_insert(stmt : LispValue, params : Array(LispValue)) : String
      table = sxql_require(stmt, "table", "sxql:yield")
      set_node = sxql_get(stmt, "set") || raise LispRuntimeError.new("sxql:yield: insert-into requires sxql:set=")
      set_pairs = LISP.list_to_a(set_node)
      cols = set_pairs.map { |pair| pair.as(Cons).car.as(LispSym).name }
      placeholders = set_pairs.map { |pair| render_expr(pair.as(Cons).cdr, params) }
      sql = String::Builder.new
      sql << "INSERT INTO " << render_expr(table, params) << " (" << cols.join(", ") << ") VALUES (" << placeholders.join(", ") << ")"
      if oc = sxql_get(stmt, "on-conflict")
        sql << " " << render_on_conflict(oc, params)
      end
      if returning = sxql_get(stmt, "returning")
        sql << " RETURNING " << LISP.list_to_a(returning).map { |col| render_expr(col, params) }.join(", ")
      end
      sql.to_s
    end

    private def render_on_conflict(node : LispValue, params : Array(LispValue)) : String
      tag = sxql_tag_name(node) || raise LispRuntimeError.new("sxql:yield: invalid on-conflict node #{node.write_string}")
      payload = sxql_payload(node)
      case tag
      when "do-nothing"
        payload.empty? ? "ON CONFLICT DO NOTHING" : "ON CONFLICT (#{payload.map { |col| render_expr(col, params) }.join(", ")}) DO NOTHING"
      when "do-update"
        target_cols = LISP.list_to_a(payload[0]).map { |col| render_expr(col, params) }.join(", ")
        set_pairs = sxql_payload(payload[1])
        assigns = set_pairs.map { |pair| "#{pair.as(Cons).car.as(LispSym).name} = #{render_expr(pair.as(Cons).cdr, params)}" }.join(", ")
        "ON CONFLICT (#{target_cols}) DO UPDATE SET #{assigns}"
      else
        raise LispRuntimeError.new("sxql:yield: unknown on-conflict kind '#{tag}'")
      end
    end

    private def render_update(stmt : LispValue, params : Array(LispValue)) : String
      table = sxql_require(stmt, "table", "sxql:yield")
      set_node = sxql_get(stmt, "set") || raise LispRuntimeError.new("sxql:yield: update requires sxql:set=")
      set_pairs = LISP.list_to_a(set_node)
      assigns = set_pairs.map { |pair| "#{pair.as(Cons).car.as(LispSym).name} = #{render_expr(pair.as(Cons).cdr, params)}" }.join(", ")
      sql = String::Builder.new
      sql << "UPDATE " << render_expr(table, params) << " SET " << assigns
      if where = sxql_get(stmt, "where")
        sql << " WHERE " << render_expr(where, params)
      end
      if returning = sxql_get(stmt, "returning")
        sql << " RETURNING " << LISP.list_to_a(returning).map { |col| render_expr(col, params) }.join(", ")
      end
      sql.to_s
    end

    private def render_delete(stmt : LispValue, params : Array(LispValue)) : String
      table = sxql_require(stmt, "table", "sxql:yield")
      sql = String::Builder.new
      sql << "DELETE FROM " << render_expr(table, params)
      if where = sxql_get(stmt, "where")
        sql << " WHERE " << render_expr(where, params)
      end
      if returning = sxql_get(stmt, "returning")
        sql << " RETURNING " << LISP.list_to_a(returning).map { |col| render_expr(col, params) }.join(", ")
      end
      sql.to_s
    end

    private def render_union(stmt : LispValue, params : Array(LispValue)) : String
      kind = sxql_require(stmt, "kind", "sxql:yield").as(LispStr).value
      stmts = LISP.list_to_a(sxql_require(stmt, "statements", "sxql:yield"))
      stmts.map { |sub_stmt| render_statement(sub_stmt, params) }.join(" #{kind} ")
    end

    # ---- Rendering: DDL (always raw text, never parameterized) ----

    private def render_create_table(stmt : LispValue) : String
      table = sxql_require(stmt, "table", "sxql:yield").as(LispSym).name
      columns = LISP.list_to_a(sxql_require(stmt, "columns", "sxql:yield"))
      if_not_exists = sxql_get(stmt, "if-not-exists") ? "IF NOT EXISTS " : ""
      "CREATE TABLE #{if_not_exists}#{table} (#{columns.map { |col| render_column_def(col) }.join(", ")})"
    end

    private def render_column_def(node : LispValue) : String
      payload = sxql_payload(node)
      name = payload[0].as(LispSym).name
      type = payload[1].as(LispStr).value
      constraints = payload[2..-1].map { |constraint| render_column_constraint(constraint) }
      ([name, type] + constraints).join(" ")
    end

    private def render_column_constraint(node : LispValue) : String
      tag = sxql_tag_name(node) || raise LispRuntimeError.new("sxql:column: invalid constraint #{node.write_string}")
      case tag
      when "primary-key"   then "PRIMARY KEY"
      when "not-null"      then "NOT NULL"
      when "unique"        then "UNIQUE"
      when "autoincrement" then "AUTOINCREMENT"
      when "default"       then "DEFAULT #{render_literal(sxql_payload(node)[0])}"
      else
        raise LispRuntimeError.new("sxql:column: unknown constraint '#{tag}'")
      end
    end

    private def render_drop_table(stmt : LispValue) : String
      table = sxql_require(stmt, "table", "sxql:yield").as(LispSym).name
      if_exists = sxql_get(stmt, "if-exists") ? "IF EXISTS " : ""
      "DROP TABLE #{if_exists}#{table}"
    end

    private def render_alter_table(stmt : LispValue) : String
      table = sxql_require(stmt, "table", "sxql:yield").as(LispSym).name
      clause = sxql_require(stmt, "clause", "sxql:yield")
      tag = sxql_tag_name(clause) || raise LispRuntimeError.new("sxql:alter-table: invalid clause #{clause.write_string}")
      payload = sxql_payload(clause)
      action =
        case tag
        when "rename-to"     then "RENAME TO #{payload[0].as(LispSym).name}"
        when "add-column"    then "ADD COLUMN #{render_column_def(payload[0])}"
        when "rename-column" then "RENAME COLUMN #{payload[0].as(LispSym).name} TO #{payload[1].as(LispSym).name}"
        when "drop-column"   then "DROP COLUMN #{payload[0].as(LispSym).name}"
        else
          raise LispRuntimeError.new("sxql:alter-table: unknown clause '#{tag}'")
        end
      "ALTER TABLE #{table} #{action}"
    end

    private def render_create_index(stmt : LispValue) : String
      name = sxql_require(stmt, "name", "sxql:yield").as(LispSym).name
      table = sxql_require(stmt, "table", "sxql:yield").as(LispSym).name
      cols = LISP.list_to_a(sxql_require(stmt, "columns", "sxql:yield")).map { |col| col.as(LispSym).name }.join(", ")
      unique = sxql_get(stmt, "unique") ? "UNIQUE " : ""
      if_not_exists = sxql_get(stmt, "if-not-exists") ? "IF NOT EXISTS " : ""
      "CREATE #{unique}INDEX #{if_not_exists}#{name} ON #{table} (#{cols})"
    end

    private def render_drop_index(stmt : LispValue) : String
      name = sxql_require(stmt, "name", "sxql:yield").as(LispSym).name
      if_exists = sxql_get(stmt, "if-exists") ? "IF EXISTS " : ""
      "DROP INDEX #{if_exists}#{name}"
    end

    # ---- Rendering: expressions/conditions ----
    #
    # The core rule: a LispSym operand is a raw identifier; anything else is
    # a bound parameter. Recognized operator tags recurse; an unrecognized
    # plain list is treated as a value list (e.g. the rhs of :in).

    private def render_expr(node : LispValue, params : Array(LispValue)) : String
      case node
      when LispSym
        node.name
      when Cons
        tag = sxql_tag_name(node)
        if tag
          render_operator(tag, sxql_payload(node), params)
        else
          "(" + LISP.list_to_a(node).map { |v| render_expr(v, params) }.join(", ") + ")"
        end
      else
        params << node
        "?"
      end
    end

    private def render_operator(tag : String, payload : Array(LispValue), params : Array(LispValue)) : String
      case tag
      when "=", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "%"
        "#{render_expr(payload[0], params)} #{tag} #{render_expr(payload[1], params)}"
      when "like"
        "#{render_expr(payload[0], params)} LIKE #{render_expr(payload[1], params)}"
      when "and"
        "(" + payload.map { |cond| render_expr(cond, params) }.join(" AND ") + ")"
      when "or"
        "(" + payload.map { |cond| render_expr(cond, params) }.join(" OR ") + ")"
      when "not"
        "NOT (#{render_expr(payload[0], params)})"
      when "in", "not-in"
        col = render_expr(payload[0], params)
        vals = LISP.list_to_a(payload[1]).map { |v| render_expr(v, params) }.join(", ")
        "#{col} #{tag == "in" ? "IN" : "NOT IN"} (#{vals})"
      when "is-null"
        "#{render_expr(payload[0], params)} IS NULL"
      when "is-not-null"
        "#{render_expr(payload[0], params)} IS NOT NULL"
      when "as"
        "#{render_expr(payload[0], params)} AS #{render_expr(payload[1], params)}"
      when "exists"
        "EXISTS (#{render_statement(payload[0], params)})"
      when "case"
        render_case(payload, params)
      when "raw"
        payload[0].as(LispStr).value
      else
        raise LispRuntimeError.new("sxql:yield: unknown operator '#{tag}'")
      end
    end

    private def render_case(payload : Array(LispValue), params : Array(LispValue)) : String
      parts = ["CASE"]
      payload.each do |clause|
        tag = sxql_tag_name(clause)
        cp = sxql_payload(clause)
        case tag
        when "when" then parts << "WHEN #{render_expr(cp[0], params)} THEN #{render_expr(cp[1], params)}"
        when "else" then parts << "ELSE #{render_expr(cp[0], params)}"
        else
          raise LispRuntimeError.new("sxql:case: expected sxql:when/sxql:else, got #{clause.write_string}")
        end
      end
      parts << "END"
      parts.join(" ")
    end

    # Inline SQL literal for contexts where a bind parameter isn't valid
    # syntax (DDL column DEFAULT). A bare symbol passes through as raw text
    # so keyword defaults like CURRENT_TIMESTAMP can be expressed.
    private def render_literal(v : LispValue) : String
      case v
      when LispStr   then "'" + v.value.gsub("'", "''") + "'"
      when LispInt   then v.value.to_s
      when LispFloat then v.display_string
      when LispBool  then v.value ? "1" : "0"
      when LispNil   then "NULL"
      when LispSym   then v.name
      else
        raise LispRuntimeError.new("sxql:column: cannot use #{v.write_string} as a DEFAULT literal")
      end
    end
  end
end
