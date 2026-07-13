# ===========================================================================
# rfc8439 module: ChaCha20, Poly1305, and the ChaCha20-Poly1305 AEAD
# construction from RFC 8439
# ===========================================================================

require "rfc8439"

module Scheme
  class Interpreter
    private def install_rfc8439(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(SchemeValue) -> SchemeValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      reg.call("rfc8439-random-key", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue do
        SchemeBlob.new(Random::Secure.random_bytes(32))
      end)

      reg.call("rfc8439-random-nonce", 0, 0, ->(_args : Array(SchemeValue)) : SchemeValue do
        SchemeBlob.new(Random::Secure.random_bytes(12))
      end)

      reg.call("hex->bytevector", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        s = rfc8439_str_arg(args[0], "hex->bytevector")
        stripped = s.gsub(/[:\s]/, "")
        unless stripped =~ /\A[0-9a-fA-F]*\z/ && stripped.size.even?
          raise SchemeRuntimeError.new("hex->bytevector: invalid hex string '#{s}'")
        end
        SchemeBlob.new(stripped.hexbytes)
      end)

      reg.call("bytevector->hex", 1, 1, ->(args : Array(SchemeValue)) : SchemeValue do
        SchemeStr.new(rfc8439_bytes_arg(args[0], "bytevector->hex").hexstring)
      end)

      # The underlying AEAD writes a self-describing sealed blob to its IO --
      # padded aad, then padded ciphertext, then a 16-byte size footer -- and
      # #decrypt reads that same blob back (plus the tag) to recover both the
      # aad and the plaintext, so encrypt/decrypt exchange this single blob
      # rather than a bare ciphertext.
      reg.call("rfc8439-encrypt", 3, 4, ->(args : Array(SchemeValue)) : SchemeValue do
        key = rfc8439_bytes_arg(args[0], "rfc8439-encrypt")
        nonce = rfc8439_bytes_arg(args[1], "rfc8439-encrypt")
        plaintext = rfc8439_bytes_arg(args[2], "rfc8439-encrypt")
        aad = args.size > 3 ? rfc8439_bytes_arg(args[3], "rfc8439-encrypt") : Bytes.empty
        begin
          io = IO::Memory.new
          aead = Crypto::AeadChacha20Poly1305.new(key, nonce, io)
          aead.aad(aad) unless aad.empty?
          aead.update(plaintext)
          tag = aead.final
          Scheme.a_to_list([
            Cons.new(SchemeStr.new("ciphertext"), SchemeBlob.new(io.to_slice.dup)).as(SchemeValue),
            Cons.new(SchemeStr.new("tag"), SchemeBlob.new(tag)).as(SchemeValue),
          ])
        rescue ex : Exception
          raise SchemeRuntimeError.new("rfc8439-encrypt: #{ex.message}")
        end
      end)

      reg.call("rfc8439-decrypt", 4, 4, ->(args : Array(SchemeValue)) : SchemeValue do
        key = rfc8439_bytes_arg(args[0], "rfc8439-decrypt")
        nonce = rfc8439_bytes_arg(args[1], "rfc8439-decrypt")
        ciphertext = rfc8439_bytes_arg(args[2], "rfc8439-decrypt")
        tag = rfc8439_bytes_arg(args[3], "rfc8439-decrypt")
        begin
          io = IO::Memory.new
          aead = Crypto::AeadChacha20Poly1305.new(key, nonce, io)
          aad = begin
            aead.decrypt(ciphertext, tag)
          rescue OverflowError
            # rfc8439.cr's #decrypt computes `data[0..(aad_size &- 1)]` for the
            # returned aad, which underflows (wrapping subtraction on an
            # unsigned size) and raises OverflowError when there was no aad --
            # but by this point the plaintext has already been written to
            # `io`, so the only thing lost is the (empty) aad value itself.
            Bytes.empty
          end
          Scheme.a_to_list([
            Cons.new(SchemeStr.new("aad"), SchemeBlob.new(aad)).as(SchemeValue),
            Cons.new(SchemeStr.new("plaintext"), SchemeBlob.new(io.to_slice.dup)).as(SchemeValue),
          ])
        rescue ex : Crypto::TagException
          raise SchemeRuntimeError.new("rfc8439-decrypt: authentication failed (tag mismatch)")
        rescue ex : Exception
          raise SchemeRuntimeError.new("rfc8439-decrypt: #{ex.message}")
        end
      end)

      reg.call("chacha20-encrypt", 3, 3, ->(args : Array(SchemeValue)) : SchemeValue do
        key = rfc8439_bytes_arg(args[0], "chacha20-encrypt")
        nonce = rfc8439_bytes_arg(args[1], "chacha20-encrypt")
        data = rfc8439_bytes_arg(args[2], "chacha20-encrypt")
        begin
          SchemeBlob.new(Crypto::ChaCha20.new(key, nonce).encrypt(data))
        rescue ex : Exception
          raise SchemeRuntimeError.new("chacha20-encrypt: #{ex.message}")
        end
      end)

      reg.call("poly1305-auth", 2, 2, ->(args : Array(SchemeValue)) : SchemeValue do
        key = rfc8439_bytes_arg(args[0], "poly1305-auth")
        message = rfc8439_bytes_arg(args[1], "poly1305-auth")
        begin
          SchemeBlob.new(Crypto::Poly1305.auth(key, message))
        rescue ex : Exception
          raise SchemeRuntimeError.new("poly1305-auth: #{ex.message}")
        end
      end)
    end

    private def rfc8439_bytes_arg(v : SchemeValue, who : String) : Bytes
      case v
      when SchemeBlob then v.value
      when SchemeStr  then v.value.to_slice
      else
        raise SchemeRuntimeError.new("#{who}: expected blob or string, got #{v.write_string}")
      end
    end

    private def rfc8439_str_arg(v : SchemeValue, who : String) : String
      raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
      v.value
    end
  end
end
