# ===========================================================================
# (scheme write): display / write / write-simple / write-shared
# ===========================================================================
#
# These are (builtin write)'s procedures (re-exported by (scheme write)),
# not (builtin base)'s/(scheme base)'s. They're installed into @base_env
# (which both (builtin base) and (builtin write) share as their Env) by
# install_write, whose register_module return value becomes (builtin
# write)'s derived export list — see install_builtin_libraries in base.cr.

module Scheme::Builtins::WriteLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("display", min: 1, max: 2)]
  def display(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.emit(args[0].display_string, args[1]?, "display")
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("write", min: 1, max: 2)]
  def write(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.emit(args[0].write_string, args[1]?, "write")
    NIL.as(SchemeValue)
  end

  # write-simple never emits datum labels for shared/circular structure —
  # since plain write here doesn't emit them either, this is currently a
  # faithful alias.
  @[Scheme::SchemeFn("write-simple", min: 1, max: 2)]
  def write_simple(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.emit(args[0].write_string, args[1]?, "write-simple")
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("write-shared", min: 1, max: 2)]
  def write_shared(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    interp.emit(write_shared_string(args[0]), args[1]?, "write-shared")
    NIL.as(SchemeValue)
  end
end

module Scheme
  class Interpreter
    private def install_write(env : Env) : Array(String)
      register_module(Scheme::Builtins::WriteLibrary, env)
    end
  end
end
