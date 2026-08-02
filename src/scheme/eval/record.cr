# ===========================================================================
# define-record-type
# ===========================================================================

module Scheme
  # Pure parse of a define-record-type form's own NAMES (type/constructor/
  # predicate/accessors/mutators) — no evaluation, mirrors eval_define_
  # record_type's own parsing exactly, in the same order it calls
  # env.define. Used by the bytecode compiler to pre-declare local
  # registers for a define-record-type used INSIDE a function body (a real
  # R7RS pattern — see spec/scheme/eval/record_spec.cr's "distinct
  # invocations produce disjoint types" — since each call must produce a
  # fresh SchemeRecordType, this can't be hoisted to a single top-level
  # define the way most local-scope restrictions in this VM are sidestepped).
  # Returns nil on anything malformed rather than raising — a malformed
  # define-record-type still surfaces its real error at eval time (from
  # eval_define_record_type itself), matching this codebase's "analyze-time-
  # detected errors surface only when reached" convention.
  def self.record_type_names(form : Cons) : Array(String)?
    parts = Scheme.list_to_a(form.cdr)
    return nil unless parts.size >= 3
    type_name_form = parts[0]
    type_name = type_name_form.is_a?(SchemeSym) ? type_name_form.name : type_name_form.write_string
    ctor_spec = Scheme.list_to_a(parts[1])
    return nil if ctor_spec.empty?
    ctor_name = ctor_spec[0]
    return nil unless ctor_name.is_a?(SchemeSym)
    pred_name = parts[2]
    return nil unless pred_name.is_a?(SchemeSym)
    names = [type_name, ctor_name.name, pred_name.name]
    parts[3..].each do |spec|
      spec_parts = Scheme.list_to_a(spec)
      return nil unless spec_parts.size == 2 || spec_parts.size == 3
      accessor = spec_parts[1]
      return nil unless accessor.is_a?(SchemeSym)
      names << accessor.name
      if spec_parts.size == 3
        mutator = spec_parts[2]
        return nil unless mutator.is_a?(SchemeSym)
        names << mutator.name
      end
    end
    names
  end

  # Describes one (define-record-type ...) invocation. Each invocation
  # produces its own SchemeRecordType instance, so predicates generated for
  # distinct define-record-type forms never cross-match even if they share a
  # type name (disjoint types, per R7RS).
  class SchemeRecordType
    include SchemeBaseValue
    getter name : String
    getter field_names : Array(String)

    def initialize(@name : String, @field_names : Array(String))
    end

    def to_display(io : IO) : Nil
      io << "#<record-type:" << @name << '>'
    end
  end

  class SchemeRecord
    include SchemeBaseValue
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

  # A record field accessor (the `(field accessor ...)` of a define-record-
  # type) as a dedicated Builtin subtype carrying its target type + field
  # index statically. It IS a Builtin (union member unchanged; its `fn` still
  # works for map/apply/first-class use), but VM#dispatch_call recognizes it
  # and does the type-guard + direct field load inline — skipping the per-call
  # args-array allocation and the generic apply path that every other builtin
  # pays. This is the shape-guarded-accessor idea from the inline-caching
  # literature; the "shape" (record_type) and slot (field_index) are carried
  # by the accessor value itself, so no per-call-site cache is needed.
  class RecordAccessor < Builtin
    getter record_type : SchemeRecordType
    getter field_index : Int32

    def initialize(name : String, @record_type : SchemeRecordType, @field_index : Int32)
      super(name, 1, 1) do |args|
        v = args[0]
        unless v.is_a?(SchemeRecord) && v.type.same?(@record_type)
          raise SchemeRuntimeError.new("#{name}: expected a #{@record_type.name} record, got #{v.write_string}")
        end
        v.fields[@field_index]
      end
    end
  end

  # A record field mutator (the optional third element of a field spec) — the
  # set! counterpart of RecordAccessor, with the same dispatch_call fast path.
  class RecordMutator < Builtin
    getter record_type : SchemeRecordType
    getter field_index : Int32

    def initialize(name : String, @record_type : SchemeRecordType, @field_index : Int32)
      super(name, 2, 2) do |args|
        v = args[0]
        unless v.is_a?(SchemeRecord) && v.type.same?(@record_type)
          raise SchemeRuntimeError.new("#{name}: expected a #{@record_type.name} record, got #{v.write_string}")
        end
        v.fields[@field_index] = args[1]
        NIL.as(SchemeValue)
      end
    end
  end

  # A record constructor (the `(ctor field...)` of a define-record-type) as
  # a dedicated Builtin subtype, the constructor-side counterpart of
  # RecordAccessor/RecordMutator above: VM#dispatch_call recognizes it and
  # builds the SchemeRecord's fields array directly from the call's own
  # stack registers, skipping BOTH the per-call args-array allocation the
  # generic apply path pays AND the field-name lookup
  # (`field_names.map { |fname| ctor_fields.index(fname) }`) the plain-
  # Builtin version used to redo from scratch on every single call —
  # `field_slots` below precomputes that mapping once, at define-record-
  # type time, instead.
  #
  # `field_slots[i]` is the constructor ARGUMENT index (0-based, always <
  # `arity`) that fills record field slot `i`, or nil if that field isn't
  # one of the constructor's own parameters (left NIL in the record,
  # matching plain Builtin constructors' existing behavior for a field
  # declared but omitted from the `(ctor field...)` spec — see
  # record_spec.cr's own coverage of that case). `arity` is `ctor_fields.
  # size` — kept as its own field rather than derived from field_slots
  # (whose length is field_names.size, a different, unrelated count) since
  # nothing about field_slots alone determines it in general (a
  # constructor could legally list fewer fields than the type declares).
  class RecordConstructor < Builtin
    getter record_type : SchemeRecordType
    getter field_slots : Array(Int32?)
    getter arity : Int32

    def initialize(name : String, @record_type : SchemeRecordType, @field_slots : Array(Int32?), @arity : Int32)
      super(name, arity, arity) do |args|
        values = @field_slots.map { |slot| slot ? args[slot] : NIL.as(SchemeValue) }
        SchemeRecord.new(record_type, values).as(SchemeValue)
      end
    end
  end

  # The condition object attached to SchemeError#payload by the `error`
  # builtin (see modules/scheme/base.cr) — a plain SchemeRecord of this type, so
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
    # defines), so its HelperFormNode just calls this helper and returns.
    def eval_define_record_type(expr : Cons, env : Env) : SchemeValue
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

      field_slots = field_names.map { |fname| ctor_fields.index(fname) }
      env.define(ctor_name.name, RecordConstructor.new(ctor_name.name, record_type, field_slots, ctor_fields.size))

      env.define(pred_name.name, Builtin.new(pred_name.name, 1, 1) do |args|
        v = args[0]
        SchemeBool.of(v.is_a?(SchemeRecord) && v.type.same?(record_type)).as(SchemeValue)
      end)

      field_specs.each_with_index do |(_, accessor_name, mutator_name), idx|
        env.define(accessor_name, RecordAccessor.new(accessor_name, record_type, idx))
        if mutator_name
          env.define(mutator_name, RecordMutator.new(mutator_name, record_type, idx))
        end
      end

      type_name_form
    end
  end
end
