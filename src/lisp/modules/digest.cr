# ===========================================================================
# digest module: hashing and base64 encoding
# ===========================================================================

require "digest/md5"
require "digest/sha1"
require "digest/sha256"
require "base64"

module LISP
  class Interpreter
    private def install_digest(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("md5", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispStr.new(Digest::MD5.hexdigest(digest_str_arg(args[0], "digest:md5")))
      end)

      reg.call("sha1", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispStr.new(Digest::SHA1.hexdigest(digest_str_arg(args[0], "digest:sha1")))
      end)

      reg.call("sha256", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispStr.new(Digest::SHA256.hexdigest(digest_str_arg(args[0], "digest:sha256")))
      end)

      reg.call("base64-encode", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispStr.new(Base64.strict_encode(digest_str_arg(args[0], "digest:base64-encode")))
      end)

      reg.call("base64-decode", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = digest_str_arg(args[0], "digest:base64-decode")
        begin
          LispStr.new(Base64.decode_string(s))
        rescue ex : Base64::Error
          raise LispRuntimeError.new("digest:base64-decode: invalid base64: #{ex.message}")
        end
      end)
    end

    private def digest_str_arg(v : LispValue, who : String) : String
      raise LispRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(LispStr)
      v.value
    end
  end
end
