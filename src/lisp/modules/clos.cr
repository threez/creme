# ===========================================================================
# clos module: CLOS-lite object system (defclass/make-instance/defgeneric/
# defmethod). Single inheritance, single dispatch on the first argument.
# ===========================================================================

module LISP
  # A class metaobject. `defclass` registers one of these both in the
  # interpreter's @classes registry (keyed by name, for quoted-symbol lookup
  # from make-instance) and as an ordinary global binding (so the bare class
  # name also evaluates to the class object, like CL's `find-class`).
  class LispClass < LispValue
    getter name : String
    getter superclass : LispClass?
    getter own_slots : Array(SlotSpec)

    def initialize(@name : String, @superclass : LispClass?, @own_slots : Array(SlotSpec))
    end

    # Slots inherited from the superclass chain, with a same-named slot on
    # this class overriding the inherited one, followed by this class's own
    # slots not already accounted for.
    def all_slots : Array(SlotSpec)
      inherited = (base = superclass) ? base.all_slots : [] of SlotSpec
      inherited.reject { |slot| own_slots.any? { |own| own.name == slot.name } } + own_slots
    end

    def to_display(io : IO) : Nil
      io << "#<class:" << @name << '>'
    end
  end

  # Not a LispValue — pure Crystal metadata describing one defclass slot spec.
  class SlotSpec
    getter name : String
    getter initarg : String?
    getter initform : LispValue?
    getter reader : String?
    getter writer : String?
    getter accessor : String?

    def initialize(@name : String, @initarg : String? = nil, @initform : LispValue? = nil,
                   @reader : String? = nil, @writer : String? = nil, @accessor : String? = nil)
    end
  end

  class LispInstance < LispValue
    getter lisp_class : LispClass
    getter slots : Hash(String, LispValue)

    def initialize(@lisp_class : LispClass, @slots : Hash(String, LispValue) = {} of String => LispValue)
    end

    def to_display(io : IO) : Nil
      io << "#<" << @lisp_class.name << '>'
    end
  end

  # A generic function's method table, keyed by the class name of its single
  # specialized (first) parameter. `name` is mutable so defgeneric/defmethod
  # can be told apart from a plain "already bound to something else" error.
  class GenericFunction < LispValue
    property name : String
    getter methods : Hash(String, Lambda)

    def initialize(@name : String)
      @methods = {} of String => Lambda
    end

    def to_display(io : IO) : Nil
      io << "#<generic-function:" << @name << '>'
    end
  end

  class Interpreter
    # ---- dispatch helpers, shared by eval_core's tail-call branch and apply ----

    # Most-specific-first chain: [class, superclass, ..., root].
    private def class_chain(c : LispClass) : Array(LispClass)
      chain = [] of LispClass
      cur : LispClass? = c
      while cur
        chain << cur
        cur = cur.superclass
      end
      chain
    end

    private def clos_dispatch_class(gf : GenericFunction, args : Array(LispValue)) : LispClass
      first = args.first?
      unless first.is_a?(LispInstance)
        raise LispRuntimeError.new("#{gf.name}: no applicable method: first argument is not an instance (#{first.try(&.write_string) || "no arguments"})")
      end
      first.lisp_class
    end

    private def find_method_index(gf : GenericFunction, chain : Array(LispClass), start_idx : Int32) : Int32?
      (start_idx...chain.size).find { |i| gf.methods.has_key?(chain[i].name) }
    end

    # Invokes the method at chain[idx] (assumed applicable), wiring up a
    # call-next-method builtin that resumes the search from idx + 1. Used for
    # apply()-style (non-tail) invocation and recursively by call-next-method
    # itself, so chains of arbitrary depth resolve correctly.
    private def apply_method_chain(gf : GenericFunction, chain : Array(LispClass), idx : Int32, args : Array(LispValue)) : LispValue
      lam = gf.methods[chain[idx].name]
      call_env = Env.new(lam.env)
      bind_params(lam, args, call_env)
      define_call_next_method(call_env, gf, chain, idx, args)
      result : LispValue = NIL
      lam.body.each { |form| result = eval(form, call_env) }
      result
    end

    private def define_call_next_method(call_env : Env, gf : GenericFunction, chain : Array(LispClass), idx : Int32, args : Array(LispValue)) : Nil
      call_env.define_fn("call-next-method", 0, -1) do |cn_args|
        next_idx = find_method_index(gf, chain, idx + 1)
        raise LispRuntimeError.new("call-next-method: no next method") unless next_idx
        apply_method_chain(gf, chain, next_idx, cn_args.empty? ? args : cn_args)
      end
    end

    private def clos_resolve_class(v : LispValue, who : String) : LispClass
      case v
      when LispClass
        v
      when LispSym
        @classes[v.name]? || raise LispRuntimeError.new("#{who}: unknown class '#{v.name}'")
      else
        raise LispRuntimeError.new("#{who}: expected a class or class name symbol, got #{v.write_string}")
      end
    end

    private def clos_instance_arg(v : LispValue, who : String) : LispInstance
      raise LispRuntimeError.new("#{who}: expected an instance, got #{v.write_string}") unless v.is_a?(LispInstance)
      v
    end

    private def clos_slot_name_arg(v : LispValue, who : String) : String
      raise LispRuntimeError.new("#{who}: expected a slot-name symbol, got #{v.write_string}") unless v.is_a?(LispSym)
      v.name
    end

    # ---- module install ---------------------------------------------------

    # Deliberately defines everything into @global instead of the isolated
    # `env` package env every other module receives: CLOS accessor/generic
    # functions and make-instance/slot-value are meant to read as unprefixed
    # global names (matching Common Lisp), not `clos:make-instance`. `env` is
    # still accepted (and left otherwise unused) to fit the standard
    # `install_<name>(Env)` module-installer signature.
    private def install_clos(env : Env) : Nil
      @clos_enabled = true
      g = @global
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        g.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("make-instance", 1, -1, ->(args : Array(LispValue)) : LispValue do
        klass = clos_resolve_class(args[0], "make-instance")
        kwargs = args[1..]
        raise LispRuntimeError.new("make-instance: keyword arguments must come in pairs") unless kwargs.size.even?
        provided = {} of String => LispValue
        i = 0
        while i < kwargs.size
          key = kwargs[i]
          unless key.is_a?(LispSym) && key.name.starts_with?(':')
            raise LispRuntimeError.new("make-instance: expected a keyword argument, got #{key.write_string}")
          end
          provided[key.name] = kwargs[i + 1]
          i += 2
        end
        slots = {} of String => LispValue
        klass.all_slots.each do |spec|
          if (ia = spec.initarg) && (val = provided.delete(ia))
            slots[spec.name] = val
          elsif iform = spec.initform
            slots[spec.name] = eval(iform, @global)
          end
        end
        unless provided.empty?
          raise LispRuntimeError.new("make-instance: unknown initarg(s) for class '#{klass.name}': #{provided.keys.join(", ")}")
        end
        LispInstance.new(klass, slots)
      end)

      reg.call("slot-value", 2, 2, ->(args : Array(LispValue)) : LispValue do
        inst = clos_instance_arg(args[0], "slot-value")
        slot_name = clos_slot_name_arg(args[1], "slot-value")
        inst.slots[slot_name]? || raise LispRuntimeError.new("slot-value: slot '#{slot_name}' is unbound")
      end)

      reg.call("set-slot-value!", 3, 3, ->(args : Array(LispValue)) : LispValue do
        inst = clos_instance_arg(args[0], "set-slot-value!")
        slot_name = clos_slot_name_arg(args[1], "set-slot-value!")
        inst.slots[slot_name] = args[2]
        args[2]
      end)

      reg.call("class-of", 1, 1, ->(args : Array(LispValue)) : LispValue do
        clos_instance_arg(args[0], "class-of").lisp_class
      end)

      reg.call("class-name", 1, 1, ->(args : Array(LispValue)) : LispValue do
        klass = args[0]
        raise LispRuntimeError.new("class-name: expected a class, got #{klass.write_string}") unless klass.is_a?(LispClass)
        LispSym.of(klass.name)
      end)

      reg.call("instance-of?", 2, 2, ->(args : Array(LispValue)) : LispValue do
        inst = clos_instance_arg(args[0], "instance-of?")
        klass = clos_resolve_class(args[1], "instance-of?")
        LispBool.of(class_chain(inst.lisp_class).includes?(klass))
      end)
    end
  end
end
