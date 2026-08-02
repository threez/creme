# ===========================================================================
# (scheme read)
# ===========================================================================

module Creme::R7RS::ReadLibrary
  extend self
  include Creme::BuiltinHelpers

  # Reads and parses exactly one datum from a port, advancing the
  # port's position past it — subsequent `read` calls on the same port
  # continue from where this one left off. Ports don't natively support
  # incremental (partial) Scheme-level reading, so this buffers the
  # port's remaining unread bytes, tokenizes/parses just the first
  # form, then rewrites the port's backing IO::Memory to contain only
  # what's left over after that form — a full re-tokenize per call, but
  # correct and simple, and read is not a hot-path procedure.
  @[Creme::SchemeFn("read", min: 0, max: 1)]
  def read(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    p = interp.input_port_arg(args[0]?, "read")
    read_one_form(p)
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "read"], Creme::R7RS::ReadLibrary
  end
end
