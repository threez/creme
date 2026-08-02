# ===========================================================================
# pkey module: RSA/EC asymmetric keys — generation, signing/verification,
# RSA-OAEP encryption, PEM import/export (Ruby's OpenSSL::PKey::RSA/EC).
#
# Crystal's stdlib has NO OpenSSL::PKey class hierarchy at all (confirmed:
# no pkey.cr/pkey/rsa.cr/pkey/ec.cr anywhere in its openssl/ directory) --
# a bigger gap than (creme cipher)'s own finding that OpenSSL::Cipher
# exists but lacks GCM/AEAD methods; here the whole class is simply
# absent. This reuses `require "jose"` (already a project dependency,
# see jose.cr)'s own vendored LibCryptoJose FFI bindings instead of
# re-declaring a parallel `lib LibCrypto` block from scratch -- every
# EVP_PKEY/RSA/EC_KEY/PEM/BIO call this file makes is proven correct
# already, by that shard's own JWK/JWS/JWE code (see lib/jose/src/jose/
# jwk.cr's generate_key/to_pem/from_pem and jws.cr's DigestSign/Verify,
# jwa/rsa_kw.cr's RSA-OAEP EVP_PKEY_CTX code -- this module's own
# sign/verify/encrypt/decrypt helpers below are directly modeled on
# those, verified independently against the system `openssl` CLI during
# development).
#
# A <pkey> handle is a SchemeBox (tag "pkey") wrapping a plain PKeyHandle
# (kind + private?-flag + the key's own PEM text) -- never a live native
# RSA*/EC_KEY* pointer held persistently. This mirrors (creme jose)'s own
# JWK, which reconstructs a transient native key from its stored
# JSON-map representation for each operation rather than holding one
# open indefinitely: every sign/verify/encrypt/decrypt/pkey->pem call
# below parses the stored PEM into a fresh RSA*/EC_KEY*, performs the
# one operation, and frees it immediately -- no manual lifetime tracking,
# no GC-finalizer subtlety, no risk of a stale/double-freed native handle.
# ===========================================================================

require "jose"

enum PKeyKind
  Rsa
  Ec
end

# Not `private` -- (creme x509) also constructs these directly, e.g. for
# x509-cert-public-key's extracted public key.
class PKeyHandle
  getter kind : PKeyKind
  getter? private_key : Bool
  getter pem : String

  def initialize(@kind, @private_key, @pem)
  end
end

module Scheme::Builtins::PKeyLibrary
  extend self
  include Scheme::BuiltinHelpers

  # ── generation ────────────────────────────────────────────────────────────

  @[Scheme::SchemeFn("rsa-generate-key", min: 0, max: 1)]
  def rsa_generate_key(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    bits = args[0]? ? int_arg(args[0], "rsa-generate-key").to_i32 : 2048
    raise SchemeRuntimeError.new("rsa-generate-key: bits must be at least 2048, got #{bits}") if bits < 2048

    rsa = LibCryptoJose.RSA_new
    raise SchemeRuntimeError.new("rsa-generate-key: RSA_new failed") if rsa.null?
    begin
      e_bn = LibCryptoJose.BN_new
      raise SchemeRuntimeError.new("rsa-generate-key: BN_new failed") if e_bn.null?
      LibCryptoJose.BN_set_word(e_bn, 65537_u64)
      ret = LibCryptoJose.RSA_generate_key_ex(rsa, bits, e_bn, Pointer(Void).null)
      LibCryptoJose.BN_free(e_bn)
      raise SchemeRuntimeError.new("rsa-generate-key: RSA_generate_key_ex failed") unless ret == 1
      pkey_box(PKeyHandle.new(PKeyKind::Rsa, true, rsa_to_pem(rsa, private_key: true)))
    ensure
      LibCryptoJose.RSA_free(rsa)
    end
  end

  @[Scheme::SchemeFn("ec-generate-key", min: 0, max: 1)]
  def ec_generate_key(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    curve = args[0]? ? pkey_sym_arg(args[0], "ec-generate-key") : "p256"
    nid = ec_curve_nid(curve, "ec-generate-key")

    key = LibCrypto.ec_key_new_by_curve_name(nid)
    raise SchemeRuntimeError.new("ec-generate-key: EC_KEY_new_by_curve_name failed") if key.null?
    begin
      ret = LibCryptoJose.EC_KEY_generate_key(key)
      raise SchemeRuntimeError.new("ec-generate-key: EC_KEY_generate_key failed") unless ret == 1
      pkey_box(PKeyHandle.new(PKeyKind::Ec, true, ec_to_pem(key, private_key: true)))
    ensure
      LibCrypto.ec_key_free(key)
    end
  end

  # ── predicates/accessors ───────────────────────────────────────────────────

  @[Scheme::SchemeFn("pkey?", min: 1, max: 1)]
  def pkey_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "pkey")
  end

  @[Scheme::SchemeFn("pkey-private?", min: 1, max: 1)]
  def pkey_private_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(pkey_arg(args[0], "pkey-private?").private_key?)
  end

  @[Scheme::SchemeFn("pkey-type", min: 1, max: 1)]
  def pkey_type(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeSym.new(pkey_arg(args[0], "pkey-type").kind.rsa? ? "rsa" : "ec")
  end

  @[Scheme::SchemeFn("pkey-public-key", min: 1, max: 1)]
  def pkey_public_key(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = pkey_arg(args[0], "pkey-public-key")
    return pkey_box(PKeyHandle.new(key.kind, false, key.pem)) unless key.private_key?
    case key.kind
    in .rsa?
      rsa = pem_to_rsa(key.pem, "pkey-public-key")
      begin
        pkey_box(PKeyHandle.new(PKeyKind::Rsa, false, rsa_to_pem(rsa, private_key: false)))
      ensure
        LibCryptoJose.RSA_free(rsa)
      end
    in .ec?
      ec = pem_to_ec(key.pem, "pkey-public-key")
      begin
        pkey_box(PKeyHandle.new(PKeyKind::Ec, false, ec_to_pem(ec, private_key: false)))
      ensure
        LibCrypto.ec_key_free(ec)
      end
    end
  end

  # ── PEM import/export ──────────────────────────────────────────────────────

  @[Scheme::SchemeFn("pkey->pem", min: 1, max: 1)]
  def pkey_to_pem(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(pkey_arg(args[0], "pkey->pem").pem)
  end

  @[Scheme::SchemeFn("pem->pkey", min: 1, max: 1)]
  def pem_to_pkey(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    pem = string_arg(args[0], "pem->pkey")

    if rsa = pem_try_rsa_private(pem)
      begin
        return pkey_box(PKeyHandle.new(PKeyKind::Rsa, true, pem))
      ensure
        LibCryptoJose.RSA_free(rsa)
      end
    end
    if rsa = pem_try_rsa_public(pem)
      begin
        return pkey_box(PKeyHandle.new(PKeyKind::Rsa, false, pem))
      ensure
        LibCryptoJose.RSA_free(rsa)
      end
    end
    if ec = pem_try_ec_private(pem)
      begin
        return pkey_box(PKeyHandle.new(PKeyKind::Ec, true, pem))
      ensure
        LibCrypto.ec_key_free(ec)
      end
    end
    if ec = pem_try_ec_public(pem)
      begin
        return pkey_box(PKeyHandle.new(PKeyKind::Ec, false, pem))
      ensure
        LibCrypto.ec_key_free(ec)
      end
    end
    raise SchemeRuntimeError.new("pem->pkey: not a recognizable RSA/EC PEM key")
  end

  # ── sign/verify (shared across RSA and EC, matching Ruby's PKey#sign/#verify) ─

  @[Scheme::SchemeFn("pkey-sign", min: 2, max: 2)]
  def pkey_sign(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = pkey_arg(args[0], "pkey-sign")
    message = pkey_bytes_arg(args[1], "pkey-sign")
    raise SchemeRuntimeError.new("pkey-sign: expected a private key") unless key.private_key?

    pkey = pkey_to_evp(key, "pkey-sign")
    begin
      ctx = LibCrypto.evp_md_ctx_new
      raise SchemeRuntimeError.new("pkey-sign: EVP_MD_CTX_new failed") if ctx.null?
      begin
        ret = LibCryptoJose.EVP_DigestSignInit(ctx, Pointer(LibCryptoJose::EVP_PKEY_CTX).null, LibCrypto.evp_sha256, Pointer(Void).null, pkey)
        raise SchemeRuntimeError.new("pkey-sign: EVP_DigestSignInit failed") unless ret == 1
        ret = LibCrypto.evp_digestupdate(ctx, message, message.size)
        raise SchemeRuntimeError.new("pkey-sign: EVP_DigestUpdate failed") unless ret == 1
        sig_len = LibC::SizeT.new(0)
        LibCryptoJose.EVP_DigestSignFinal(ctx, Pointer(UInt8).null, pointerof(sig_len))
        sig = Bytes.new(sig_len)
        ret = LibCryptoJose.EVP_DigestSignFinal(ctx, sig, pointerof(sig_len))
        raise SchemeRuntimeError.new("pkey-sign: EVP_DigestSignFinal failed") unless ret == 1
        SchemeBlob.new(sig[0, sig_len.to_i])
      ensure
        LibCrypto.evp_md_ctx_free(ctx)
      end
    ensure
      LibCryptoJose.EVP_PKEY_free(pkey)
    end
  end

  @[Scheme::SchemeFn("pkey-verify", min: 3, max: 3)]
  def pkey_verify(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = pkey_arg(args[0], "pkey-verify")
    message = pkey_bytes_arg(args[1], "pkey-verify")
    signature = pkey_bytes_arg(args[2], "pkey-verify")

    pkey = pkey_to_evp(key, "pkey-verify")
    begin
      ctx = LibCrypto.evp_md_ctx_new
      raise SchemeRuntimeError.new("pkey-verify: EVP_MD_CTX_new failed") if ctx.null?
      begin
        ret = LibCryptoJose.EVP_DigestVerifyInit(ctx, Pointer(LibCryptoJose::EVP_PKEY_CTX).null, LibCrypto.evp_sha256, Pointer(Void).null, pkey)
        raise SchemeRuntimeError.new("pkey-verify: EVP_DigestVerifyInit failed") unless ret == 1
        ret = LibCrypto.evp_digestupdate(ctx, message, message.size)
        raise SchemeRuntimeError.new("pkey-verify: EVP_DigestUpdate failed") unless ret == 1
        SchemeBool.of(LibCryptoJose.EVP_DigestVerifyFinal(ctx, signature, signature.size) == 1)
      ensure
        LibCrypto.evp_md_ctx_free(ctx)
      end
    ensure
      LibCryptoJose.EVP_PKEY_free(pkey)
    end
  end

  # ── RSA-OAEP-SHA256 encryption only -- deliberately not legacy PKCS1v1.5 ───
  # encryption padding, the real padding-oracle-vulnerable case (unlike
  # PKCS1v1.5 for SIGNATURES, which pkey-sign above still uses, matching
  # Ruby's own default -- signing isn't the vulnerable direction).

  @[Scheme::SchemeFn("rsa-encrypt", min: 2, max: 2)]
  def rsa_encrypt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = pkey_arg(args[0], "rsa-encrypt")
    plaintext = pkey_bytes_arg(args[1], "rsa-encrypt")
    raise SchemeRuntimeError.new("rsa-encrypt: expected an RSA key") unless key.kind.rsa?
    rsa = pem_to_rsa(key.pem, "rsa-encrypt")
    begin
      SchemeBlob.new(rsa_oaep_op(rsa, plaintext, encrypt: true, who: "rsa-encrypt"))
    ensure
      LibCryptoJose.RSA_free(rsa)
    end
  end

  @[Scheme::SchemeFn("rsa-decrypt", min: 2, max: 2)]
  def rsa_decrypt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = pkey_arg(args[0], "rsa-decrypt")
    ciphertext = pkey_bytes_arg(args[1], "rsa-decrypt")
    raise SchemeRuntimeError.new("rsa-decrypt: expected an RSA key") unless key.kind.rsa?
    raise SchemeRuntimeError.new("rsa-decrypt: expected a private key") unless key.private_key?
    rsa = pem_to_rsa(key.pem, "rsa-decrypt")
    begin
      SchemeBlob.new(rsa_oaep_op(rsa, ciphertext, encrypt: false, who: "rsa-decrypt"))
    ensure
      LibCryptoJose.RSA_free(rsa)
    end
  end

  # ── internal helpers ────────────────────────────────────────────────────────

  private def rsa_oaep_op(rsa : LibCryptoJose::RSA, input : Bytes, encrypt : Bool, who : String) : Bytes
    pkey = LibCryptoJose.EVP_PKEY_new
    raise SchemeRuntimeError.new("#{who}: EVP_PKEY_new failed") if pkey.null?
    begin
      LibCryptoJose.EVP_PKEY_set1_RSA(pkey, rsa)
      ctx = LibCryptoJose.EVP_PKEY_CTX_new(pkey, Pointer(Void).null)
      raise SchemeRuntimeError.new("#{who}: EVP_PKEY_CTX_new failed") if ctx.null?
      begin
        if encrypt
          raise SchemeRuntimeError.new("#{who}: EVP_PKEY_encrypt_init failed") unless LibCryptoJose.EVP_PKEY_encrypt_init(ctx) == 1
        else
          raise SchemeRuntimeError.new("#{who}: EVP_PKEY_decrypt_init failed") unless LibCryptoJose.EVP_PKEY_decrypt_init(ctx) == 1
        end
        unless LibCryptoJose.EVP_PKEY_CTX_ctrl(ctx, LibCryptoJose::EVP_PKEY_RSA, -1, LibCryptoJose::EVP_PKEY_CTRL_RSA_PADDING,
                 LibCryptoJose::RSA_PKCS1_OAEP_PADDING, Pointer(Void).null) > 0
          raise SchemeRuntimeError.new("#{who}: failed to set OAEP padding")
        end
        unless LibCryptoJose.EVP_PKEY_CTX_ctrl(ctx, LibCryptoJose::EVP_PKEY_RSA, -1, LibCryptoJose::EVP_PKEY_CTRL_RSA_OAEP_MD, 0,
                 LibCrypto.evp_sha256.as(Void*)) > 0
          raise SchemeRuntimeError.new("#{who}: failed to set OAEP digest")
        end
        unless LibCryptoJose.EVP_PKEY_CTX_ctrl(ctx, LibCryptoJose::EVP_PKEY_RSA, -1, LibCryptoJose::EVP_PKEY_CTRL_RSA_MGF1_MD, 0,
                 LibCrypto.evp_sha256.as(Void*)) > 0
          raise SchemeRuntimeError.new("#{who}: failed to set MGF1 digest")
        end
        outlen = LibC::SizeT.new(0)
        out_buf = Bytes.empty
        if encrypt
          LibCryptoJose.EVP_PKEY_encrypt(ctx, Pointer(UInt8).null, pointerof(outlen), input, input.size)
          out_buf = Bytes.new(outlen)
          raise SchemeRuntimeError.new("#{who}: EVP_PKEY_encrypt failed") unless LibCryptoJose.EVP_PKEY_encrypt(ctx, out_buf, pointerof(outlen), input, input.size) == 1
        else
          LibCryptoJose.EVP_PKEY_decrypt(ctx, Pointer(UInt8).null, pointerof(outlen), input, input.size)
          out_buf = Bytes.new(outlen)
          raise SchemeRuntimeError.new("#{who}: decryption failed (wrong key, or corrupted/truncated ciphertext)") unless LibCryptoJose.EVP_PKEY_decrypt(ctx, out_buf, pointerof(outlen), input, input.size) == 1
        end
        out_buf[0, outlen.to_i]
      ensure
        LibCryptoJose.EVP_PKEY_CTX_free(ctx)
      end
    ensure
      LibCryptoJose.EVP_PKEY_free(pkey)
    end
  end

  private def pkey_to_evp(key : PKeyHandle, who : String) : LibCryptoJose::EVP_PKEY
    pkey = LibCryptoJose.EVP_PKEY_new
    raise SchemeRuntimeError.new("#{who}: EVP_PKEY_new failed") if pkey.null?
    case key.kind
    in .rsa?
      rsa = pem_to_rsa(key.pem, who)
      LibCryptoJose.EVP_PKEY_set1_RSA(pkey, rsa)
      LibCryptoJose.RSA_free(rsa)
    in .ec?
      ec = pem_to_ec(key.pem, who)
      LibCryptoJose.EVP_PKEY_set1_EC_KEY(pkey, ec)
      LibCrypto.ec_key_free(ec)
    end
    pkey
  end

  private def ec_curve_nid(curve : String, who : String) : Int32
    case curve
    when "p256" then LibCrypto::NID_X9_62_prime256v1
    when "p384" then LibCryptoJose::NID_secp384r1
    when "p521" then LibCryptoJose::NID_secp521r1
    else
      raise SchemeRuntimeError.new("#{who}: unknown curve '#{curve}' (expected p256, p384, or p521)")
    end
  end

  private def bio_to_string(bio : LibCrypto::Bio*) : String
    data_ptr = Pointer(UInt8).null
    len = LibCryptoJose.BIO_ctrl(bio, LibCryptoJose::BIO_CTRL_INFO, 0_i64, pointerof(data_ptr).as(Void*))
    String.new(data_ptr, len.to_i)
  end

  private def rsa_to_pem(rsa : LibCryptoJose::RSA, private_key : Bool) : String
    bio = LibCrypto.BIO_new(LibCryptoJose.BIO_s_mem)
    raise SchemeRuntimeError.new("rsa_to_pem: BIO_new failed") if bio.null?
    begin
      ret = if private_key
              LibCryptoJose.PEM_write_bio_RSAPrivateKey(bio, rsa, Pointer(Void).null, Pointer(UInt8).null, 0, Pointer(Void).null, Pointer(Void).null)
            else
              LibCryptoJose.PEM_write_bio_RSA_PUBKEY(bio, rsa)
            end
      raise SchemeRuntimeError.new("rsa_to_pem: PEM write failed") unless ret == 1
      bio_to_string(bio)
    ensure
      LibCrypto.BIO_free(bio)
    end
  end

  private def ec_to_pem(ec : LibCrypto::EC_KEY, private_key : Bool) : String
    bio = LibCrypto.BIO_new(LibCryptoJose.BIO_s_mem)
    raise SchemeRuntimeError.new("ec_to_pem: BIO_new failed") if bio.null?
    begin
      ret = if private_key
              LibCryptoJose.PEM_write_bio_ECPrivateKey(bio, ec, Pointer(Void).null, Pointer(UInt8).null, 0, Pointer(Void).null, Pointer(Void).null)
            else
              LibCryptoJose.PEM_write_bio_EC_PUBKEY(bio, ec)
            end
      raise SchemeRuntimeError.new("ec_to_pem: PEM write failed") unless ret == 1
      bio_to_string(bio)
    ensure
      LibCrypto.BIO_free(bio)
    end
  end

  private def pem_try_rsa_private(pem : String) : LibCryptoJose::RSA?
    bio = LibCryptoJose.BIO_new_mem_buf(pem.to_unsafe.as(Void*), pem.bytesize)
    rsa = LibCryptoJose.PEM_read_bio_RSAPrivateKey(bio, Pointer(LibCryptoJose::RSA).null, Pointer(Void).null, Pointer(Void).null)
    LibCrypto.BIO_free(bio)
    rsa.null? ? nil : rsa
  end

  private def pem_try_rsa_public(pem : String) : LibCryptoJose::RSA?
    bio = LibCryptoJose.BIO_new_mem_buf(pem.to_unsafe.as(Void*), pem.bytesize)
    rsa = LibCryptoJose.PEM_read_bio_RSA_PUBKEY(bio, Pointer(LibCryptoJose::RSA).null, Pointer(Void).null, Pointer(Void).null)
    LibCrypto.BIO_free(bio)
    rsa.null? ? nil : rsa
  end

  private def pem_try_ec_private(pem : String) : LibCrypto::EC_KEY?
    bio = LibCryptoJose.BIO_new_mem_buf(pem.to_unsafe.as(Void*), pem.bytesize)
    ec = LibCryptoJose.PEM_read_bio_ECPrivateKey(bio, nil, Pointer(Void).null, Pointer(Void).null)
    LibCrypto.BIO_free(bio)
    ec.null? ? nil : ec
  end

  private def pem_try_ec_public(pem : String) : LibCrypto::EC_KEY?
    bio = LibCryptoJose.BIO_new_mem_buf(pem.to_unsafe.as(Void*), pem.bytesize)
    ec = LibCryptoJose.PEM_read_bio_EC_PUBKEY(bio, nil, Pointer(Void).null, Pointer(Void).null)
    LibCrypto.BIO_free(bio)
    ec.null? ? nil : ec
  end

  private def pem_to_rsa(pem : String, who : String) : LibCryptoJose::RSA
    pem_try_rsa_private(pem) || pem_try_rsa_public(pem) || raise SchemeRuntimeError.new("#{who}: not a recognizable RSA PEM key")
  end

  private def pem_to_ec(pem : String, who : String) : LibCrypto::EC_KEY
    pem_try_ec_private(pem) || pem_try_ec_public(pem) || raise SchemeRuntimeError.new("#{who}: not a recognizable EC PEM key")
  end

  private def pkey_box(key : PKeyHandle) : SchemeValue
    SchemeBox.new("pkey", key, "#<pkey:#{key.kind}:#{key.private_key? ? "private" : "public"}>")
  end

  private def pkey_arg(v : SchemeValue, who : String) : PKeyHandle
    raise SchemeRuntimeError.new("#{who}: expected a pkey, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "pkey"
    v.get(PKeyHandle)
  end

  private def pkey_bytes_arg(v : SchemeValue, who : String) : Bytes
    case v
    when SchemeBlob then v.value
    when SchemeStr  then v.value.to_slice
    else
      raise SchemeRuntimeError.new("#{who}: expected a blob or string, got #{v.write_string}")
    end
  end

  private def pkey_sym_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected a symbol, got #{v.write_string}") unless v.is_a?(SchemeSym)
    v.name
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "pkey"], Scheme::Builtins::PKeyLibrary
  end
end
