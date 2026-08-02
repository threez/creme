# ===========================================================================
# cipher module: AES-256-GCM authenticated encryption (Ruby's
# OpenSSL::Cipher) -- deliberately scoped to ONE algorithm/mode (AEAD,
# the modern default) rather than Ruby's much broader cipher-name-string
# surface; no raw CBC/ECB is offered here at all, the same AEAD-first cut
# (creme rfc8439) already made for ChaCha20-Poly1305.
#
# Crystal's own stdlib OpenSSL::Cipher (openssl/cipher.cr) has NO GCM/AEAD
# support in this Crystal version -- no way to feed it AAD or get/set an
# authentication tag (EVP_CIPHER_CTX_ctrl is never bound in
# OpenSSL::LibCrypto at all). This drives the raw EVP API directly
# instead, reopening LibCrypto (already @[Link]ed by "openssl/lib_crypto",
# require "openssl/hmac" elsewhere in this project) to add the one
# missing binding, EVP_CIPHER_CTX_ctrl -- everything else needed
# (ctx new/free, cipherinit_ex, cipherupdate, cipherfinal_ex,
# get_cipherbyname) is already bound there.
# ===========================================================================

require "openssl/lib_crypto"

lib LibCrypto
  fun evp_cipher_ctx_ctrl = EVP_CIPHER_CTX_ctrl(ctx : EVP_CIPHER_CTX, type : Int32, arg : Int32, ptr : Void*) : Int32
end

module Scheme::Builtins::CipherLibrary
  extend self
  include Scheme::BuiltinHelpers

  # Standard OpenSSL EVP AEAD ctrl codes (openssl/evp.h) -- stable across
  # every OpenSSL 1.1/3.x release, aliased today as EVP_CTRL_AEAD_*.
  EVP_CTRL_GCM_SET_IVLEN =  0x9
  EVP_CTRL_GCM_GET_TAG   = 0x10
  EVP_CTRL_GCM_SET_TAG   = 0x11

  KEY_SIZE   = 32 # AES-256
  NONCE_SIZE = 12 # GCM's standard 96-bit nonce
  TAG_SIZE   = 16

  @[Scheme::SchemeFn("aes-256-gcm-random-key", min: 0, max: 0)]
  def aes_256_gcm_random_key(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBlob.new(Random::Secure.random_bytes(KEY_SIZE))
  end

  @[Scheme::SchemeFn("aes-256-gcm-random-nonce", min: 0, max: 0)]
  def aes_256_gcm_random_nonce(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBlob.new(Random::Secure.random_bytes(NONCE_SIZE))
  end

  @[Scheme::SchemeFn("aes-256-gcm-encrypt", min: 3, max: 4)]
  def aes_256_gcm_encrypt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = cipher_bytes_arg(args[0], "aes-256-gcm-encrypt")
    nonce = cipher_bytes_arg(args[1], "aes-256-gcm-encrypt")
    plaintext = cipher_bytes_arg(args[2], "aes-256-gcm-encrypt")
    aad = args.size > 3 ? cipher_bytes_arg(args[3], "aes-256-gcm-encrypt") : Bytes.empty
    cipher_check_key_nonce(key, nonce, "aes-256-gcm-encrypt")

    ctx = cipher_new_ctx(key, nonce, encrypt: true, who: "aes-256-gcm-encrypt")
    begin
      cipher_feed_aad(ctx, aad, "aes-256-gcm-encrypt")
      outbuf = Bytes.new(plaintext.size + TAG_SIZE)
      outlen = 0
      cipher_check(LibCrypto.evp_cipherupdate(ctx, outbuf, pointerof(outlen), plaintext, plaintext.size), "aes-256-gcm-encrypt")
      total = outlen
      finlen = 0
      cipher_check(LibCrypto.evp_cipherfinal_ex(ctx, outbuf[total, outbuf.size - total], pointerof(finlen)), "aes-256-gcm-encrypt")
      total += finlen
      ciphertext = outbuf[0, total].dup

      tag = Bytes.new(TAG_SIZE)
      cipher_check(LibCrypto.evp_cipher_ctx_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, TAG_SIZE, tag), "aes-256-gcm-encrypt")

      Scheme.a_to_list([
        Cons.new(SchemeStr.new("ciphertext"), SchemeBlob.new(ciphertext)).as(SchemeValue),
        Cons.new(SchemeStr.new("tag"), SchemeBlob.new(tag)).as(SchemeValue),
      ])
    ensure
      LibCrypto.evp_cipher_ctx_free(ctx)
    end
  end

  @[Scheme::SchemeFn("aes-256-gcm-decrypt", min: 4, max: 5)]
  def aes_256_gcm_decrypt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = cipher_bytes_arg(args[0], "aes-256-gcm-decrypt")
    nonce = cipher_bytes_arg(args[1], "aes-256-gcm-decrypt")
    ciphertext = cipher_bytes_arg(args[2], "aes-256-gcm-decrypt")
    tag = cipher_bytes_arg(args[3], "aes-256-gcm-decrypt")
    aad = args.size > 4 ? cipher_bytes_arg(args[4], "aes-256-gcm-decrypt") : Bytes.empty
    cipher_check_key_nonce(key, nonce, "aes-256-gcm-decrypt")
    if tag.size != TAG_SIZE
      raise SchemeRuntimeError.new("aes-256-gcm-decrypt: expected a #{TAG_SIZE}-byte tag, got #{tag.size} bytes")
    end

    ctx = cipher_new_ctx(key, nonce, encrypt: false, who: "aes-256-gcm-decrypt")
    begin
      cipher_feed_aad(ctx, aad, "aes-256-gcm-decrypt")
      outbuf = Bytes.new(ciphertext.size + TAG_SIZE)
      outlen = 0
      cipher_check(LibCrypto.evp_cipherupdate(ctx, outbuf, pointerof(outlen), ciphertext, ciphertext.size), "aes-256-gcm-decrypt")
      total = outlen
      cipher_check(LibCrypto.evp_cipher_ctx_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, TAG_SIZE, tag), "aes-256-gcm-decrypt")
      finlen = 0
      ok = LibCrypto.evp_cipherfinal_ex(ctx, outbuf[total, outbuf.size - total], pointerof(finlen))
      unless ok == 1
        raise SchemeRuntimeError.new("aes-256-gcm-decrypt: authentication failed (tag mismatch)")
      end
      total += finlen
      SchemeBlob.new(outbuf[0, total].dup)
    ensure
      LibCrypto.evp_cipher_ctx_free(ctx)
    end
  end

  private def cipher_new_ctx(key : Bytes, nonce : Bytes, encrypt : Bool, who : String) : LibCrypto::EVP_CIPHER_CTX
    ctx = LibCrypto.evp_cipher_ctx_new
    raise SchemeRuntimeError.new("#{who}: failed to allocate a cipher context") if ctx.null?
    evp = LibCrypto.evp_get_cipherbyname("aes-256-gcm")
    raise SchemeRuntimeError.new("#{who}: aes-256-gcm not available in this OpenSSL build") if evp.null?
    enc = encrypt ? 1 : 0
    cipher_check(LibCrypto.evp_cipherinit_ex(ctx, evp, nil, nil, nil, enc), who)
    cipher_check(LibCrypto.evp_cipher_ctx_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, nonce.size, Pointer(Void).null), who)
    cipher_check(LibCrypto.evp_cipherinit_ex(ctx, nil, nil, key, nonce, enc), who)
    ctx
  end

  private def cipher_feed_aad(ctx : LibCrypto::EVP_CIPHER_CTX, aad : Bytes, who : String) : Nil
    return if aad.empty?
    outlen = 0
    cipher_check(LibCrypto.evp_cipherupdate(ctx, Pointer(UInt8).null, pointerof(outlen), aad, aad.size), who)
  end

  private def cipher_check(ret : Int32, who : String) : Nil
    raise SchemeRuntimeError.new("#{who}: an OpenSSL EVP call failed") unless ret == 1
  end

  # A too-short key/nonce here would make the EVP calls above read PAST
  # the end of the given buffer (EVP_CipherInit_ex trusts the cipher's
  # own declared key/iv length, not whatever size the caller's buffer
  # actually is) -- this check is a memory-safety gate, not just an
  # API-correctness one, and must run before any FFI call touches key/nonce.
  private def cipher_check_key_nonce(key : Bytes, nonce : Bytes, who : String) : Nil
    raise SchemeRuntimeError.new("#{who}: expected a #{KEY_SIZE}-byte key, got #{key.size} bytes") unless key.size == KEY_SIZE
    raise SchemeRuntimeError.new("#{who}: expected a #{NONCE_SIZE}-byte nonce, got #{nonce.size} bytes") unless nonce.size == NONCE_SIZE
  end

  private def cipher_bytes_arg(v : SchemeValue, who : String) : Bytes
    case v
    when SchemeBlob then v.value
    when SchemeStr  then v.value.to_slice
    else
      raise SchemeRuntimeError.new("#{who}: expected a blob or string, got #{v.write_string}")
    end
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "cipher"], Scheme::Builtins::CipherLibrary
  end
end
