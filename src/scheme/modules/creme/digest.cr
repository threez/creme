# ===========================================================================
# digest module: hashing and base64 encoding
# ===========================================================================

require "digest/md5"
require "digest/sha1"
require "digest/sha256"
require "digest/sha512"
require "openssl/digest"
require "openssl/hmac"
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

  # No dedicated Digest::SHA384 class ships in Crystal stdlib (unlike
  # MD5/SHA1/SHA256/SHA512, each their own class with a one-shot
  # .hexdigest(String) classmethod) -- OpenSSL::Digest is the generic
  # streaming API every named Digest::* class is itself built on.
  @[Scheme::SchemeFn("digest-sha384", min: 1, max: 1)]
  def digest_sha384(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(OpenSSL::Digest.new("SHA384").update(digest_bytes_arg(args[0], "digest-sha384")).final.hexstring)
  end

  @[Scheme::SchemeFn("digest-sha512", min: 1, max: 1)]
  def digest_sha512(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(::Digest::SHA512.hexdigest(digest_bytes_arg(args[0], "digest-sha512")))
  end

  @[Scheme::SchemeFn("hmac-sha256", min: 2, max: 2)]
  def hmac_sha256(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = digest_bytes_arg(args[0], "hmac-sha256")
    data = digest_bytes_arg(args[1], "hmac-sha256")
    SchemeStr.new(OpenSSL::HMAC.hexdigest(:sha256, key, data))
  end

  @[Scheme::SchemeFn("hmac-sha384", min: 2, max: 2)]
  def hmac_sha384(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = digest_bytes_arg(args[0], "hmac-sha384")
    data = digest_bytes_arg(args[1], "hmac-sha384")
    SchemeStr.new(OpenSSL::HMAC.hexdigest(:sha384, key, data))
  end

  @[Scheme::SchemeFn("hmac-sha512", min: 2, max: 2)]
  def hmac_sha512(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = digest_bytes_arg(args[0], "hmac-sha512")
    data = digest_bytes_arg(args[1], "hmac-sha512")
    SchemeStr.new(OpenSSL::HMAC.hexdigest(:sha512, key, data))
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

  # Wider than digest_str_arg (string-only, the original three digest-*
  # procedures' contract, left untouched) -- a key is often raw binary
  # (e.g. straight from (creme secure-random)), so every NEW procedure
  # added here accepts either a bytevector or a string, matching
  # rfc8439.cr's own rfc8439_bytes_arg.
  private def digest_bytes_arg(v : SchemeValue, who : String) : Bytes
    case v
    when SchemeBlob then v.value
    when SchemeStr  then v.value.to_slice
    else
      raise SchemeRuntimeError.new("#{who}: expected blob or string, got #{v.write_string}")
    end
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "digest"], Scheme::Builtins::Digest
  end
end
