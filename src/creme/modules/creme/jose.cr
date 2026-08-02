# ===========================================================================
# jose module: JOSE (JSON Object Signing and Encryption) — JWK/JWS/JWT/JWE/
# JWKS, backed by the jose.cr shard (OpenSSL underneath).
#
# JWK/JWKS objects are opaque SchemeBox values (tags "jose-jwk"/"jose-jwks"),
# the same "compile once, use many times" shape as (creme regex)'s compiled
# patterns and (creme sql)'s connections. Compact tokens (JWS/JWT/JWE) are
# plain Scheme strings. Claims/headers round-trip as alists of
# (key . value) conses, matching the (creme json)/(creme sql)/(creme http)
# convention for JSON-object-shaped data.
# ===========================================================================

require "jose"
require "base64"

module Creme::Builtins::JoseLibrary
  extend self
  include Creme::BuiltinHelpers

  # ── JWK ────────────────────────────────────────────────────────────────────

  @[Creme::SchemeFn("jose-jwk-generate-oct", min: 0, max: 1)]
  def jose_jwk_generate_oct(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    size = args[0]? ? int_arg(args[0], "jose-jwk-generate-oct").to_i32 : 32
    jose_jwk_box(JOSE::JWK.generate_key_oct(size))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-generate-oct: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-generate-ec", min: 0, max: 1)]
  def jose_jwk_generate_ec(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    crv = args[0]? ? jose_str_arg(args[0], "jose-jwk-generate-ec") : "P-256"
    jose_jwk_box(JOSE::JWK.generate_key_ec(crv))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-generate-ec: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-generate-rsa", min: 0, max: 1)]
  def jose_jwk_generate_rsa(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    bits = args[0]? ? int_arg(args[0], "jose-jwk-generate-rsa").to_i32 : 2048
    jose_jwk_box(JOSE::JWK.generate_key_rsa(bits))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-generate-rsa: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-generate-okp", min: 0, max: 1)]
  def jose_jwk_generate_okp(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    crv = args[0]? ? jose_str_arg(args[0], "jose-jwk-generate-okp") : "Ed25519"
    jose_jwk_box(JOSE::JWK.generate_key_okp(crv))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-generate-okp: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-from-oct", min: 1, max: 1)]
  def jose_jwk_from_oct(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jose_jwk_box(JOSE::JWK.from_oct(jose_bytes_arg(args[0], "jose-jwk-from-oct")))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-from-oct: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-from-pem", min: 1, max: 1)]
  def jose_jwk_from_pem(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jose_jwk_box(JOSE::JWK.from_pem(jose_str_arg(args[0], "jose-jwk-from-pem")))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-from-pem: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-from-json", min: 1, max: 1)]
  def jose_jwk_from_json(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jose_jwk_box(JOSE::JWK.from_binary(jose_str_arg(args[0], "jose-jwk-from-json")))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-from-json: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-to-pem", min: 1, max: 1)]
  def jose_jwk_to_pem(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(jose_jwk_arg(args[0], "jose-jwk-to-pem").to_pem)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-to-pem: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-to-json", min: 1, max: 1)]
  def jose_jwk_to_json(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(jose_jwk_arg(args[0], "jose-jwk-to-json").to_binary)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-to-json: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-to-public", min: 1, max: 1)]
  def jose_jwk_to_public(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jose_jwk_box(jose_jwk_arg(args[0], "jose-jwk-to-public").to_public)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-to-public: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-with-kid", min: 2, max: 2)]
  def jose_jwk_with_kid(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jwk-with-kid")
    kid = jose_str_arg(args[1], "jose-jwk-with-kid")
    jose_jwk_box(jwk.with(kid: kid))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-with-kid: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-kty", min: 1, max: 1)]
  def jose_jwk_kty(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(jose_jwk_arg(args[0], "jose-jwk-kty").kty)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-kty: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-public?", min: 1, max: 1)]
  def jose_jwk_public_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(jose_jwk_arg(args[0], "jose-jwk-public?").public?)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-public?: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk-private?", min: 1, max: 1)]
  def jose_jwk_private_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(jose_jwk_arg(args[0], "jose-jwk-private?").private?)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwk-private?: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwk?", min: 1, max: 1)]
  def jose_jwk_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "jose-jwk")
  end

  # ── JWS ────────────────────────────────────────────────────────────────────

  @[Creme::SchemeFn("jose-jws-sign", min: 2, max: 3)]
  def jose_jws_sign(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jws-sign")
    payload = jose_str_arg(args[1], "jose-jws-sign")
    overrides = jose_overrides_arg(args[2]?, "jose-jws-sign")
    SchemeStr.new(JOSE::JWS.sign(jwk, payload, overrides).compact)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jws-sign: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jws-verify", min: 2, max: 2)]
  def jose_jws_verify(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jws-verify")
    signed = jose_str_arg(args[1], "jose-jws-verify")
    valid, payload = JOSE::JWS.verify(jwk, signed)
    jose_valid_payload_alist(valid, payload)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jws-verify: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jws-sign-detached", min: 2, max: 3)]
  def jose_jws_sign_detached(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jws-sign-detached")
    payload = jose_str_arg(args[1], "jose-jws-sign-detached")
    overrides = jose_overrides_arg(args[2]?, "jose-jws-sign-detached")
    SchemeStr.new(JOSE::JWS.sign_detached(jwk, payload, overrides))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jws-sign-detached: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jws-verify-detached", min: 3, max: 3)]
  def jose_jws_verify_detached(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jws-verify-detached")
    signed = jose_str_arg(args[1], "jose-jws-verify-detached")
    payload = jose_str_arg(args[2], "jose-jws-verify-detached")
    valid, decoded = JOSE::JWS.verify_detached(jwk, signed, payload)
    jose_valid_payload_alist(valid, decoded)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jws-verify-detached: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jws-sign-json", min: 2, max: 4)]
  def jose_jws_sign_json(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jws-sign-json")
    payload = jose_str_arg(args[1], "jose-jws-sign-json")
    protected_overrides = jose_overrides_arg(args[2]?, "jose-jws-sign-json")
    unprotected = jose_overrides_arg(args[3]?, "jose-jws-sign-json")
    SchemeStr.new(JOSE::JWS.sign_json(jwk, payload, protected_overrides, unprotected))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jws-sign-json: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jws-verify-json", min: 2, max: 2)]
  def jose_jws_verify_json(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jws-verify-json")
    json = jose_str_arg(args[1], "jose-jws-verify-json")
    valid, payload = JOSE::JWS.verify_json(jwk, json)
    jose_valid_payload_alist(valid, payload)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jws-verify-json: #{ex.message}")
  end

  # ── JWT ────────────────────────────────────────────────────────────────────

  @[Creme::SchemeFn("jose-jwt-sign", min: 2, max: 3)]
  def jose_jwt_sign(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jwt-sign")
    claims = jose_claims_arg(args[1], "jose-jwt-sign")
    overrides = jose_overrides_arg(args[2]?, "jose-jwt-sign")
    SchemeStr.new(JOSE::JWT.sign(jwk, JOSE::JWT.from_map(claims), overrides).compact)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwt-sign: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwt-verify", min: 3, max: 4)]
  def jose_jwt_verify(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jwt-verify")
    algorithms = jose_string_list_arg(args[1], "jose-jwt-verify")
    token = jose_str_arg(args[2], "jose-jwt-verify")
    opts = jose_opts_arg(args[3]?, "jose-jwt-verify")
    iss = opts["iss"]?.try(&.as_s)
    aud = opts["aud"]?.try { |any| any.as_a? ? any.as_a.map(&.as_s) : any.as_s }
    typ = opts["typ"]?.try(&.as_s)
    validate_claims = opts["validate-claims"]?.try(&.as_bool) != false

    valid, jwt, header = JOSE::JWT.verify_strict(jwk, algorithms, token,
      iss: iss, aud: aud, typ: typ, validate_claims: validate_claims)

    Creme.a_to_list([
      Cons.new(SchemeStr.new("valid"), SchemeBool.of(valid)).as(SchemeValue),
      Cons.new(SchemeStr.new("claims"), Creme.to_scheme(jwt.to_map)).as(SchemeValue),
      Cons.new(SchemeStr.new("header"), Creme.to_scheme(header)).as(SchemeValue),
    ])
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwt-verify: #{ex.message}")
  end

  # ── JWE ────────────────────────────────────────────────────────────────────

  @[Creme::SchemeFn("jose-jwe-encrypt", min: 2, max: 3)]
  def jose_jwe_encrypt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jwe-encrypt")
    plaintext = jose_str_arg(args[1], "jose-jwe-encrypt")
    overrides = jose_overrides_arg(args[2]?, "jose-jwe-encrypt")
    SchemeStr.new(JOSE::JWE.block_encrypt(jwk, plaintext, overrides).compact)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwe-encrypt: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwe-decrypt", min: 2, max: 2)]
  def jose_jwe_decrypt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jwe-decrypt")
    token = jose_str_arg(args[1], "jose-jwe-decrypt")
    SchemeStr.new(JOSE::JWE.block_decrypt(jwk, token))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwe-decrypt: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwe-password-encrypt", min: 2, max: 3)]
  def jose_jwe_password_encrypt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    password = jose_str_arg(args[0], "jose-jwe-password-encrypt")
    plaintext = jose_str_arg(args[1], "jose-jwe-password-encrypt")
    overrides = jose_overrides_arg(args[2]?, "jose-jwe-password-encrypt")
    SchemeStr.new(JOSE::JWE.block_encrypt(password, plaintext, overrides).compact)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwe-password-encrypt: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwe-password-decrypt", min: 2, max: 2)]
  def jose_jwe_password_decrypt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    password = jose_str_arg(args[0], "jose-jwe-password-decrypt")
    token = jose_str_arg(args[1], "jose-jwe-password-decrypt")
    SchemeStr.new(JOSE::JWE.block_decrypt(password, token))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwe-password-decrypt: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwe-json-encrypt", min: 2, max: 4)]
  def jose_jwe_json_encrypt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jwe-json-encrypt")
    plaintext = jose_str_arg(args[1], "jose-jwe-json-encrypt")
    overrides = jose_overrides_arg(args[2]?, "jose-jwe-json-encrypt")
    aad = args[3]? ? jose_bytes_arg(args[3], "jose-jwe-json-encrypt") : nil
    SchemeStr.new(JOSE::JWE.json_encrypt(jwk, plaintext, overrides, aad))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwe-json-encrypt: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwe-json-decrypt", min: 2, max: 2)]
  def jose_jwe_json_decrypt(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwk = jose_jwk_arg(args[0], "jose-jwe-json-decrypt")
    json = jose_str_arg(args[1], "jose-jwe-json-decrypt")
    SchemeStr.new(JOSE::JWE.json_decrypt(jwk, json))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwe-json-decrypt: #{ex.message}")
  end

  # ── JWKS ───────────────────────────────────────────────────────────────────

  @[Creme::SchemeFn("jose-jwks-new", min: 1, max: 1)]
  def jose_jwks_new(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    keys = Creme.list_to_a(args[0]).map { |v| jose_jwk_arg(v, "jose-jwks-new") }
    jose_jwks_box(JOSE::JWKS.new(keys))
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwks-new: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwks-to-public", min: 1, max: 1)]
  def jose_jwks_to_public(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jose_jwks_box(jose_jwks_arg(args[0], "jose-jwks-to-public").to_public)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwks-to-public: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwks-ref", min: 2, max: 2)]
  def jose_jwks_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    jwks = jose_jwks_arg(args[0], "jose-jwks-ref")
    kid = jose_str_arg(args[1], "jose-jwks-ref")
    if jwk = jwks[kid]?
      jose_jwk_box(jwk)
    else
      FALSE.as(SchemeValue)
    end
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwks-ref: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwks-size", min: 1, max: 1)]
  def jose_jwks_size(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(jose_jwks_arg(args[0], "jose-jwks-size").size.to_i64)
  rescue ex : Exception
    raise SchemeRuntimeError.new("jose-jwks-size: #{ex.message}")
  end

  @[Creme::SchemeFn("jose-jwks?", min: 1, max: 1)]
  def jose_jwks_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "jose-jwks")
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  private def jose_valid_payload_alist(valid : Bool, payload : String) : SchemeValue
    Creme.a_to_list([
      Cons.new(SchemeStr.new("valid"), SchemeBool.of(valid)).as(SchemeValue),
      Cons.new(SchemeStr.new("payload"), SchemeStr.new(payload)).as(SchemeValue),
    ])
  end

  private def jose_jwk_box(jwk : JOSE::JWK) : SchemeValue
    SchemeBox.new("jose-jwk", jwk, "#<jose-jwk:#{jwk.kty}>")
  end

  private def jose_jwks_box(jwks : JOSE::JWKS) : SchemeValue
    SchemeBox.new("jose-jwks", jwks, "#<jose-jwks:#{jwks.size}>")
  end

  private def jose_jwk_arg(v : SchemeValue, who : String) : JOSE::JWK
    raise SchemeRuntimeError.new("#{who}: expected a jose jwk, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "jose-jwk"
    v.get(JOSE::JWK)
  end

  private def jose_jwks_arg(v : SchemeValue, who : String) : JOSE::JWKS
    raise SchemeRuntimeError.new("#{who}: expected a jose jwks, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "jose-jwks"
    v.get(JOSE::JWKS)
  end

  private def jose_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end

  private def jose_bytes_arg(v : SchemeValue, who : String) : Bytes
    case v
    when SchemeBlob then v.value
    when SchemeStr  then v.value.to_slice
    else
      raise SchemeRuntimeError.new("#{who}: expected blob or string, got #{v.write_string}")
    end
  end

  private def jose_string_list_arg(v : SchemeValue, who : String) : Array(String)
    Creme.list_to_a(v).map { |e| jose_str_arg(e, who) }
  end

  # Converts an optional Scheme alist argument into Hash(String, JSON::Any)?
  # for jose.cr's `header_overrides`/`protected_overrides`/`unprotected`
  # parameters.
  private def jose_overrides_arg(v : SchemeValue?, who : String) : Hash(String, JSON::Any)?
    v ? jose_claims_arg(v, who) : nil
  end

  # Converts a Scheme alist of (string . value) conses into Hash(String,
  # JSON::Any), for JWT claims / JWS/JWE header overrides.
  private def jose_claims_arg(v : SchemeValue, who : String) : Hash(String, JSON::Any)
    native = Creme.from_scheme(v)
    raise SchemeRuntimeError.new("#{who}: expected an alist, got #{v.write_string}") unless native.is_a?(Hash)
    native.transform_values { |value| jose_convertible_to_json_any(value) }
  end

  private def jose_convertible_to_json_any(v : Creme::Convertible) : JSON::Any
    case v
    when Nil     then JSON::Any.new(nil)
    when Bool    then JSON::Any.new(v)
    when Int64   then JSON::Any.new(v)
    when Float64 then JSON::Any.new(v)
    when String  then JSON::Any.new(v)
    when Bytes   then JSON::Any.new(Base64.strict_encode(v))
    when Array
      JSON::Any.new(v.map { |e| jose_convertible_to_json_any(e) })
    when Hash
      JSON::Any.new(v.transform_values { |e| jose_convertible_to_json_any(e) })
    else
      raise SchemeRuntimeError.new("unsupported claim/header value")
    end
  end

  # Extracts jose-jwt-verify's optional fourth alist argument (iss/aud/typ/
  # validate-claims) into a plain Hash keyed by those string names, values
  # left as JSON::Any for the caller to coerce per-key.
  private def jose_opts_arg(v : SchemeValue?, who : String) : Hash(String, JSON::Any)
    v ? jose_claims_arg(v, who) : {} of String => JSON::Any
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "jose"], Creme::Builtins::JoseLibrary
  end
end
