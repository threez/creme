# Changelog

All notable changes to this project are documented here, starting from
the first tagged release (`v0.1.0`). Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow `shard.yml`'s own `version:` field (synced into `src/creme.cr`'s
`VERSION` constant via `make version`, then tagged via `make tag` — see
that Makefile target's own header comment).

The 167 commits before this tag are this project's initial development
history (the native `creme` interpreter and the standalone `cvm` VM
both reaching their current shape) — not itemized individually here;
`git log` is the authoritative record for that period. Everything from
`v0.1.0` onward gets a real entry below.

## [Unreleased]

### `libcreme.a`: an embeddable static library, plus `examples/libcream/`

- `make -C icecreme lib` builds `libcreme.a`, a static library an external C
  program can link against to embed `icecreme` directly, instead of
  shelling out to the `icecreme` binary. `#include <icecreme/creme.h>`
  pulls in the whole public surface in one line.
- New embedding-convenience API (`icecreme/embed.c`/`embed.h`):
  `creme_runtime_init()` (bundles `GC_INIT`/default heap sizing/
  `GC_set_oom_fn`/GMP-via-GC redirection into one call), `creme_register_
  global()` (the value-side counterpart of the existing `creme_register_
  builtin()`, for a host-defined constant rather than a function),
  `creme_run_repl()`, and `creme_run_scheme_file()`.
- **The self-hosted compiler is bundled directly into the library at build
  time**: `icecreme/tools/bin2c.c` (a tiny new build-time helper) turns the
  precompiled `compiler-run.ice` into an embedded C byte array, so
  `creme_run_scheme_file()` can compile-and-run a plain `.scm` file with
  zero `--emit-icecreme` precompilation step and no `.ice` file for the
  host to ship. `creme_run_repl()` compiles `icecreme/repl.scm` fresh
  through that same mechanism rather than bundling a separately
  precompiled `repl.ice` — the REPL script needs `read`/`eval`/
  `interaction-environment`, only ever backed by the self-hosted
  compiler's own toolchain setup (see the "REPL" section), so a
  standalone precompiled `repl.ice` aborts on the first form submitted.
- `creme_register_required_builtins()` (and its `BUILTIN_FAMILIES` table)
  moves out of `main.c` into a new `icecreme/builtin_families.c`/`.h` — it
  previously lived alongside `main()`, a real link-symbol clash for any
  embedder building their own executable. Pure move, no CLI behavior
  change. Also adds `creme_register_all_builtins()`, for an embedder
  running scripts it doesn't want to (or can't) inspect ahead of time via
  `creme_peek_required_families`.
- `embed.h` also gains a set of `static inline` value/argument helpers for
  writing a native `BuiltinFn`'s own body — `creme_arg_int`/
  `creme_arg_double`/`creme_arg_bool`/`creme_arg_cstr`/`creme_arg_bytes`/
  `creme_arg_vector` (extract+validate argument N, aborting by name on
  arity/type mismatch — `creme_arg_cstr` for a NUL-terminated copy,
  `creme_arg_bytes` for the raw `(pointer, length)` slice with no copy),
  `creme_cstr_value`/`creme_bytes_value`/`creme_format_value` (build a
  fresh Scheme string from a C string/raw byte slice/`printf`-style format,
  no manual length-counting), and `creme_list_length`/
  `creme_list_to_values`/`creme_list_from_values`/`creme_vector_from_values`
  (convert a Scheme list/vector to/from a plain C array of `Value`s) — none
  add anything to `libcreme.a` itself (pure `static inline`). icecreme's
  own `bi_*` builtins across every `.c` file now use these directly too,
  in place of their previous hand-rolled arity/type checks and
  `GC_MALLOC`/`memcpy`/manual-list-walking boilerplate.
- New example: `examples/libcream/` — a complete, minimal C host program
  registering its own native function (`host-greet`) and native value
  (`host-version`) as Scheme globals, then running a plain `.scm` script
  that calls/reads both; `host_greet` itself is 2 lines, using the new
  `creme_arg_cstr`/`creme_format_value` helpers above.
- See `icecreme/README.md`'s new "Embedding" section for the full minimal
  call sequence and the link-flag set a `libcreme.a` consumer needs to
  reproduce (static archives carry no transitive link flags).

### Breaking: standalone C VM (`cvm`) renamed to `icecreme` ("Ice Creme")

- Continuing the project's dessert-themed branding (the Crystal implementation
  is "Crystal Creme"), the standalone C11 VM backend is renamed from `cvm` to
  **`icecreme`** ("Ice Creme") throughout: the directory (`cvm/` →
  `icecreme/`), its built binary (`cvm/cvm` → `icecreme/icecreme`, sanitizer
  build `cvm-sanitize` → `icecreme-sanitize`), and the CLI flags on `bin/creme`
  that drive it (`--emit-cvm` → `--emit-icecreme`, `--cvm` → `--icecreme`).
- The compiled-bytecode file extension changes `.cvmc` → `.ice`, and its
  on-disk magic header changes `SCB1` → `ICE1` (a build artifact regenerated
  by `make`, not persisted user data, so no old-format compatibility is
  needed).
- The two documented, publicly-read environment variables rename to match:
  `CVM_STACK_CAP`/`CVM_FRAMES_CAP` → `ICECREME_STACK_CAP`/`ICECREME_FRAMES_CAP`
  (the internal-only default-value macros stay named
  `CVM_DEFAULT_STACK_CAP`/`CVM_DEFAULT_FRAMES_CAP`, since those were never a
  public interface).
- The runtime-visible backend name changes too: `(runtime)`'s `vm` field is
  now `"icecreme"` instead of `"cvm"` (tested via `(spec-vm)` in the spec
  suite's cvm-only skip logic).
- Files renamed to match: `doc/optimization-cvm.md` →
  `doc/optimization-icecreme.md`, `doc/deadend-cvm.md` →
  `doc/deadend-icecreme.md`, `spec/creme/examples_cvm_spec.scm` →
  `spec/creme/examples_icecreme_spec.scm`, `src/creme/compile/cvm_emitter.cr`
  → `src/creme/compile/icecreme_emitter.cr` (`CVMEmitter` → `IcecremeEmitter`).
- The internal C implementation's own `cvm_*`/`CVM_*` function/macro naming
  convention (~315 functions, ~62 macros — e.g. `cvm_alloc_vm` → `creme_alloc_vm`,
  `cvm_cons` → `creme_cons`, `CVM_COMPILER_DRIVER_PATH` → `CREME_COMPILER_DRIVER_PATH`,
  `CvmHashTable` → `CremeHashTable`) is also renamed to `creme_`/`CREME_`, for a
  single consistent internal prefix across the whole project rather than
  `icecreme_`/`ICECREME_` (reserved for the smaller set of genuinely
  user-facing names — the CLI flags, env vars, and extension above).

### Breaking: `Scheme` Crystal namespace renamed to `Creme`, shard renamed `scheme` → `creme`

- The Crystal-side module namespace (`Scheme::Interpreter`, `Scheme.run_source`,
  `Scheme::SchemeValue`, etc.) is renamed to `Creme` throughout, matching the
  project's actual brand/CLI/shard-target name (`creme`) instead of the
  language it interprets. The shard itself is renamed `scheme` → `creme` in
  `shard.yml` (`require "creme"` instead of `require "scheme"`), and
  `src/scheme.cr`/`src/scheme/` move to `src/creme.cr`/`src/creme/` to match
  (the `modules/scheme/` and `modules/creme/` subdirectories keep their
  existing names — those encode the *Scheme-language* library-naming
  convention, `(scheme base)` vs `(creme json)`, which is unrelated to the
  Crystal namespace).
- Every builtin-library module's `Scheme::Builtins::Xxx` namespace is now
  split by what it actually is: files implementing genuine R7RS
  standard-library procedures (`(scheme base)`, `(scheme char)`, ...) move to
  `Creme::R7RS::Xxx`; creme-only extensions (json/csv/mux/cipher/actor/...)
  become `Creme::Builtins::Xxx`. This is a pre-1.0 breaking change to the
  embedding API documented in this README's "As a Crystal library" section —
  anyone requiring `"scheme"` or referencing `Scheme::...` directly needs to
  update to `require "creme"` / `Creme::...`.

### New `(creme ...)` stdlib modules closing Ruby-stdlib gaps

- 14 new pure-R7RS, file-based `.sld` libraries, closing gaps identified
  by `doc/creme-vs-ruby-stdlib.md`'s comparison against Ruby's stdlib —
  each built entirely on existing creme primitives, no new Crystal/FFI
  code: `(creme set)` (a hash-set plus SortedSet), `(creme tsort)`
  (topological sort + Tarjan SCCs), `(creme prime)` (primality/
  factorization), `(creme abbrev)` (Ruby `Abbrev`), `(creme ostruct)`
  (dynamic-attribute records), `(creme pathname)` (pure string path
  parsing, complementing `(creme path)`'s builder direction), `(creme
  cgi)` (form-urlencoding, HTML-entity escaping, query-string parsing),
  `(creme uri)` (URI parsing/building/RFC 3986 §5.3 reference
  resolution), `(creme logger)` (Ruby `Logger`-style leveled logging),
  `(creme tempfile)`, `(creme pstore)` (a single-file persistent
  key-value store, S-expression serialized), `(creme matrix)` (dense
  linear algebra), `(creme xml)` (a minimal reader/writer parsing into
  exactly `(creme html)`'s own node shape), and `(creme escm)` (a minimal
  ERB-style template compiler for embedded Scheme, over `(scheme eval)`).
  `(creme uri)`, `(creme pstore)`, and `(creme escm)` are native `bin/creme` only —
  each depends on a builtin (regex trailing-group reporting, `read`'s
  port-optional default, and `(scheme eval)`'s `environment`,
  respectively) that behaves differently or is unavailable under
  `cvm/cvm` today; see each library's own header comment.

- Two more `doc/creme-vs-ruby-stdlib.md` gaps closed:
  - `(creme yaml)` (Ruby `YAML`/Psych): `yaml-read`/`yaml-write` for a
    single YAML document, mappings decoding to alists and sequences to
    vectors (the same convention `(creme json)` uses). Unlike the 14
    modules above, this one is a genuine dual-implementation module, not
    pure Scheme — native `bin/creme` backs it with Crystal's own bundled
    `YAML` stdlib module (`src/creme/modules/creme/yaml.cr`), and
    `cvm/cvm` links libyaml (MIT) directly (new `cvm/yaml.c`/`yaml.h`,
    `pkg-config yaml-0.1` wired into `cvm/Makefile` the same way
    PCRE2/GMP/OpenSSL/libffi already are) — both ends up backed by the
    same underlying C library either way. A plain (unquoted) scalar is
    resolved per YAML's core-schema conventions (bool words `yes`/`no`/
    `on`/`off`, `0x`/`0o`/leading-zero-octal/underscored integers,
    `.inf`/`.nan`) on both backends, verified to match byte-for-byte
    across all three run modes (native, `--self-hosted`, `cvm/cvm`) for
    every case exercised; one narrow, deliberate, documented divergence
    remains — a mapping key is always its literal scalar text on the
    `cvm` side, where native instead runs a key through the same typed
    resolution a value gets (see `cvm/yaml.c`'s own header comment).
    Building either backend now needs the system libyaml library
    (`apt install libyaml-dev` on Debian/Ubuntu; already present on
    macOS) — see `README.md`.
  - `(creme ipaddr)` (Ruby `IPAddr`): IPv4/IPv6 parsing (`make-ipaddr`,
    autodetecting family and an optional CIDR `/prefix`),
    `ipaddr->string` (RFC 5952 canonical form for ipv6), CIDR math
    (`ipaddr-network`/`-broadcast`/`-netmask`/`-hostmask`,
    `ipaddr-include?`), comparison (`ipaddr=?`/`-<?`), and
    `ipaddr-succ`/`-pred`. Pure R7RS, file-based, no new builtins on
    either backend — confirmed no bitwise operations exist anywhere in
    this codebase and none are needed, since a CIDR mask is always
    contiguous from the MSB, so `quotient`/`expt` on plain integers is
    enough. Internally represents an address as a list of per-group
    integers (4 groups of 0..255 for ipv4, 8 of 0..65535 for ipv6)
    rather than one combined integer — discovered mid-implementation
    that this interpreter's plain integers are fixnums that raise
    "integer overflow" rather than auto-promoting to a bignum past
    roughly 2^62 (`(expt 2 100)` already fails), too narrow to safely
    hold a full 128-bit IPv6 address as a single value; every group-wise
    arithmetic step here stays far inside fixnum range regardless of
    family.

### General-purpose crypto primitives, on both backends

- Three general-purpose primitives Ruby's `openssl` stdlib gem provides
  for free were missing entirely — closed as new builtins (not
  file-based `.sld` libraries, since new C/Crystal code was needed on
  both sides) identically on native `bin/creme` and `cvm/cvm`:
  - `(creme digest)` gains `digest-sha384`/`digest-sha512` and general
    `hmac-sha256`/`hmac-sha384`/`hmac-sha512` (hex digest strings). The
    new procedures (unlike the original three `digest-*`, left
    untouched) accept either a bytevector or a string for their
    arguments, since a key is often raw binary. Verified against the
    system `openssl` CLI and RFC 4231's HMAC-SHA256/384/512 test case 2
    on both backends.
  - New `(creme secure-random)`: `secure-random-bytes`/`-hex`/`-base64`,
    a CSPRNG kept deliberately separate from `(creme random)`'s plain,
    non-cryptographic PRNG — the same OS-entropy primitive `(creme
    actor)`'s handshake nonces and `(creme rfc8439)`'s random-key/nonce
    already use (`Random::Secure` natively, OpenSSL's `RAND_bytes` in
    `cvm`), newly exposed as general-purpose builtins.
  - New `(creme cipher)`: `aes-256-gcm-encrypt`/`-decrypt`/
    `-random-key`/`-random-nonce`, deliberately scoped to AES-256-GCM
    only (authenticated encryption, no raw CBC/ECB offered) — the same
    AEAD-first cut `(creme rfc8439)` already made for ChaCha20-Poly1305.
    Crystal's own `OpenSSL::Cipher` has no GCM/AEAD support at all in
    the Crystal version this project builds against (no way to feed it
    AAD or get/set an authentication tag — `EVP_CIPHER_CTX_ctrl` is
    never bound in its `OpenSSL::LibCrypto`), so
    `src/creme/modules/creme/cipher.cr` reopens that `lib` binding to
    add the one missing entry point and drives the raw EVP AEAD API
    directly; `cvm/cipher.c` drives the same API directly in C, where
    the full surface is simply part of `<openssl/evp.h>`. Verified
    against a published NIST/GCM test vector (256-bit all-zero key/IV,
    empty plaintext/aad) on both backends, plus explicit tamper-
    detection tests (a flipped ciphertext byte, tag byte, wrong key, or
    wrong aad must all raise `"authentication failed"` rather than ever
    returning corrupted plaintext or silently succeeding).
  - None of this needed a new system dependency on either backend — both
    already link libcrypto/libssl unconditionally (`cvm/actor.c`'s own
    HMAC-SHA256 handshake, `(creme digest)`'s `EVP_Digest`, `(creme
    http)`'s TLS client).

### Asymmetric crypto: `(creme pkey)` and `(creme x509)`, on both backends

- Closes the last major crypto gap vs Ruby's `openssl` stdlib gem: RSA/EC
  key generation, signing/verification, RSA encryption
  (`OpenSSL::PKey::RSA`/`EC`), and X.509 certificates/CSRs/chain
  verification (`OpenSSL::X509`) — previously nonexistent outside `(creme
  jose)`'s own narrow JWK wrapper, and there was zero X.509 support at
  all. Both new builtins-based modules (not file-based `.sld` libraries)
  implemented identically on native `bin/creme` and `cvm/cvm`.
  - New `(creme pkey)`: `rsa-generate-key [bits]`/`ec-generate-key
    [curve]` → a `<pkey>` handle; `pkey-public-key`/`-private?`/`-type`/
    `?`; `pkey-sign`/`-verify` (one shared procedure for both RSA and EC,
    mirroring Ruby's shared `PKey#sign`/`#verify` — RSA uses
    PKCS1v1.5-SHA256 matching Ruby's own default, EC uses ECDSA-SHA256);
    `rsa-encrypt`/`-decrypt` (RSA-OAEP-SHA256 only — deliberately not
    legacy PKCS1v1.5 encryption padding, the real padding-oracle-
    vulnerable case, unlike PKCS1v1.5 for signatures); `pkey->pem`/
    `pem->pkey` (auto-detecting RSA vs EC, private vs public). A `<pkey>`
    handle holds the key's own PEM text, never a live native key pointer
    — every operation reconstructs a transient one, uses it once, and
    frees it immediately, the same design `(creme jose)`'s own JWK
    already uses and for the same reason.
  - Discovered mid-implementation: Crystal's stdlib has NO
    `OpenSSL::PKey` class hierarchy at all (no `pkey.cr`/`pkey/rsa.cr`/
    `pkey/ec.cr` anywhere) — a bigger gap than `(creme cipher)`'s own
    finding that `OpenSSL::Cipher` exists but lacks GCM methods; here the
    whole class is simply absent. `src/creme/modules/creme/pkey.cr`
    reuses the vendored `jose.cr` shard's own reopened `LibCryptoJose`
    FFI bindings directly (`require "jose"`, already a project
    dependency) instead of re-declaring a parallel `lib LibCrypto` block
    from scratch — every EVP_PKEY/RSA/EC_KEY/PEM/BIO call is modeled
    directly on that shard's own JWK/JWS/JWE code, already proven correct
    against this OpenSSL build. `cvm/pkey.c` drives the same API directly
    in C, where it's simply part of `<openssl/evp.h>`/`<openssl/rsa.h>`/
    `<openssl/ec.h>`/`<openssl/pem.h>` — no FFI reopening needed there at
    all.
  - New `(creme x509)`: `x509-self-signed-certificate`/`-create-csr`
    (subject as a plain alist), `x509-sign-csr` (a CA signs a CSR into a
    real chainable cert), `x509-cert->pem`/`pem->x509-cert`,
    `x509-cert-subject`/`-issuer`/`-public-key`/`-not-before`/`-not-after`,
    and `x509-verify-chain` (builds a fresh `X509_STORE` per call, raises
    with OpenSSL's own verification-failure reason string on a broken/
    untrusted chain rather than just returning false). Every self-signed
    certificate gets a `basicConstraints CA:TRUE` extension
    (`X509V3_EXT_nconf_nid`) — discovered during development that
    `X509_verify_cert` rejects a trust-anchor cert lacking it
    ("invalid CA certificate") even without strict-mode verification
    flags set. `not-before`/`-after` convert `ASN1_TIME` to epoch seconds
    via a self-contained civil-calendar calculation (Howard Hinnant's
    `days_from_civil`/`civil_from_days` algorithm) on both backends,
    rather than `timegm(3)`, whose declaration and required feature-test
    macros vary across glibc/musl/BSD libc.
  - Neither Crystal's stdlib nor the vendored `jose.cr` shard bind any
    X.509 certificate-building or chain-verification surface (Crystal's
    own `openssl/x509/` subdirectory has certificate *parsing* only) —
    `src/creme/modules/creme/x509.cr` reopens Crystal's own `lib
    LibCrypto` binding for every `X509_`/`ASN1_` declaration this module
    needs beyond what's already there; `cvm/x509.c` drives the same
    X509/X509_REQ/X509_STORE API directly in C, where the full surface
    is simply part of `<openssl/x509.h>`/`<openssl/x509v3.h>` already.
  - Verified beyond self-consistency: every RSA/EC signature cross-
    checked against the system `openssl dgst -sign`/`-verify` CLI in
    both directions (creme signs → openssl verifies, and vice versa);
    every self-signed CA / CSR-signed leaf certificate chain cross-
    checked against `openssl verify -CAfile`, on both backends.
  - Fixed a real latent bug this work's own growth exposed:
    `cvm/main.c`'s `registered_family_mask`/`CVM_EXTRA_BIT_*` builtin-
    family bookkeeping used a plain 32-bit `int`, and shifting a bit
    position past 31 (once the family count plus its 3 reserved extra
    bits crossed that line — exactly what adding `(creme pkey)`/`(creme
    x509)` on top of this session's other new families did) is undefined
    behavior in C; a real regression surfaced in
    `spec/creme/examples_cvm_spec.scm` once that threshold was crossed.
    Fixed by widening the field to `uint64_t` and the shift constants to
    match (`cvm/vm.h`, `cvm/main.c`).
  - None of this needed a new system dependency on either backend — both
    already link libcrypto/libssl unconditionally.

### Security / robustness (cvm)

- `builtins.c`: every unchecked `malloc`/`realloc` call site now
  null-checks (`xmalloc`/`xrealloc`), aborting cleanly instead of
  risking a null-pointer dereference on allocation failure.
- New `make -C cvm sanitize` target (ASAN+UBSAN diagnostic build).
  Found and fixed a real bug: a nested `guard` whose inner clause
  doesn't match and re-raises to an outer guard could resume with a
  corrupted condition value, because identifying "which handler is
  resuming" relied on a stack local silently clobbered by a later
  nested handler's own install sharing the same C stack frame — fixed
  by threading that identity through a VM struct field instead.
- `loader.c` (the SCB1 bytecode deserializer): every length/count field
  is now bounds-checked before driving an allocation, with recursion-
  depth guards on nested datums and nested chunks to block a stack-
  overflow DoS from a crafted file.
- New `make -C cvm fuzz` libFuzzer harness targeting the SCB1 loader —
  the concrete untrusted-input boundary for an embedder. Found and
  fixed: an oversized-but-"plausible" count still permitting a ~512MB
  single allocation; a type-confusion crash where `resolve_globals`
  trusted an instruction operand as a valid symbol/string const without
  checking bounds or type; a GMP division-by-zero on a malformed
  rational constant's zero denominator.
- Boehm GC's out-of-memory callback now routes through the existing
  `cvm_abort` machinery, so an allocation failure becomes a clean,
  catchable Scheme condition instead of an unchecked crash.

### Error-handling completeness (cvm)

- `cxr`/`abs`/`zero?`/`positive?`/`negative?`'s fused/quickened call
  sites now deopt to the real builtin on a fast-path miss (mirroring
  the native Crystal VM's own `unary_prim_deopt`) instead of hard-
  aborting with an internal "deopt not implemented" message.
- The register stack and call-frame array are no longer fixed-size
  members baked into the VM struct's own layout — `cvm_alloc_vm`
  builds every VM (including a spawned actor's, inheriting its
  parent's own limits) with a configurable cap, overridable today via
  `CVM_STACK_CAP`/`CVM_FRAMES_CAP` environment variables.

## [v0.1.0] — first tagged release

Marks the starting point for this changelog and for real git tags
going forward — not a specific milestone beyond "the project's shape
as of this point." See `git log` for the full history up to this tag.
