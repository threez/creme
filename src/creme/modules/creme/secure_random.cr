# ===========================================================================
# secure-random module: cryptographically-secure random bytes/hex/base64
# (Ruby's SecureRandom) -- deliberately its own module, distinct from
# (creme random)'s plain, non-cryptographic PRNG (backed by Crystal's
# ordinary `Random`, seedable/reproducible), the same way Ruby keeps
# `SecureRandom` and `Random` as two separate stdlib modules. Backed by
# Random::Secure, a thin wrapper over the OS's own CSPRNG (getrandom(2)/
# /dev/urandom on Linux, arc4random_buf on BSD/macOS) -- the exact same
# primitive (creme actor)'s TCP/Unix handshake nonces and (creme
# rfc8439)'s rfc8439-random-key/-nonce already use, just newly exposed
# here as general-purpose builtins.
# ===========================================================================

module Creme::Builtins::SecureRandomLibrary
  extend self
  include Creme::BuiltinHelpers

  @[Creme::SchemeFn("secure-random-bytes", min: 1, max: 1)]
  def secure_random_bytes(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = secure_random_count_arg(args[0], "secure-random-bytes")
    SchemeBlob.new(Random::Secure.random_bytes(n))
  end

  @[Creme::SchemeFn("secure-random-hex", min: 1, max: 1)]
  def secure_random_hex(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = secure_random_count_arg(args[0], "secure-random-hex")
    SchemeStr.new(Random::Secure.hex(n))
  end

  @[Creme::SchemeFn("secure-random-base64", min: 1, max: 1)]
  def secure_random_base64(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = secure_random_count_arg(args[0], "secure-random-base64")
    SchemeStr.new(Random::Secure.base64(n))
  end

  private def secure_random_count_arg(v : SchemeValue, who : String) : Int32
    raise SchemeRuntimeError.new("#{who}: expected a non-negative integer, got #{v.write_string}") unless v.is_a?(SchemeInt)
    raise SchemeRuntimeError.new("#{who}: expected a non-negative integer, got #{v.write_string}") if v.value < 0
    v.value.to_i32
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "secure-random"], Creme::Builtins::SecureRandomLibrary
  end
end
