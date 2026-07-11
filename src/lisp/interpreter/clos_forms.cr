# ===========================================================================
# defclass / defgeneric / defmethod: special-form parsing for CLOS-lite.
#
# These are recognized unconditionally by eval_core's dispatch (like
# define/defmacro), but only functional after (require 'clos) — otherwise
# they raise. They must be special forms (not builtins) because their
# argument lists are syntax, not evaluated expressions: slot specs contain
# bare symbols standing for slot/reader/writer names, and `defmethod`'s
# specializer list and class name are never quoted.
# ===========================================================================

module LISP
  class Interpreter
    private def require_clos_enabled(who : String) : Nil
      raise LispRuntimeError.new("#{who}: call (require 'clos) first") unless @clos_enabled
    end

    # (defclass name (superclass) ((slot-name slot-option...)...) (:documentation "..."))
    private def eval_defclass(expr : Cons, env : Env) : LispValue
      require_clos_enabled("defclass")
      parts = LISP.list_to_a(expr.cdr)
      raise LispRuntimeError.new("defclass: expects at least a class name") if parts.empty?
      name_sym = parts[0]
      raise LispRuntimeError.new("defclass: class name must be a symbol") unless name_sym.is_a?(LispSym)

      superclass_names = parts.size >= 2 ? LISP.list_to_a(parts[1]).map { |sym| defclass_sym_name(sym) } : [] of String
      raise LispRuntimeError.new("defclass: multiple inheritance is not supported (single inheritance only)") if superclass_names.size > 1
      superclass = superclass_names.empty? ? nil : (@classes[superclass_names[0]]? || raise LispRuntimeError.new("defclass: unknown superclass '#{superclass_names[0]}'"))

      slot_forms = parts.size >= 3 ? LISP.list_to_a(parts[2]) : [] of LispValue
      slots = slot_forms.map { |slot_form| parse_slot_spec(slot_form) }

      klass = LispClass.new(name_sym.name, superclass, slots)
      @classes[name_sym.name] = klass
      env.define(name_sym.name, klass)
      define_slot_accessors(klass, slots)
      name_sym
    end

    private def defclass_sym_name(v : LispValue) : String
      raise LispRuntimeError.new("defclass: expected a symbol, got #{v.write_string}") unless v.is_a?(LispSym)
      v.name
    end

    private def parse_slot_spec(slot_form : LispValue) : SlotSpec
      case slot_form
      when LispSym
        SlotSpec.new(slot_form.name)
      when Cons
        items = LISP.list_to_a(slot_form)
        raise LispRuntimeError.new("defclass: empty slot specifier") if items.empty?
        slot_name = defclass_sym_name(items[0])
        reader, writer, accessor, initarg, initform = parse_slot_options(slot_name, items[1..])
        SlotSpec.new(slot_name, initarg, initform, reader, writer, accessor)
      else
        raise LispRuntimeError.new("defclass: bad slot specifier #{slot_form.write_string}")
      end
    end

    private def parse_slot_options(slot_name : String, options : Array(LispValue))
      raise LispRuntimeError.new("defclass: malformed slot options for '#{slot_name}'") unless options.size.even?
      reader = writer = accessor = initarg = nil
      initform = nil
      i = 0
      while i < options.size
        key = options[i]
        val = options[i + 1]
        raise LispRuntimeError.new("defclass: expected a slot-option keyword, got #{key.write_string}") unless key.is_a?(LispSym) && key.name.starts_with?(':')
        case key.name
        when ":reader"   then reader = defclass_sym_name(val)
        when ":writer"   then writer = defclass_sym_name(val)
        when ":accessor" then accessor = defclass_sym_name(val)
        when ":initarg"
          raise LispRuntimeError.new("defclass: :initarg value must be a keyword, got #{val.write_string}") unless val.is_a?(LispSym) && val.name.starts_with?(':')
          initarg = val.name
        when ":initform" then initform = val
        else                  raise LispRuntimeError.new("defclass: unknown slot option #{key.write_string}")
        end
        i += 2
      end
      {reader, writer, accessor, initarg, initform}
    end

    private def define_slot_accessors(klass : LispClass, slots : Array(SlotSpec)) : Nil
      slots.each do |spec|
        if r = spec.reader
          @global.define_fn(r, 1, 1) { |args| clos_instance_arg(args[0], r).slots[spec.name]? || raise LispRuntimeError.new("#{r}: slot '#{spec.name}' is unbound") }
        end
        if w = spec.writer
          @global.define_fn(w, 2, 2) { |args| clos_instance_arg(args[0], w).slots[spec.name] = args[1] }
        end
        if a = spec.accessor
          @global.define_fn(a, 1, 1) { |args| clos_instance_arg(args[0], a).slots[spec.name]? || raise LispRuntimeError.new("#{a}: slot '#{spec.name}' is unbound") }
          setter = "set-#{a}!"
          @global.define_fn(setter, 2, 2) { |args| clos_instance_arg(args[0], setter).slots[spec.name] = args[1] }
        end
      end
    end

    # (defgeneric name (params...))
    private def eval_defgeneric(expr : Cons, env : Env) : LispValue
      require_clos_enabled("defgeneric")
      parts = LISP.list_to_a(expr.cdr)
      raise LispRuntimeError.new("defgeneric: expects a generic function name") if parts.empty?
      name_sym = parts[0]
      raise LispRuntimeError.new("defgeneric: generic function name must be a symbol") unless name_sym.is_a?(LispSym)
      existing = env.get?(name_sym.name)
      if existing
        raise LispRuntimeError.new("defgeneric: '#{name_sym.name}' is already bound to a non-generic-function value") unless existing.is_a?(GenericFunction)
      else
        env.define(name_sym.name, GenericFunction.new(name_sym.name))
      end
      name_sym
    end

    # (defmethod name ((self ClassName) other-arg...) body...)
    private def eval_defmethod(expr : Cons, env : Env) : LispValue
      require_clos_enabled("defmethod")
      rest = expr.cdr
      raise LispRuntimeError.new("defmethod: malformed") unless rest.is_a?(Cons)
      name_sym = rest.car
      raise LispRuntimeError.new("defmethod: method name must be a symbol") unless name_sym.is_a?(LispSym)
      formals_rest = rest.cdr
      raise LispRuntimeError.new("defmethod: malformed") unless formals_rest.is_a?(Cons)
      formal_items = LISP.list_to_a(formals_rest.car)
      body = LISP.list_to_a(formals_rest.cdr)
      raise LispRuntimeError.new("defmethod: method body is empty") if body.empty?
      raise LispRuntimeError.new("defmethod: parameter list must specialize the first parameter, e.g. ((self ClassName))") if formal_items.empty?

      first = formal_items[0]
      raise LispRuntimeError.new("defmethod: first parameter must be specialized, e.g. (self ClassName)") unless first.is_a?(Cons)
      first_parts = LISP.list_to_a(first)
      raise LispRuntimeError.new("defmethod: malformed specialized parameter #{first.write_string}") unless first_parts.size == 2
      pname = defclass_sym_name(first_parts[0])
      specializer_name = defclass_sym_name(first_parts[1])
      raise LispRuntimeError.new("defmethod: unknown class '#{specializer_name}'") unless @classes.has_key?(specializer_name)

      rest_params = formal_items[1..].map do |param|
        raise LispRuntimeError.new("defmethod: only the first parameter may be specialized (single dispatch)") if param.is_a?(Cons)
        defclass_sym_name(param)
      end

      lam = Lambda.new([pname] + rest_params, nil, body, env, "#{name_sym.name}[#{specializer_name}]")

      existing = env.get?(name_sym.name)
      gf = if existing
             raise LispRuntimeError.new("defmethod: '#{name_sym.name}' is already bound to a non-generic-function value") unless existing.is_a?(GenericFunction)
             existing
           else
             GenericFunction.new(name_sym.name)
           end
      gf.methods[specializer_name] = lam
      env.define(name_sym.name, gf)
      name_sym
    end
  end
end
