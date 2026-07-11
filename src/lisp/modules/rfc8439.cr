# ===========================================================================
# rfc8439 module: ChaCha20, Poly1305, and the ChaCha20-Poly1305 AEAD
# construction from RFC 8439
# ===========================================================================

require "rfc8439"

module LISP
  class Interpreter
    private def install_rfc8439(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("random-key", 0, 0, ->(_args : Array(LispValue)) : LispValue do
        LispBlob.new(Random::Secure.random_bytes(32))
      end)

      reg.call("random-nonce", 0, 0, ->(_args : Array(LispValue)) : LispValue do
        LispBlob.new(Random::Secure.random_bytes(12))
      end)

      reg.call("hex->blob", 1, 1, ->(args : Array(LispValue)) : LispValue do
        s = rfc8439_str_arg(args[0], "rfc8439:hex->blob")
        stripped = s.gsub(/[:\s]/, "")
        unless stripped =~ /\A[0-9a-fA-F]*\z/ && stripped.size.even?
          raise LispRuntimeError.new("rfc8439:hex->blob: invalid hex string '#{s}'")
        end
        LispBlob.new(stripped.hexbytes)
      end)

      reg.call("blob->hex", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispStr.new(rfc8439_bytes_arg(args[0], "rfc8439:blob->hex").hexstring)
      end)

      # The underlying AEAD writes a self-describing sealed blob to its IO --
      # padded aad, then padded ciphertext, then a 16-byte size footer -- and
      # #decrypt reads that same blob back (plus the tag) to recover both the
      # aad and the plaintext, so encrypt/decrypt exchange this single blob
      # rather than a bare ciphertext.
      reg.call("encrypt", 3, 4, ->(args : Array(LispValue)) : LispValue do
        key = rfc8439_bytes_arg(args[0], "rfc8439:encrypt")
        nonce = rfc8439_bytes_arg(args[1], "rfc8439:encrypt")
        plaintext = rfc8439_bytes_arg(args[2], "rfc8439:encrypt")
        aad = args.size > 3 ? rfc8439_bytes_arg(args[3], "rfc8439:encrypt") : Bytes.empty
        begin
          io = IO::Memory.new
          aead = Crypto::AeadChacha20Poly1305.new(key, nonce, io)
          aead.aad(aad) unless aad.empty?
          aead.update(plaintext)
          tag = aead.final
          LISP.a_to_list([
            Cons.new(LispStr.new("ciphertext"), LispBlob.new(io.to_slice.dup)).as(LispValue),
            Cons.new(LispStr.new("tag"), LispBlob.new(tag)).as(LispValue),
          ])
        rescue ex : Exception
          raise LispRuntimeError.new("rfc8439:encrypt: #{ex.message}")
        end
      end)

      reg.call("decrypt", 4, 4, ->(args : Array(LispValue)) : LispValue do
        key = rfc8439_bytes_arg(args[0], "rfc8439:decrypt")
        nonce = rfc8439_bytes_arg(args[1], "rfc8439:decrypt")
        ciphertext = rfc8439_bytes_arg(args[2], "rfc8439:decrypt")
        tag = rfc8439_bytes_arg(args[3], "rfc8439:decrypt")
        begin
          io = IO::Memory.new
          aead = Crypto::AeadChacha20Poly1305.new(key, nonce, io)
          aad = begin
            aead.decrypt(ciphertext, tag)
          rescue IndexError
            # rfc8439.cr's #decrypt computes `data[0..(aad_size &- 1)]` for the
            # returned aad, which underflows (wrapping subtraction on an
            # unsigned size) and raises when there was no aad -- but by this
            # point the plaintext has already been written to `io`, so the
            # only thing lost is the (empty) aad value itself.
            Bytes.empty
          end
          LISP.a_to_list([
            Cons.new(LispStr.new("aad"), LispBlob.new(aad)).as(LispValue),
            Cons.new(LispStr.new("plaintext"), LispBlob.new(io.to_slice.dup)).as(LispValue),
          ])
        rescue ex : Crypto::TagException
          raise LispRuntimeError.new("rfc8439:decrypt: authentication failed (tag mismatch)")
        rescue ex : Exception
          raise LispRuntimeError.new("rfc8439:decrypt: #{ex.message}")
        end
      end)

      reg.call("chacha20-encrypt", 3, 3, ->(args : Array(LispValue)) : LispValue do
        key = rfc8439_bytes_arg(args[0], "rfc8439:chacha20-encrypt")
        nonce = rfc8439_bytes_arg(args[1], "rfc8439:chacha20-encrypt")
        data = rfc8439_bytes_arg(args[2], "rfc8439:chacha20-encrypt")
        begin
          LispBlob.new(Crypto::ChaCha20.new(key, nonce).encrypt(data))
        rescue ex : Exception
          raise LispRuntimeError.new("rfc8439:chacha20-encrypt: #{ex.message}")
        end
      end)

      reg.call("poly1305-auth", 2, 2, ->(args : Array(LispValue)) : LispValue do
        key = rfc8439_bytes_arg(args[0], "rfc8439:poly1305-auth")
        message = rfc8439_bytes_arg(args[1], "rfc8439:poly1305-auth")
        begin
          LispBlob.new(Crypto::Poly1305.auth(key, message))
        rescue ex : Exception
          raise LispRuntimeError.new("rfc8439:poly1305-auth: #{ex.message}")
        end
      end)
    end

    private def rfc8439_bytes_arg(v : LispValue, who : String) : Bytes
      case v
      when LispBlob then v.value
      when LispStr  then v.value.to_slice
      else
        raise LispRuntimeError.new("#{who}: expected blob or string, got #{v.write_string}")
      end
    end

    private def rfc8439_str_arg(v : LispValue, who : String) : String
      raise LispRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(LispStr)
      v.value
    end
  end
end
