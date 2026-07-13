# ===========================================================================
# define-record-type
# ===========================================================================

module Scheme
  # Describes one (define-record-type ...) invocation. Each invocation
  # produces its own SchemeRecordType instance, so predicates generated for
  # distinct define-record-type forms never cross-match even if they share a
  # type name (disjoint types, per R7RS).
  class SchemeRecordType < SchemeValue
    getter name : String
    getter field_names : Array(String)

    def initialize(@name : String, @field_names : Array(String))
    end

    def to_display(io : IO) : Nil
      io << "#<record-type:" << @name << '>'
    end
  end

  class SchemeRecord < SchemeValue
    getter type : SchemeRecordType
    getter fields : Array(SchemeValue)

    def initialize(@type : SchemeRecordType, @fields : Array(SchemeValue))
    end

    def to_display(io : IO) : Nil
      io << '#' << '<' << @type.name
      @type.field_names.each_with_index do |field_name, i|
        io << ' ' << field_name << '=' << @fields[i].display_string
      end
      io << '>'
    end
  end

  # The condition object attached to SchemeError#payload by the `error`
  # builtin (see builtins.cr) — a plain SchemeRecord of this type, so
  # `guard` can hand callers structured access to the message/irritants via
  # the R7RS-standard error-object?/error-object-message/
  # error-object-irritants names, instead of only a joined string.
  CONDITION_TYPE = SchemeRecordType.new("condition", ["message", "irritants"])

  # Distinguishable condition types for file-error?/read-error? — kept
  # separate from CONDITION_TYPE (not "error-object?"-compatible) since
  # R7RS's file-error?/read-error? are independent predicates, not a
  # required subtype of error-object?.
  FILE_ERROR_TYPE = SchemeRecordType.new("file-error", ["message", "irritants"])
  READ_ERROR_TYPE = SchemeRecordType.new("read-error", ["message", "irritants"])

  class Interpreter
    # (define-record-type <name> (ctor field...) pred (field accessor [mutator])...)
    # Defines the type descriptor, constructor, predicate, and each
    # accessor/mutator directly into env, the same way `define` does — this
    # form fully evaluates (no tail position concern, it's a batch of
    # defines), so eval_core just delegates and returns.
    private def eval_define_record_type(expr : Cons, env : Env) : SchemeValue
      parts = Scheme.list_to_a(expr.cdr)
      raise SchemeRuntimeError.new("define-record-type: malformed") unless parts.size >= 3

      type_name_form = parts[0]
      type_name = type_name_form.is_a?(SchemeSym) ? type_name_form.name : type_name_form.write_string

      ctor_spec = Scheme.list_to_a(parts[1])
      raise SchemeRuntimeError.new("define-record-type: malformed constructor spec") if ctor_spec.empty?
      ctor_name = ctor_spec[0]
      raise SchemeRuntimeError.new("define-record-type: constructor name must be a symbol") unless ctor_name.is_a?(SchemeSym)
      ctor_fields = ctor_spec[1..].map do |field|
        raise SchemeRuntimeError.new("define-record-type: constructor field must be a symbol") unless field.is_a?(SchemeSym)
        field.name
      end

      pred_name = parts[2]
      raise SchemeRuntimeError.new("define-record-type: predicate name must be a symbol") unless pred_name.is_a?(SchemeSym)

      field_specs = parts[3..].map do |spec|
        spec_parts = Scheme.list_to_a(spec)
        raise SchemeRuntimeError.new("define-record-type: bad field spec") unless spec_parts.size == 2 || spec_parts.size == 3
        field_name = spec_parts[0]
        raise SchemeRuntimeError.new("define-record-type: field name must be a symbol") unless field_name.is_a?(SchemeSym)
        accessor = spec_parts[1]
        raise SchemeRuntimeError.new("define-record-type: accessor name must be a symbol") unless accessor.is_a?(SchemeSym)
        mutator = spec_parts[2]?
        raise SchemeRuntimeError.new("define-record-type: mutator name must be a symbol") if mutator && !mutator.is_a?(SchemeSym)
        {field_name.name, accessor.name, mutator.as?(SchemeSym).try(&.name)}
      end

      field_names = field_specs.map { |field_name, _, _| field_name }
      ctor_fields.each do |ctor_field|
        raise SchemeRuntimeError.new("define-record-type: constructor field '#{ctor_field}' is not a declared field") unless field_names.includes?(ctor_field)
      end

      record_type = SchemeRecordType.new(type_name, field_names)
      env.define(type_name, record_type)

      env.define(ctor_name.name, Builtin.new(ctor_name.name, ctor_fields.size, ctor_fields.size) do |args|
        values = field_names.map do |fname|
          idx = ctor_fields.index(fname)
          idx ? args[idx] : NIL.as(SchemeValue)
        end
        SchemeRecord.new(record_type, values).as(SchemeValue)
      end)

      env.define(pred_name.name, Builtin.new(pred_name.name, 1, 1) do |args|
        v = args[0]
        SchemeBool.of(v.is_a?(SchemeRecord) && v.type.same?(record_type)).as(SchemeValue)
      end)

      field_specs.each_with_index do |(_, accessor_name, mutator_name), idx|
        env.define(accessor_name, Builtin.new(accessor_name, 1, 1) do |args|
          record_arg(args[0], record_type, accessor_name).fields[idx]
        end)
        if mutator_name
          env.define(mutator_name, Builtin.new(mutator_name, 2, 2) do |args|
            record_arg(args[0], record_type, mutator_name).fields[idx] = args[1]
            NIL.as(SchemeValue)
          end)
        end
      end

      type_name_form
    end

    private def record_arg(v : SchemeValue, record_type : SchemeRecordType, who : String) : SchemeRecord
      unless v.is_a?(SchemeRecord) && v.type.same?(record_type)
        raise SchemeRuntimeError.new("#{who}: expected a #{record_type.name} record, got #{v.write_string}")
      end
      v
    end
  end
end
