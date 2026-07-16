# ===========================================================================
# digest module: hashing and base64 encoding
# ===========================================================================

require "digest/md5"
require "digest/sha1"
require "digest/sha256"
require "base64"

module Scheme::Builtins::Digest
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("digest-md5", min: 1, max: 1)]
  def digest_md5(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(::Digest::MD5.hexdigest(digest_str_arg(args[0], "digest-md5")))
  end

  @[Scheme::SchemeFn("digest-sha1", min: 1, max: 1)]
  def digest_sha1(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(::Digest::SHA1.hexdigest(digest_str_arg(args[0], "digest-sha1")))
  end

  @[Scheme::SchemeFn("digest-sha256", min: 1, max: 1)]
  def digest_sha256(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(::Digest::SHA256.hexdigest(digest_str_arg(args[0], "digest-sha256")))
  end

  @[Scheme::SchemeFn("base64-encode", min: 1, max: 1)]
  def base64_encode(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(Base64.strict_encode(digest_str_arg(args[0], "base64-encode")))
  end

  @[Scheme::SchemeFn("base64-decode", min: 1, max: 1)]
  def base64_decode(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = digest_str_arg(args[0], "base64-decode")
    SchemeStr.new(Base64.decode_string(s))
  rescue ex : Base64::Error
    raise SchemeRuntimeError.new("base64-decode: invalid base64: #{ex.message}")
  end

  private def digest_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "digest"], Scheme::Builtins::Digest
  end
end
