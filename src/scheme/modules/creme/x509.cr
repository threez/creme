# ===========================================================================
# x509 module: X.509 certificates, certificate signing requests (CSRs),
# and chain verification (Ruby's OpenSSL::X509).
#
# Crystal's stdlib `openssl/x509/` subdirectory has certificate PARSING
# (`OpenSSL::X509::Certificate`) but no builder API at all and no chain-
# verification (X509_STORE) wrapper -- this reuses the raw EVP_PKEY/X509
# C API directly instead, the same `require "jose"` dependency and
# reopened `lib LibCrypto` technique (creme pkey)'s own pkey.cr already
# uses (jose.cr's own vendored LibCryptoJose has no X509 declarations at
# all -- certificates are outside JOSE's own scope -- so every X509_*/
# ASN1_*/PEM_*_X509 binding this file needs beyond what Crystal's stdlib
# LibCrypto already has is declared below, reopening `lib LibCrypto`
# itself since @[Link]-bound `fun` declarations conflict at the whole-
# program symbol level, not per-lib-block, if redeclared elsewhere).
#
# An x509-cert/x509-csr handle is a SchemeBox (tags "x509-cert"/
# "x509-csr") wrapping the cert/CSR's own PEM text -- the same
# reconstruct-a-transient-native-object-per-operation design (creme
# pkey)'s own PKeyHandle already uses (see that file's own header
# comment for why): never a live X509*/X509_REQ* held persistently.
# ===========================================================================

require "jose"

lib LibCrypto
  # ameba:disable Naming/TypeNames
  alias X509_REQ = Void*
  # ameba:disable Naming/TypeNames
  alias ASN1_INTEGER = Void*
  # ameba:disable Naming/TypeNames
  alias ASN1_TIME = Void*

  fun X509_set_version(x : X509, version : LibC::Long) : LibC::Int
  fun X509_get_serialNumber(x : X509) : ASN1_INTEGER
  fun ASN1_INTEGER_set(a : ASN1_INTEGER, v : LibC::Long) : LibC::Int
  fun X509_getm_notBefore(x : X509) : ASN1_TIME
  fun X509_getm_notAfter(x : X509) : ASN1_TIME
  fun X509_gmtime_adj(s : ASN1_TIME, adj : LibC::Long) : ASN1_TIME
  fun X509_set_pubkey(x : X509, pkey : LibCryptoJose::EVP_PKEY) : LibC::Int
  fun X509_get_pubkey(x : X509) : LibCryptoJose::EVP_PKEY
  fun X509_get_issuer_name(x : X509) : X509_NAME
  fun X509_set_issuer_name(x : X509, name : X509_NAME) : LibC::Int
  fun X509_NAME_get_text_by_NID(name : X509_NAME, nid : LibC::Int, buf : UInt8*, len : LibC::Int) : LibC::Int
  fun X509_sign(x : X509, pkey : LibCryptoJose::EVP_PKEY, md : EVP_MD) : LibC::Int
  fun X509_verify(x : X509, pkey : LibCryptoJose::EVP_PKEY) : LibC::Int
  fun PEM_read_bio_X509(bp : Bio*, x : X509*, cb : Void*, u : Void*) : X509
  fun PEM_write_bio_X509(bp : Bio*, x : X509) : LibC::Int
  fun ASN1_TIME_to_tm(t : ASN1_TIME, tm : LibC::Tm*) : LibC::Int
  fun EVP_PKEY_get_id(pkey : LibCryptoJose::EVP_PKEY) : LibC::Int
  fun EVP_PKEY_get1_RSA(pkey : LibCryptoJose::EVP_PKEY) : LibCryptoJose::RSA
  fun EVP_PKEY_get1_EC_KEY(pkey : LibCryptoJose::EVP_PKEY) : EC_KEY

  fun X509_REQ_new : X509_REQ
  fun X509_REQ_free(req : X509_REQ)
  fun X509_REQ_set_version(req : X509_REQ, version : LibC::Long) : LibC::Int
  fun X509_REQ_set_subject_name(req : X509_REQ, name : X509_NAME) : LibC::Int
  fun X509_REQ_get_subject_name(req : X509_REQ) : X509_NAME
  fun X509_REQ_set_pubkey(req : X509_REQ, pkey : LibCryptoJose::EVP_PKEY) : LibC::Int
  fun X509_REQ_get_pubkey(req : X509_REQ) : LibCryptoJose::EVP_PKEY
  fun X509_REQ_sign(req : X509_REQ, pkey : LibCryptoJose::EVP_PKEY, md : EVP_MD) : LibC::Int
  fun X509_REQ_verify(req : X509_REQ, pkey : LibCryptoJose::EVP_PKEY) : LibC::Int
  fun PEM_read_bio_X509_REQ(bp : Bio*, x : X509_REQ*, cb : Void*, u : Void*) : X509_REQ
  fun PEM_write_bio_X509_REQ(bp : Bio*, x : X509_REQ) : LibC::Int

  fun X509_STORE_new : X509_STORE
  fun X509_STORE_free(store : X509_STORE)
  fun X509_STORE_CTX_new : X509_STORE_CTX
  fun X509_STORE_CTX_free(ctx : X509_STORE_CTX)
  fun X509_STORE_CTX_init(ctx : X509_STORE_CTX, store : X509_STORE, x : X509, chain : Void*) : LibC::Int
  fun X509_STORE_CTX_get_error(ctx : X509_STORE_CTX) : LibC::Int
  fun X509_verify_cert_error_string(n : LibC::Long) : UInt8*

  # basicConstraints CA:TRUE, needed on any cert used as an X509_STORE
  # trust anchor -- OpenSSL's default chain verification rejects a CA
  # cert lacking this extension ("invalid CA certificate"), confirmed
  # directly during development.
  fun X509V3_EXT_nconf_nid(conf : Void*, ctx : Void*, ext_nid : LibC::Int, value : UInt8*) : X509_EXTENSION
end

private NID_BASIC_CONSTRAINTS = 87
private SUBJECT_NIDS          = {
  "CN"           => 13,
  "O"            => 17,
  "OU"           => 18,
  "C"            => 14,
  "L"            => 7,
  "ST"           => 8,
  "emailAddress" => 48,
}
private MBSTRING_UTF8 = 0x1000

module Scheme::Builtins::X509Library
  extend self
  include Scheme::BuiltinHelpers

  # ── certificate/CSR generation ─────────────────────────────────────────────

  @[Scheme::SchemeFn("x509-self-signed-certificate", min: 2, max: 3)]
  def x509_self_signed_certificate(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = pkey_arg(args[0], "x509-self-signed-certificate")
    raise SchemeRuntimeError.new("x509-self-signed-certificate: expected a private key") unless key.private_key?
    subject = x509_subject_arg(args[1], "x509-self-signed-certificate")
    days = args[2]? ? int_arg(args[2], "x509-self-signed-certificate").to_i32 : 365

    pkey = pkey_to_evp(key, "x509-self-signed-certificate")
    begin
      name = x509_build_name(subject, "x509-self-signed-certificate")
      cert = LibCrypto.x509_new
      LibCrypto.X509_set_version(cert, 2_i64)
      LibCrypto.ASN1_INTEGER_set(LibCrypto.X509_get_serialNumber(cert), 1_i64)
      LibCrypto.X509_gmtime_adj(LibCrypto.X509_getm_notBefore(cert), 0_i64)
      LibCrypto.X509_gmtime_adj(LibCrypto.X509_getm_notAfter(cert), days.to_i64 * 24 * 3600)
      LibCrypto.X509_set_pubkey(cert, pkey)
      LibCrypto.x509_set_subject_name(cert, name)
      LibCrypto.X509_set_issuer_name(cert, name)
      x509_add_ca_extension(cert, "x509-self-signed-certificate")
      ret = LibCrypto.X509_sign(cert, pkey, LibCrypto.evp_sha256)
      raise SchemeRuntimeError.new("x509-self-signed-certificate: X509_sign failed") if ret == 0
      pem_len = 0
      pem = x509_cert_to_pem(cert, pointerof(pem_len), "x509-self-signed-certificate")
      x509_cert_box(pem)
    ensure
      LibCryptoJose.EVP_PKEY_free(pkey)
    end
  end

  @[Scheme::SchemeFn("x509-create-csr", min: 2, max: 2)]
  def x509_create_csr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    key = pkey_arg(args[0], "x509-create-csr")
    raise SchemeRuntimeError.new("x509-create-csr: expected a private key") unless key.private_key?
    subject = x509_subject_arg(args[1], "x509-create-csr")

    pkey = pkey_to_evp(key, "x509-create-csr")
    begin
      name = x509_build_name(subject, "x509-create-csr")
      req = LibCrypto.X509_REQ_new
      LibCrypto.X509_REQ_set_version(req, 0_i64)
      LibCrypto.X509_REQ_set_subject_name(req, name)
      LibCrypto.X509_REQ_set_pubkey(req, pkey)
      ret = LibCrypto.X509_REQ_sign(req, pkey, LibCrypto.evp_sha256)
      raise SchemeRuntimeError.new("x509-create-csr: X509_REQ_sign failed") if ret == 0
      x509_csr_box(x509_csr_to_pem(req, "x509-create-csr"))
    ensure
      LibCryptoJose.EVP_PKEY_free(pkey)
    end
  end

  @[Scheme::SchemeFn("x509-sign-csr", min: 3, max: 4)]
  def x509_sign_csr(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    csr_pem = x509_csr_arg(args[0], "x509-sign-csr")
    ca_cert_pem = x509_cert_arg(args[1], "x509-sign-csr")
    ca_key = pkey_arg(args[2], "x509-sign-csr")
    raise SchemeRuntimeError.new("x509-sign-csr: expected a private CA key") unless ca_key.private_key?
    days = args[3]? ? int_arg(args[3], "x509-sign-csr").to_i32 : 365

    req = x509_pem_to_csr(csr_pem, "x509-sign-csr")
    ca_cert = x509_pem_to_cert(ca_cert_pem, "x509-sign-csr")
    ca_pkey = pkey_to_evp(ca_key, "x509-sign-csr")
    req_pubkey = LibCrypto.X509_REQ_get_pubkey(req)
    begin
      raise SchemeRuntimeError.new("x509-sign-csr: CSR self-signature does not verify") unless LibCrypto.X509_REQ_verify(req, req_pubkey) == 1

      cert = LibCrypto.x509_new
      LibCrypto.X509_set_version(cert, 2_i64)
      LibCrypto.ASN1_INTEGER_set(LibCrypto.X509_get_serialNumber(cert), 2_i64)
      LibCrypto.X509_gmtime_adj(LibCrypto.X509_getm_notBefore(cert), 0_i64)
      LibCrypto.X509_gmtime_adj(LibCrypto.X509_getm_notAfter(cert), days.to_i64 * 24 * 3600)
      LibCrypto.X509_set_pubkey(cert, req_pubkey)
      LibCrypto.x509_set_subject_name(cert, LibCrypto.X509_REQ_get_subject_name(req))
      LibCrypto.X509_set_issuer_name(cert, LibCrypto.x509_get_subject_name(ca_cert))
      ret = LibCrypto.X509_sign(cert, ca_pkey, LibCrypto.evp_sha256)
      raise SchemeRuntimeError.new("x509-sign-csr: X509_sign failed") if ret == 0
      pem_len = 0
      pem = x509_cert_to_pem(cert, pointerof(pem_len), "x509-sign-csr")
      x509_cert_box(pem)
    ensure
      LibCryptoJose.EVP_PKEY_free(req_pubkey)
      LibCryptoJose.EVP_PKEY_free(ca_pkey)
    end
  end

  # ── PEM import/export ──────────────────────────────────────────────────────

  @[Scheme::SchemeFn("x509-cert->pem", min: 1, max: 1)]
  def x509_cert_to_pem_fn(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(x509_cert_arg(args[0], "x509-cert->pem"))
  end

  @[Scheme::SchemeFn("pem->x509-cert", min: 1, max: 1)]
  def pem_to_x509_cert_fn(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    pem = string_arg(args[0], "pem->x509-cert")
    x509_pem_to_cert(pem, "pem->x509-cert") # validates it parses
    x509_cert_box(pem)
  end

  # ── accessors ───────────────────────────────────────────────────────────────

  @[Scheme::SchemeFn("x509-cert-subject", min: 1, max: 1)]
  def x509_cert_subject(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    cert = x509_pem_to_cert(x509_cert_arg(args[0], "x509-cert-subject"), "x509-cert-subject")
    x509_name_alist(LibCrypto.x509_get_subject_name(cert))
  end

  @[Scheme::SchemeFn("x509-cert-issuer", min: 1, max: 1)]
  def x509_cert_issuer(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    cert = x509_pem_to_cert(x509_cert_arg(args[0], "x509-cert-issuer"), "x509-cert-issuer")
    x509_name_alist(LibCrypto.X509_get_issuer_name(cert))
  end

  @[Scheme::SchemeFn("x509-cert-public-key", min: 1, max: 1)]
  def x509_cert_public_key(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    cert = x509_pem_to_cert(x509_cert_arg(args[0], "x509-cert-public-key"), "x509-cert-public-key")
    pkey = LibCrypto.X509_get_pubkey(cert)
    raise SchemeRuntimeError.new("x509-cert-public-key: X509_get_pubkey failed") if pkey.null?
    begin
      evp_pkey_to_box(pkey, "x509-cert-public-key")
    ensure
      LibCryptoJose.EVP_PKEY_free(pkey)
    end
  end

  @[Scheme::SchemeFn("x509-cert-not-before", min: 1, max: 1)]
  def x509_cert_not_before(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    cert = x509_pem_to_cert(x509_cert_arg(args[0], "x509-cert-not-before"), "x509-cert-not-before")
    SchemeFloat.new(x509_asn1_time_to_epoch(LibCrypto.X509_getm_notBefore(cert), "x509-cert-not-before").to_f64)
  end

  @[Scheme::SchemeFn("x509-cert-not-after", min: 1, max: 1)]
  def x509_cert_not_after(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    cert = x509_pem_to_cert(x509_cert_arg(args[0], "x509-cert-not-after"), "x509-cert-not-after")
    SchemeFloat.new(x509_asn1_time_to_epoch(LibCrypto.X509_getm_notAfter(cert), "x509-cert-not-after").to_f64)
  end

  # ── chain verification ──────────────────────────────────────────────────────

  @[Scheme::SchemeFn("x509-verify-chain", min: 2, max: 2)]
  def x509_verify_chain(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    cert = x509_pem_to_cert(x509_cert_arg(args[0], "x509-verify-chain"), "x509-verify-chain")
    ca_pems = x509_cert_list_arg(args[1], "x509-verify-chain")

    store = LibCrypto.X509_STORE_new
    raise SchemeRuntimeError.new("x509-verify-chain: X509_STORE_new failed") if store.null?
    begin
      ca_pems.each do |ca_pem|
        ca_cert = x509_pem_to_cert(ca_pem, "x509-verify-chain")
        LibCrypto.x509_store_add_cert(store, ca_cert)
      end
      ctx = LibCrypto.X509_STORE_CTX_new
      raise SchemeRuntimeError.new("x509-verify-chain: X509_STORE_CTX_new failed") if ctx.null?
      begin
        raise SchemeRuntimeError.new("x509-verify-chain: X509_STORE_CTX_init failed") unless LibCrypto.X509_STORE_CTX_init(ctx, store, cert, nil) == 1
        ok = LibCrypto.x509_verify_cert(ctx)
        if ok == 1
          SchemeBool.of(true)
        else
          err = LibCrypto.X509_STORE_CTX_get_error(ctx)
          reason = String.new(LibCrypto.X509_verify_cert_error_string(err.to_i64))
          raise SchemeRuntimeError.new("x509-verify-chain: #{reason}")
        end
      ensure
        LibCrypto.X509_STORE_CTX_free(ctx)
      end
    ensure
      LibCrypto.X509_STORE_free(store)
    end
  end

  # ── internal helpers ────────────────────────────────────────────────────────

  private def bio_to_string(bio : LibCrypto::Bio*) : String
    data_ptr = Pointer(UInt8).null
    len = LibCryptoJose.BIO_ctrl(bio, LibCryptoJose::BIO_CTRL_INFO, 0_i64, pointerof(data_ptr).as(Void*))
    String.new(data_ptr, len.to_i)
  end

  private def x509_build_name(subject : Array({String, String}), who : String) : LibCrypto::X509_NAME
    name = LibCrypto.x509_name_new
    subject.each do |field, value|
      ret = LibCrypto.x509_name_add_entry_by_txt(name, field, MBSTRING_UTF8, value, value.bytesize, -1, 0)
      raise SchemeRuntimeError.new("#{who}: invalid subject field '#{field}'") if ret.null?
    end
    name
  end

  private def x509_add_ca_extension(cert : LibCrypto::X509, who : String) : Nil
    ext = LibCrypto.X509V3_EXT_nconf_nid(Pointer(Void).null, Pointer(Void).null, NID_BASIC_CONSTRAINTS, "critical,CA:TRUE")
    raise SchemeRuntimeError.new("#{who}: failed to build basicConstraints extension") if ext.null?
    LibCrypto.x509_add_ext(cert, ext, -1)
  end

  private def x509_name_alist(name : LibCrypto::X509_NAME) : SchemeValue
    buf = Bytes.new(256)
    pairs = [] of SchemeValue
    SUBJECT_NIDS.each do |field, nid|
      idx = LibCrypto.x509_name_get_index_by_nid(name, nid, -1)
      next if idx < 0
      n = LibCrypto.X509_NAME_get_text_by_NID(name, nid, buf, buf.size)
      next if n < 0
      pairs << Cons.new(SchemeStr.new(field), SchemeStr.new(String.new(buf[0, n]))).as(SchemeValue)
    end
    Scheme.a_to_list(pairs)
  end

  private def x509_cert_to_pem(cert : LibCrypto::X509, len_out : Pointer(Int32), who : String) : String
    bio = LibCrypto.BIO_new(LibCryptoJose.BIO_s_mem)
    raise SchemeRuntimeError.new("#{who}: BIO_new failed") if bio.null?
    begin
      ret = LibCrypto.PEM_write_bio_X509(bio, cert)
      raise SchemeRuntimeError.new("#{who}: failed to write certificate PEM") unless ret == 1
      bio_to_string(bio)
    ensure
      LibCrypto.BIO_free(bio)
    end
  end

  private def x509_csr_to_pem(req : LibCrypto::X509_REQ, who : String) : String
    bio = LibCrypto.BIO_new(LibCryptoJose.BIO_s_mem)
    raise SchemeRuntimeError.new("#{who}: BIO_new failed") if bio.null?
    begin
      ret = LibCrypto.PEM_write_bio_X509_REQ(bio, req)
      raise SchemeRuntimeError.new("#{who}: failed to write CSR PEM") unless ret == 1
      bio_to_string(bio)
    ensure
      LibCrypto.BIO_free(bio)
    end
  end

  private def x509_pem_to_cert(pem : String, who : String) : LibCrypto::X509
    bio = LibCryptoJose.BIO_new_mem_buf(pem.to_unsafe.as(Void*), pem.bytesize)
    cert = LibCrypto.PEM_read_bio_X509(bio, Pointer(LibCrypto::X509).null, Pointer(Void).null, Pointer(Void).null)
    LibCrypto.BIO_free(bio)
    raise SchemeRuntimeError.new("#{who}: not a recognizable X.509 certificate PEM") if cert.null?
    cert
  end

  private def x509_pem_to_csr(pem : String, who : String) : LibCrypto::X509_REQ
    bio = LibCryptoJose.BIO_new_mem_buf(pem.to_unsafe.as(Void*), pem.bytesize)
    req = LibCrypto.PEM_read_bio_X509_REQ(bio, Pointer(LibCrypto::X509_REQ).null, Pointer(Void).null, Pointer(Void).null)
    LibCrypto.BIO_free(bio)
    raise SchemeRuntimeError.new("#{who}: not a recognizable CSR PEM") if req.null?
    req
  end

  private def x509_asn1_time_to_epoch(t : LibCrypto::ASN1_TIME, who : String) : Int64
    tm = LibC::Tm.new
    ret = LibCrypto.ASN1_TIME_to_tm(t, pointerof(tm))
    raise SchemeRuntimeError.new("#{who}: ASN1_TIME_to_tm failed") if ret == 0
    LibC.timegm(pointerof(tm)).to_i64
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

  private def pem_to_rsa(pem : String, who : String) : LibCryptoJose::RSA
    bio = LibCryptoJose.BIO_new_mem_buf(pem.to_unsafe.as(Void*), pem.bytesize)
    rsa = LibCryptoJose.PEM_read_bio_RSAPrivateKey(bio, Pointer(LibCryptoJose::RSA).null, Pointer(Void).null, Pointer(Void).null)
    LibCrypto.BIO_free(bio)
    raise SchemeRuntimeError.new("#{who}: not a recognizable RSA private key PEM") if rsa.null?
    rsa
  end

  private def pem_to_ec(pem : String, who : String) : LibCrypto::EC_KEY
    bio = LibCryptoJose.BIO_new_mem_buf(pem.to_unsafe.as(Void*), pem.bytesize)
    ec = LibCryptoJose.PEM_read_bio_ECPrivateKey(bio, nil, Pointer(Void).null, Pointer(Void).null)
    LibCrypto.BIO_free(bio)
    raise SchemeRuntimeError.new("#{who}: not a recognizable EC private key PEM") if ec.null?
    ec
  end

  # Converts a generic EVP_PKEY (e.g. one extracted from a certificate via
  # X509_get_pubkey, which only ever has public material) into a
  # (creme pkey) PKeyHandle/SchemeBox, mirroring pkey.cr's own
  # rsa_to_pem/ec_to_pem PEM-serialization exactly.
  private def evp_pkey_to_box(pkey : LibCryptoJose::EVP_PKEY, who : String) : SchemeValue
    case LibCrypto.EVP_PKEY_get_id(pkey)
    when 6 # EVP_PKEY_RSA
      rsa = LibCrypto.EVP_PKEY_get1_RSA(pkey)
      raise SchemeRuntimeError.new("#{who}: EVP_PKEY_get1_RSA failed") if rsa.null?
      begin
        bio = LibCrypto.BIO_new(LibCryptoJose.BIO_s_mem)
        LibCryptoJose.PEM_write_bio_RSA_PUBKEY(bio, rsa)
        pem = bio_to_string(bio)
        LibCrypto.BIO_free(bio)
        SchemeBox.new("pkey", PKeyHandle.new(PKeyKind::Rsa, false, pem), "#<pkey:rsa:public>")
      ensure
        LibCryptoJose.RSA_free(rsa)
      end
    else # EC (any other key type this module produces)
      ec = LibCrypto.EVP_PKEY_get1_EC_KEY(pkey)
      raise SchemeRuntimeError.new("#{who}: EVP_PKEY_get1_EC_KEY failed") if ec.null?
      begin
        bio = LibCrypto.BIO_new(LibCryptoJose.BIO_s_mem)
        LibCryptoJose.PEM_write_bio_EC_PUBKEY(bio, ec)
        pem = bio_to_string(bio)
        LibCrypto.BIO_free(bio)
        SchemeBox.new("pkey", PKeyHandle.new(PKeyKind::Ec, false, pem), "#<pkey:ec:public>")
      ensure
        LibCrypto.ec_key_free(ec)
      end
    end
  end

  private def pkey_box(key : PKeyHandle) : SchemeValue
    SchemeBox.new("pkey", key, "#<pkey:#{key.kind}:#{key.private_key? ? "private" : "public"}>")
  end

  private def pkey_arg(v : SchemeValue, who : String) : PKeyHandle
    raise SchemeRuntimeError.new("#{who}: expected a pkey, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "pkey"
    v.get(PKeyHandle)
  end

  private def x509_cert_box(pem : String) : SchemeValue
    SchemeBox.new("x509-cert", pem, "#<x509-cert>")
  end

  private def x509_csr_box(pem : String) : SchemeValue
    SchemeBox.new("x509-csr", pem, "#<x509-csr>")
  end

  private def x509_cert_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected an x509 certificate, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "x509-cert"
    v.get(String)
  end

  private def x509_csr_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected an x509 CSR, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "x509-csr"
    v.get(String)
  end

  private def x509_cert_list_arg(v : SchemeValue, who : String) : Array(String)
    raise SchemeRuntimeError.new("#{who}: expected a list of x509 certificates") unless Scheme.proper_list?(v)
    Scheme.list_to_a(v).map { |cert_value| x509_cert_arg(cert_value, who) }
  end

  private def x509_subject_arg(v : SchemeValue, who : String) : Array({String, String})
    raise SchemeRuntimeError.new("#{who}: expected an alist of (field . value) pairs") unless Scheme.proper_list?(v)
    Scheme.list_to_a(v).map do |pair|
      raise SchemeRuntimeError.new("#{who}: expected an alist of (field . value) pairs") unless pair.is_a?(Cons)
      field = pair.car
      value = pair.cdr
      raise SchemeRuntimeError.new("#{who}: expected string field/value in subject alist") unless field.is_a?(SchemeStr) && value.is_a?(SchemeStr)
      {field.value, value.value}
    end
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "x509"], Scheme::Builtins::X509Library
  end
end
