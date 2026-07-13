# ===========================================================================
# Runner: run_source, run_file
# ===========================================================================
#
# Pure library entry points — no STDOUT/STDERR/exit here. Callers (e.g.
# src/main.cr) own presentation and process lifecycle.

module Scheme
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
  def self.run_source(interp : Interpreter, src : String, bindings : Hash(String, SchemeValue)? = nil, parent : Env? = nil, source_name : String = "<repl>") : SchemeValue
    root = parent || interp.global
    env : Env = root
    if bindings
      env = Env.new(root)
      bindings.each { |k, v| env.define(k, v) }
    end
    result : SchemeValue = NIL
    Reader.read_all(src, source_name).each do |form|
      result = interp.eval(form, env)
    end
    result
  end

  def self.run_file(interp : Interpreter, path : String, bindings : Hash(String, SchemeValue)? = nil, parent : Env? = nil) : SchemeValue
    raise SchemeRuntimeError.new("file not found: #{path}") unless File.exists?(path)
    # Push the script's own directory so a relative (require "...") inside it
    # resolves against where the script lives, not the process's CWD.
    interp.push_load_dir(File.dirname(File.expand_path(path)))
    begin
      run_source(interp, File.read(path), bindings, parent, source_name: path)
    ensure
      interp.pop_load_dir
    end
  end
end
