# ===========================================================================
# digest module: hashing and base64 encoding
# ===========================================================================

require "digest/md5"
require "digest/sha1"
require "digest/sha256"
require "base64"

module Scheme
  class Interpreter
    private def install_digest(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("digest-md5", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeStr.new(Digest::MD5.hexdigest(digest_str_arg(args[0], "digest-md5")))
      end)

      reg.call("digest-sha1", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeStr.new(Digest::SHA1.hexdigest(digest_str_arg(args[0], "digest-sha1")))
      end)

      reg.call("digest-sha256", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeStr.new(Digest::SHA256.hexdigest(digest_str_arg(args[0], "digest-sha256")))
      end)

      reg.call("base64-encode", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeStr.new(Base64.strict_encode(digest_str_arg(args[0], "base64-encode")))
      end)

      reg.call("base64-decode", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        s = digest_str_arg(args[0], "base64-decode")
        begin
          SchemeStr.new(Base64.decode_string(s))
        rescue ex : Base64::Error
          raise SchemeRuntimeError.new("base64-decode: invalid base64: #{ex.message}")
        end
      end)
    end

    private def digest_str_arg(v : SchemeValue, who : String) : String
      raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
      v.value
    end
  end
end
