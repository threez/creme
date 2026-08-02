# cvm stability policy

This project (both `cvm` and the native `creme` interpreter it shares a
bytecode format with) is pre-1.0 (`shard.yml`'s `version:`, currently
`0.1.0`) and still under active development. This document says what you
can currently rely on staying stable across a patch/minor release versus
what's explicitly still in flux — so an embedder (or anyone holding a
precompiled `.cvmc`) knows what needs re-checking after an upgrade and
what doesn't.

Versions follow `shard.yml`'s own `version:` field, synced into
`src/creme.cr`'s `VERSION` constant via `make version`, tagged via
`make tag`. See `CHANGELOG.md` for what changed at each tag.

## Stable (won't break without a version bump and a CHANGELOG.md entry)

- **The SCB1 bytecode format's read compatibility, gated by an explicit
  version check.** Every `.cvmc` file (and every `load-chunk-bytes`
  blob) carries a format-version byte immediately after the `"SCB1"`
  magic (`ChunkSerializer::FORMAT_VERSION` in
  `src/creme/compile/chunk_serializer.cr`, mirrored by
  `modules/creme/bytecode.sld`'s own writer). `cvm/loader.c`'s
  `check_magic_and_version` and `chunk_deserializer.cr`'s own read both
  reject a mismatched version with a clean, actionable error instead of
  silently misinterpreting bytes they weren't written for. **This
  version number only changes when the on-disk layout itself changes in
  a way an older reader couldn't safely parse** — bumping it is a
  deliberate act (update all three: the two writers above and this
  policy's own expectations), not something that happens as a side
  effect of ordinary feature work. A `.cvmc` compiled at one point
  version (`0.1.x` → `0.1.y`) is expected to keep loading; a bump to
  the format version itself is called out explicitly in `CHANGELOG.md`.
- **The base builtin procedure set** — R7RS `(scheme base)` and the
  other standard libraries `cvm/README.md`'s "Compatibility with creme"
  section documents as supported. A name that exists today won't be
  removed or have its arity/basic contract changed without a
  `CHANGELOG.md` entry calling it out; genuinely new procedures get
  added over time (also noted there).
- **The `cvm` CLI's own invocation contract**: `cvm <file.cvmc-or-.scm>
  [script-args...]`, the `--profile` flag, and the `CVM_STACK_CAP`/
  `CVM_FRAMES_CAP` environment-variable resource-limit overrides (see
  `cvm_alloc_vm`'s own doc comment in `vm.h`).

## Explicitly UNSTABLE (may change in any release, including a patch)

- **Everything in `vm.h`/`value.h`/`opcodes.h` not listed above** —
  `Value`/`Frame`/`VM`/`Chunk`'s own C struct layout, field order,
  padding, and every internal function signature. There is no stable C
  ABI yet: linking against cvm's internals means recompiling against
  the exact source you're linking, not a versioned header contract.
  (A real, narrower public embedding header is a planned, not yet
  built, piece of future work — see the project's own roadmap notes;
  once it exists, whatever it exposes moves into the "stable" list
  above and everything else stays here.)
- **The self-hosted compiler's own internal IR/representation**
  (`modules/creme/compiler/compiler.sld`) — only its OUTPUT (an SCB1
  chunk) is covered by the format-version guarantee above; the
  compiler's own internal data shapes are free to change at any time.
- **`cvm --profile`'s report format** (column layout, exact wording) —
  a diagnostic tool's output, not a machine-readable contract anything
  should parse.
- **`(creme actor)`'s wire protocol** (the TCP/Unix transport's own
  framing/handshake, `actor.c`) — presently undocumented/unversioned;
  treat cross-version actor clusters (an old cvm build talking to a
  new one) as unsupported until this gets its own explicit version
  marker.
- Anything this document doesn't mention. When in doubt, ask, or treat
  it as unstable.
