# creme vs. Ruby's standard library

A category-by-category comparison of what `(creme ...)`/`(scheme ...)` covers
against what ships in Ruby's stdlib (the bundled libraries under `ruby/lib`,
not third-party gems). Scope: this project's own modules
(`modules/creme/*.sld`, `modules/scheme/*.sld`, `modules/dialect/ruby.sld`),
compared feature-for-feature against Ruby 3.x's default/bundled gems.

Verdict up front: creme's overlap with Ruby stdlib is real but narrower than
it looks (JSON/CSV/digest/base64/regex/time/random/SQLite are all there,
named differently), and its non-overlap is dominated by two things Ruby's
stdlib doesn't attempt at all — compiler/VM tooling (its own bytecode format,
an LR parser generator, a PEG library, a Scheme lexer) and a Raft consensus
engine — plus a cluster of macro-folded "build a string at compile time"
libraries (`css`, `html`, `path`, `json-builder`) that have no Ruby analog
because Ruby has no compile-time macro system to fold them with.

**Update:** 14 of the gaps originally listed in §2 below (Set, TSort, URI,
CGI, Prime, Abbrev, OpenStruct, Pathname, Logger, Tempfile, PStore, Matrix,
XML, ERB) have since been closed as pure-R7RS `(creme ...)` modules — see
`CHANGELOG.md`'s "New `(creme ...)` stdlib modules closing Ruby-stdlib gaps"
entry. They've moved down into §1. Three of them (`(creme uri)`, `(creme
pstore)`, `(creme escm)`) are native `bin/creme` only for now — each leans on
a builtin that behaves differently or is unavailable under `icecreme/icecreme` today
(regex trailing-group reporting, `read`'s port-optional default, and
`(scheme eval)`'s `environment`, respectively); see each library's own
header comment.

**Update 2:** two more gaps have since closed: `YAML` (`(creme yaml)`,
backed by libyaml on both backends — Crystal's own bundled `YAML` stdlib
module natively, `icecreme/icecreme` linking libyaml directly) and `IPAddr`
(`(creme ipaddr)`, pure R7RS, no new builtins on either backend — see
that library's own header comment for why it stores an address as a list
of per-group integers rather than one combined integer). Both have moved
into §1; `Resolv` (actual DNS resolution) remains in §2, now on its own.

**Update 3:** three general-purpose crypto primitives Ruby's `openssl`
stdlib gem provides for free have since closed too: `OpenSSL::HMAC`
(`hmac-sha256`/`-sha384`/`-sha512`, folded into `(creme digest)`
alongside newly-added `digest-sha384`/`-sha512`), `OpenSSL::Cipher`
(`(creme cipher)`, deliberately scoped to AES-256-GCM only — no raw
CBC/ECB), and `SecureRandom` (`(creme secure-random)`, a CSPRNG kept
apart from `(creme random)`'s plain PRNG the same way Ruby keeps the two
modules separate). All three are implemented identically on both native
`bin/creme` and `icecreme/icecreme` (`icecreme/digest.c`'s `HMAC()` addition,
`icecreme/secure_random.c`, `icecreme/cipher.c` — all reusing the libcrypto/libssl
link already in place, no new dependency on either backend). Remaining
real gaps: RMD160 (`(creme digest)`), and general symmetric-cipher modes
beyond GCM (raw CBC/ECB, deliberately not offered).

**Update 4:** asymmetric crypto, previously a pure gap outside `(creme
jose)`'s own narrow JWK wrapper, has closed too: `OpenSSL::PKey::RSA`/
`EC` (`(creme pkey)`: key generation, PEM import/export, sign/verify,
RSA-OAEP encryption) and `OpenSSL::X509` (`(creme x509)`: self-signed
certificates, CSRs, CA-signing, chain verification). Crystal's stdlib
has NO `OpenSSL::PKey` class hierarchy at all (a bigger gap than the
`OpenSSL::Cipher` finding above — there the class existed but lacked
GCM methods; here the whole class is simply absent) and its
`openssl/x509/` subdirectory only has certificate *parsing*, no builder
or chain-verification (`X509_STORE`) support — both closed the same way
this project already closes such gaps: reopening Crystal's own `lib
LibCrypto` binding (`(creme pkey)` also reuses the vendored `jose.cr`
shard's own `LibCryptoJose` FFI declarations directly, already proven
correct by that shard's own JWK/JWS code, rather than re-declaring them).
Both modules are implemented identically on native `bin/creme` and
`icecreme/icecreme` (`icecreme/pkey.c`/`icecreme/x509.c`, where the full API is simply part
of OpenSSL's own C headers — no FFI reopening needed there at all).
Deliberate cuts: RSA encryption is OAEP-only (no legacy PKCS1v1.5
encryption padding); no DSA; Ed25519 remains JOSE-only (`(creme jose)`'s
own OKP key type), not exposed through `(creme pkey)`; X.509 has no CRL
(certificate revocation list) support.

## 1. Has a clear Ruby-stdlib counterpart (same job, different name/shape)

| Ruby stdlib | creme equivalent | Notes |
|---|---|---|
| `JSON` | `(creme json)` | Ruby: objects → Hash. creme: objects → alist, arrays → vector (not list) — a deliberate convention shared with `(creme csv)`/`(creme jose)`. |
| `CSV` | `(creme csv)` | Both bulk and streaming (`csv-reader-open`/`csv-writer-open` vs Ruby's `CSV.open`); creme's is backed by Crystal's stdlib CSV parser. |
| `Digest::MD5`/`SHA1`/`SHA256`/`SHA384`/`SHA512` | `(creme digest)` | Ruby's `Digest` family also has RMD160; that's the only remaining gap now that SHA384/512 have closed. |
| `Base64` | `(creme digest)`'s `base64-encode`/`base64-decode` | Folded into digest rather than its own library. |
| `OpenSSL::HMAC` | `(creme digest)`'s `hmac-sha256`/`-sha384`/`-sha512` | Hex digest strings, folded into the same `(creme digest)` module rather than a separate one, matching how `Base64` above already folds in too. |
| `OpenSSL::Cipher` | `(creme cipher)` | Scoped to AES-256-GCM only (authenticated encryption) — no raw CBC/ECB/etc.; Ruby's `OpenSSL::Cipher` accepts any cipher name string OpenSSL itself supports. A genuine dual-implementation module on both backends, not a pure-Scheme one: native drives OpenSSL's raw EVP AEAD API directly (its own `OpenSSL::Cipher` wrapper has no GCM/AEAD support at all in this Crystal version), `icecreme` drives the same EVP API directly in C. |
| `SecureRandom` | `(creme secure-random)` | Kept as its own module, distinct from `(creme random)`'s plain PRNG, the same way Ruby keeps `SecureRandom` apart from `Random`; `secure-random-bytes`/`-hex`/`-base64` match `SecureRandom.random_bytes`/`.hex`/`.base64` closely. |
| `OpenSSL::PKey::RSA`/`EC` | `(creme pkey)` | Key generation, PEM import/export, `pkey-sign`/`-verify` (one shared name for both algorithms, like Ruby's shared `PKey#sign`/`#verify`), `rsa-encrypt`/`-decrypt` (RSA-OAEP-SHA256 only — no legacy PKCS1v1.5 encryption padding). No DSA; Ed25519 stays JOSE-only (`(creme jose)`'s own OKP key type), not exposed here. |
| `OpenSSL::X509` | `(creme x509)` | Self-signed certificates, CSRs, CA-signing, chain verification (`x509-verify-chain`, an `X509_STORE`-backed check that raises with OpenSSL's own failure reason on a broken/untrusted chain). No CRL (certificate revocation list) support. |
| `Regexp` (core, but stdlib-adjacent via `Regexp` methods) | `(creme regex)` | SRFI-115 naming (`regexp-search`/`regexp-replace-all`) rather than Ruby's `=~`/`match`/`gsub` operator style. |
| `Time`/`Date` | `(creme time)` (rich) + `(scheme time)` (R7RS-minimal) | `(creme time)` covers what `Time` does (arithmetic, formatting, component accessors); no `Date`-only (calendar-without-time) type. |
| `Random` | `(creme random)` | SRFI-27 naming (`random-real`/`random-integer`/`random-seed!`) instead of `Random.rand`/`Random.new(seed)`. |
| `BigDecimal` | `(creme bigdecimal)` | Same job: arbitrary-precision decimal, avoiding float rounding for money-shaped math. |
| `Complex` | `(scheme complex)` | Core-language numeric tower in creme vs. a stdlib require in Ruby — creme's is arguably more "built in." |
| `Rational` | Native `SchemeRational` (auto-reducing, no import needed) | Same story — core numeric tower, not a bolt-on library. |
| `sqlite3` gem (not stdlib, but the closest Ruby has without a gem) | `(creme sql)` | Ruby stdlib has **no** bundled database library at all; `sqlite3`/`pg`/etc. are all gems. This is actually a creme-has/Ruby-stdlib-doesn't case, listed here only because it's the single closest analog. |
| `OptionParser` | `(creme cli)` | Declarative flag parsing with auto `-h`/`--help` in both. |
| `Net::HTTP` | `(creme http)` | HTTP(S) client in both; creme's is thinner (no cookie jar, no streaming multipart). |
| `FileUtils`/`File`/`Dir` (subset) | `(creme file)` | Whole-file convenience (`file-read`/`file-write`/`file-lines`) plus R7RS port-based I/O; no recursive `cp_r`/`mkdir_p`/glob equivalent. |
| `Open3`/`Process.spawn` | `(creme process)`/`(creme shell)` | External command execution; `(creme shell)` adds bench-script ergonomics Ruby would get from `Open3.capture3` + hand-rolled helpers. |
| `Benchmark` | `(creme bench)` | Timing a thunk + report formatting in both. |
| `StringScanner` | `(creme scanner)` | Both are character-port/position-tracking scanning primitives for hand-written parsers; creme's is purpose-built for `#lang` dialect front-ends. |
| `Racc` (parser generator, bundled default gem) | `(creme lr)` | Both are from-scratch LALR/SLR table-driven parser generators; creme's raises on any conflict instead of resolving via declared precedence. |
| `Struct`/`Data.define` | `define-record-type` (R7RS core, not a creme addition) | Same job (named product types with accessors), different mechanism (special form vs. class factory). |
| `Enumerable` (`map`/`select`/`reduce`/`each_with_index`/...) | `(creme extra)` (SRFI-1) + `(dialect ruby)` | `(dialect ruby)` exists specifically to give these Ruby-shaped names/call order over the SRFI-1 base. |
| `String` methods (`upcase`/`strip`/`split`/`gsub`/...) | `(creme string)` + `(dialect ruby)` | Same coverage; `(dialect ruby)` renames to match Ruby exactly (`gsub`, `strip`, `start_with?`). |
| Pattern matching (`case`/`in`, language feature since 2.7) | `(creme match)` | creme's is a library (record-shape matching only), Ruby's is a language feature with full deconstruction. |
| `Set`/`SortedSet` | `(creme set)` | A mutable hash-set over `(creme hash-table)`, plus a `SortedSet` variant (`sorted-set->list` always ascending, via `(creme sort)`). |
| `TSort` | `(creme tsort)` | `tsort` (dependencies-first, raises on a cycle), `tsort-strongly-connected-components` (Tarjan's algorithm — a cycle collapses into one component instead of raising). |
| `Prime` | `(creme prime)` | `prime?`/`prime-factors`/`primes-upto`/`next-prime` — plain trial division, not Miller-Rabin, so fine for ordinary integers, not cryptographic-scale ones. |
| `Abbrev` | `(creme abbrev)` | `abbrev`/`abbrev-resolve`, matching `abbrev.rb`'s exact unique-prefix algorithm (minus its optional regexp pre-filter argument). |
| `OpenStruct` | `(creme ostruct)` | A hash-table-backed dynamic-attribute record; field access is always an explicit procedure call (`ostruct-ref`/`ostruct-set!`), since Scheme has no `method_missing` to dispatch dot syntax through. |
| `Pathname` | `(creme pathname)` | Pure string path *parsing* — `pathname-dirname`/`-basename`/`-extname`/`-split`/`-join`/`-cleanpath`/`-parent`; complements `(creme path)`'s builder direction; no filesystem access at all (purely lexical, like `#cleanpath` not `#realpath`). |
| `CGI` (escaping, query-string parsing) | `(creme cgi)` | `cgi-escape`/`cgi-unescape` (form-urlencoding), `cgi-escape-html`/`cgi-unescape-html`, `cgi-parse` (grouping repeated keys, matching `CGI.parse` exactly). |
| `URI` (parsing, building, reference resolution) | `(creme uri)` | `uri-parse`/`uri->string`, `uri-encode-www-form`/`-decode-www-form`, `uri-join` (full RFC 3986 §5.3 resolution) — native `bin/creme` only for now (see the library's own header comment). |
| `Logger` | `(creme logger)` | Five severity levels, `logger-debug!` through `logger-fatal!`, a configurable formatter — no ANSI coloring by default (a logger's output often ends up in a redirected file). |
| `Tempfile` | `(creme tempfile)` | `make-tempfile`, `call-with-tempfile` (guarantees close+unlink via `dynamic-wind`, even if its block raises). |
| `PStore`/`DBM`/`GDBM` | `(creme pstore)` | A single-file key-value store, backed by this project's own `write`/`read` round-tripping a whole alist verbatim — no file locking (same caveat Ruby's own PStore gives) — native `bin/creme` only for now. |
| `Matrix`/`Vector` (bundled gem) | `(creme matrix)` | Dense-matrix linear algebra: add/sub/scale/multiply/transpose/trace/determinant (recursive cofactor expansion, so `O(n!)` — fine for small matrices). |
| `REXML`/`Nokogiri`-adjacent XML | `(creme xml)` | A minimal well-formed-XML reader/writer, parsing into exactly `(creme html)`'s own node shape; no DTD/namespace/CDATA support. |
| `ERB`/template engines | `(creme escm)` | `<% %>`/`<%= %>` over literal text, compiled once via `escm-compile` and rendered per locals-alist via `(scheme eval)` — native `bin/creme` only for now. |
| `YAML` (Psych) | `(creme yaml)` | Both backends backed by libyaml either way (native via Crystal's own bundled `YAML` stdlib module, `icecreme/icecreme` linking libyaml directly) — a genuine dual-implementation module, unlike the 14 pure-Scheme ones above; `yaml-read`/`yaml-write` follow the same alist/vector convention as `(creme json)`. |
| `IPAddr` | `(creme ipaddr)` | Pure R7RS, no new builtins on either backend — CIDR masks are always MSB-contiguous, so network math is plain `quotient`/`expt` on per-group integers rather than needing bitwise ops (creme has none); stores an address as a list of per-group integers instead of one combined integer, since this interpreter's plain integers don't auto-promote to a bignum past ~2^62, too narrow for a full 128-bit IPv6 address. |

## 2. Ruby stdlib has it, creme doesn't

| Ruby stdlib | Gap |
|---|---|
| `Observable`/`Forwardable`/`SimpleDelegator`/`Singleton` | No OO mixin-pattern helpers (unsurprising — creme has no classes to mix into). |
| `Thread`/`Mutex`/`ConditionVariable`/`Fiber`/`Ractor` | No shared-memory concurrency primitives at all — `(creme actor)` is message-passing only (see §3), a different concurrency model entirely, not a thin API gap. |
| `Socket`/`IPSocket`/`UNIXSocket` (raw sockets) | No raw socket library exposed to scripts — `(creme mux)`/`(creme http)` cover HTTP server/client only; `(creme actor)`'s `start-node 'tcp`/`'unix` covers actor transport only, not general sockets. |
| `Resolv` | No DNS resolution (a real gap — `(creme ipaddr)` covers `IPAddr`'s own half of this pairing, address parsing/CIDR math, but doing anything with a hostname still needs actual name resolution, which needs a socket). |
| `Marshal`/`Ripper` | No Ruby-source-parses-itself introspection (creme's nearest thing, `(creme scheme-lexer)`, tokenizes *Scheme* source for its own REPL highlighting, not a general reflection API) — object serialization itself is now covered, since `write`/`read` already round-trip any Scheme datum verbatim (as `(creme pstore)` relies on directly). |
| `WeakRef`/`ObjectSpace`/`GC` introspection | No exposed GC/object-graph introspection. |
| `English` (`$INPUT_RECORD_SEPARATOR` etc.) | N/A — no global magic-variable convention to alias. |

## 3. creme has it, Ruby stdlib doesn't (and mostly no gem covers it either)

| creme module | What it does | Closest Ruby equivalent |
|---|---|---|
| `(creme raft)`/`(creme raft-scheme)`/`(creme raft-machine)` | Full Raft consensus (leader election, log replication, snapshotting, membership changes), two independent implementations (FFI-backed and pure-Scheme) | None in stdlib; would mean reaching for a gem like `raft-rb` (unmaintained) or rolling your own |
| `(creme actor)`/`(creme actor-supervisor)` | Message-passing actors with OTP-style supervised restart-on-crash | None — Ruby's concurrency stdlib (`Thread`/`Fiber`/`Ractor`) is shared-memory/message-queue at a much lower level; nothing OTP-shaped ships by default |
| `(creme bytecode)` | Assembler + serializer (ICE format) for this project's own register-VM bytecode | N/A — Ruby doesn't expose its own YARV bytecode format for scripts to assemble |
| `(creme ir)` | Generic S-expression code-generation building blocks (used by the self-hosted compiler) | No direct analog — closest is metaprogramming via `Kernel#eval`/`instance_eval`, a different mechanism entirely |
| `(creme lr)` | SLR(1) parser-table generator exposed as a library, including conflict inspection (`debug-states`) | `Racc` is a *code generator* (compiles a `.y` grammar to a `.rb` file offline); `(creme lr)` is a runtime library callable directly from a script |
| `(creme peg)` | PEG-style parser combinators | Not in stdlib; closest gems are `parslet`/`treetop`, both third-party |
| `(creme scheme-lexer)`/`(creme highlight)` | Real tokenizer for Scheme source + ANSI syntax highlighting/paren-balance checking for a REPL input line | Nothing bundled — Ruby's own `irb` uses `Reline`, which isn't exposed as a general lexer |
| `(creme css)` | Data-driven CSS builder with Sass-style nesting, `css!`/`css-write!` macro-folding a static stylesheet to a string literal at macro-expansion time (zero runtime cost) | No stdlib CSS builder; the macro-time folding trick has no Ruby analog since Ruby has no `syntax-rules`/`defmacro`-style compile-time expansion |
| `(creme html)` | Hiccup-style HTML builder (S-expressions as markup) with the same macro-folding trick (`html!`) | `ERB` is a *text*-template engine (interpolate code into a string), not an S-expression builder; ERB also can't const-fold at compile time the way `html!` does |
| `(creme json-builder)` | Macro-folded JSON template builder | No equivalent — same "fold the static parts at macro-expansion time" trick as `css!`/`html!` |
| `(creme path)` | Macro-folded URL/file path *builder* | No direct analog; closest is manual string interpolation or `File.join`, neither const-folded |
| `(creme sxql)` | SQL statement builder DSL (ported from Common Lisp's sxql), pairs with `(creme sql)` | `Sequel`/`ActiveRecord::QueryMethods` do this but are gems, not stdlib |
| `(creme dao)` | Mini Scheme-native DAO layer over `(creme sxql)` | `ActiveRecord`/`Sequel::Model` — again, gems, not stdlib |
| `(creme for)` | Racket-`for`-family iteration/comprehension macros (`for/sum`, `for/fold`, `for*`, ...) | Ruby has no comprehension macro system; closest is chained `Enumerable` calls, which can't express e.g. `for/fold`'s multi-accumulator form as compactly |
| `(creme pipe)` | Elixir-style `|>` pipeline threading | Ruby 2.7+ has `Object#then`/`#yield_self` for single-step chaining, but no multi-step pipeline macro with implicit-first-argument threading |
| `(creme memoize)` | Function memoization including a self-bounding LRU variant (`memoize-lru`) | No stdlib memoization at all — hand-rolled `@cache ||= {}` is the idiom, no LRU eviction helper |
| `(creme treelist)` | Immutable RRB-tree sequences, O(log n) `ref`/`set`/`insert`/`delete`, plus a mutable variant | Ruby's `Array` is a plain mutable array — no immutable persistent-sequence type ships anywhere in stdlib |
| `(creme table)` | Bordered/borderless text-table rendering with pluggable styles | No stdlib text-table formatter (gems like `terminal-table` fill this gap) |
| `(creme tui)` | Terminal UI primitives | `curses`/`Curses` was removed from stdlib in Ruby 3.3; now a gem |
| `(creme wrk)` | Runs `wrk` (HTTP benchmarking tool) and parses its output | No stdlib benchmarking-tool wrapper |
| `(creme mux)`/`(creme surf)` | HTTP router + Sinatra-style declarative layer on top | `Rack`/`Sinatra` — gems, not stdlib; Ruby stdlib has no HTTP server framework at all (`WEBrick` was removed from stdlib default gems in 3.0) |
| `(creme jose)` | Full JOSE suite — JWK/JWS/JWT/JWE/JWKS | No stdlib JWT/JOSE support; needs the `jwt`/`jose` gems |
| `(creme rfc8439)` | ChaCha20/Poly1305 AEAD encryption | Ruby's crypto story is entirely via the `openssl` stdlib wrapper around OpenSSL, not a from-scratch RFC 8439 implementation |
| `(creme ffi)`/`(creme foreign)` | Generic `dlopen`/libffi bridge + declarative sugar (structs, records over opaque pointers) | Ruby *does* have `fiddle` (bundled) for exactly this — the fairest one-to-one match in this whole table, so treat this row as the exception that's arguably §1, not §3 |
| `(creme numfmt)` | Fixed-decimal and ratio number formatting | Ruby's `Kernel#format`/`%` covers basic cases; no dedicated ratio-aware formatter |
| `(creme spec)`/`(creme spec-runner)` | RSpec-*like* test framework written in Scheme itself, for testing the self-hosted compiler | `RSpec` isn't stdlib either (it's a gem) — but Ruby stdlib does bundle `Test::Unit`/`minitest`, so this is really creme-has-nothing-bundled vs Ruby-has-something-bundled, inverted from the rest of this table |
| `(creme cli)`'s sibling `#lang` machinery (`(creme syntax ruby)`, `(creme syntax scss)`, `(creme syntax slim)`) | Whole alternate concrete syntaxes compiling down to Scheme | No Ruby equivalent — Ruby's parser isn't user-extensible; nothing like a pluggable `#lang` reader exists |

## Summary

- **Direct overlap (§1):** ~39 modules/features line up closely enough to call
  them the same job under a different name — JSON, CSV, digest/base64, regex,
  time, random, bigdecimal, the numeric tower, CLI parsing, HTTP client, file
  I/O, process spawning, benchmarking, string scanning, parser generation,
  records, Enumerable/String coverage (the last two largely *because*
  `(dialect ruby)` exists to bridge the naming gap on purpose), Set, TSort,
  Prime, Abbrev, OpenStruct, Pathname, CGI, URI, Logger, Tempfile, PStore,
  Matrix, XML, and ERB (all closed as pure-R7RS `(creme ...)` modules with no
  new Crystal/FFI code), YAML (`(creme yaml)`, a real dual-implementation
  module, libyaml either way) and IPAddr (`(creme ipaddr)`, pure R7RS again,
  no new builtins), and — most recently — five general-purpose crypto
  primitives that were pure gaps until now: `OpenSSL::HMAC` (folded into
  `(creme digest)`, alongside newly-added SHA384/512), `OpenSSL::Cipher`
  (`(creme cipher)`, scoped to AES-256-GCM only), `SecureRandom`
  (`(creme secure-random)`, a CSPRNG kept apart from `(creme random)`'s
  plain PRNG), and `OpenSSL::PKey::RSA`/`EC` + `OpenSSL::X509`
  (`(creme pkey)`/`(creme x509)`: key generation/sign/verify/encryption,
  certificates/CSRs/chain verification) — all five implemented identically
  on both native `bin/creme` and `icecreme/icecreme`, unlike `(creme rfc8439)`/
  `(creme jose)` below, which remain native-only.
- **Ruby-only (§2):** now just `Resolv` (DNS resolution, needs a real socket)
  plus things that are structural to Ruby-the-OO-language and have no
  meaning in creme (Observable/Forwardable/Singleton mixins) or that need
  real OS-level support this project hasn't built yet (Thread/Fiber/Ractor's
  shared-memory concurrency model, raw sockets, GC/object-graph
  introspection).
- **creme-only (§3):** dominated by two clusters — (a) the self-hosting
  compiler's own tooling (bytecode assembler, IR, LR/PEG parsing, a real
  Scheme lexer) which exists because creme *implements itself*, not because
  general scripts need it, and (b) genuinely novel-for-a-scripting-stdlib
  distributed-systems/macro tooling (Raft, OTP-style supervised actors,
  macro-folded builders for CSS/HTML/JSON/paths that Ruby's macro-free
  language design can't replicate).
