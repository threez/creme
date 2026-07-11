# ===========================================================================
# Runner: run_source, run_file
# ===========================================================================
#
# Pure library entry points — no STDOUT/STDERR/exit here. Callers (e.g.
# src/main.cr) own presentation and process lifecycle.

module LISP
  def self.run_source(interp : Interpreter, src : String) : LispValue
    result : LispValue = NIL
    Reader.read_all(src).each do |form|
      result = interp.eval(form, interp.global)
    end
    result
  end

  def self.run_file(interp : Interpreter, path : String) : LispValue
    raise LispRuntimeError.new("file not found: #{path}") unless File.exists?(path)
    run_source(interp, File.read(path))
  end
end
