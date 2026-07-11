# ===========================================================================
# Runner: run_source, run_file
# ===========================================================================
#
# Pure library entry points — no STDOUT/STDERR/exit here. Callers (e.g.
# src/main.cr) own presentation and process lifecycle.

module LISP
  # bindings/parent let a host inject data and isolate one call from the
  # next while reusing a single warm Interpreter:
  #   - neither given: evals against interp.global, unchanged from before.
  #   - bindings given: evals against a fresh child of (parent || interp.global),
  #     seeded with bindings and discarded after the call — nothing leaks
  #     into interp.global or a later call.
  #   - parent given alone: evals directly against it (host controls isolation).
  #   - both given: fresh child of parent, seeded with bindings — lets a host
  #     register expensive callbacks once on a reusable parent env, then
  #     reuse it as the chain root for many cheap, isolated calls.
  def self.run_source(interp : Interpreter, src : String, bindings : Hash(String, LispValue)? = nil, parent : Env? = nil) : LispValue
    root = parent || interp.global
    env : Env = root
    if bindings
      env = Env.new(root)
      bindings.each { |k, v| env.define(k, v) }
    end
    result : LispValue = NIL
    Reader.read_all(src).each do |form|
      result = interp.eval(form, env)
    end
    result
  end

  def self.run_file(interp : Interpreter, path : String, bindings : Hash(String, LispValue)? = nil, parent : Env? = nil) : LispValue
    raise LispRuntimeError.new("file not found: #{path}") unless File.exists?(path)
    run_source(interp, File.read(path), bindings, parent)
  end
end
