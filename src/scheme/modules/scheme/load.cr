# ===========================================================================
# (scheme load)
# ===========================================================================

module Scheme::Builtins::Load
  extend self
  include Scheme::BuiltinHelpers

  # `interp` is stale for an actor Fiber (captured at registration time,
  # always the root Interpreter — see builtin_registration.cr); resolve the
  # Interpreter actually running THIS fiber instead, so a default-target
  # `load` lands in that actor's own @global/load_dirs, not the root's.
  @[Scheme::SchemeFn("load", min: 1, max: 2)]
  def load(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    active = Interpreter.current || interp
    path_arg = args[0]
    raise SchemeRuntimeError.new("load: expected string, got #{path_arg.write_string}") unless path_arg.is_a?(SchemeStr)
    target_env = args.size == 2 ? environment_specifier_arg(args[1], "load") : active.global

    dir = active.load_dirs.last?
    path = dir ? File.join(dir, path_arg.value) : path_arg.value
    raise SchemeRuntimeError.new("load: #{path_arg.value}: file not found") unless File.exists?(path)
    resolved = File.realpath(path)
    forms = Reader.read_all(File.read(resolved), resolved)
    active.load_dirs << File.dirname(resolved)
    begin
      BytecodeCompiler.run_program(active, forms, target_env)
    ensure
      active.load_dirs.pop
    end
  end
end

module Scheme
  class Interpreter
    register_library ["scheme", "load"], Scheme::Builtins::Load
  end
end
