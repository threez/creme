# Improvement areas — JIT-adjacent techniques for icecreme/creme

Notes from surveying a bytecode-VM JIT writeup
(https://yoichiozaki.github.io/en/blog/bytecode-vm) against icecreme's actual
architecture (`icecreme/vm.c`: computed-goto dispatch, Boehm conservative GC,
ahead-of-time self-hosted compiler in `modules/creme/compiler/`). Not all
of that article's techniques are a good fit here — this doc separates
what's worth pursuing from what isn't, roughly in priority order.

---

## Worth pursuing

### 1. ~~Inline caching for global lookups~~ — correction: already a non-issue

**This entry was wrong and is kept only as a correction note.** It
assumed icecreme resolves a global-variable reference the way, say, a
Python module dict or a JS global object does — a real lookup on every
access. It doesn't: `loader.c`'s `resolve_globals` interns every
`GetGlobal`/`SetGlobal`/`DefGlobal`/`CallGlobal` reference to a fixed
array slot index once, at load time (see `creme_global_intern`). At
runtime it's already just `vm->globals[ins->b]` — a direct array index
plus a `bound` flag check, with no name comparison or hashtable
involved. There's nothing here for an inline cache to speed up; this
item doesn't belong in "worth pursuing" and item 2 replaces it below.

Record/struct field access was reassessed the same way and turned out
to be a real target — **implemented**, see item 2's own entry below.
(The `record-type->define-forms`/tagged-vector shape mentioned above
is a narrower, non-top-level legacy path; top-level `define-record-
type` — the shape real programs use — desugars differently, to a
`RecordCallable`/`SchemeRecord` pair, which is what actually got
quickened.)

### 2. Call-site quickening for primitive calls — **implemented**

The genuine analog of "inline caching" for icecreme turned out to be at
`OP_CALLGLOBAL` call sites, not at global-slot storage itself. icecreme's
self-hosted bootstrap compiler (`modules/creme/compiler/compiler.sld`)
*does* fuse `+`/`-`/`*`/`car`/`cdr`/`cons`/etc. into dedicated opcodes
at compile time when it can prove the call site is safe to fuse — but
that proof is purely static: the moment the compiler sees ANY
`(define ...)`/`(set! ...)` of one of these names anywhere earlier in
the same compile (`mark-redefined!`, tracked in
`redefined-fusable-globals`), it permanently disables fusion for that
name for the rest of that compilation unit, even if the redefinition
is later undone or never actually runs. Every call to that primitive
from then on compiles as an ordinary `OP_CALLGLOBAL` to a real
n-ary builtin (`builtins.c`'s `bi_plus`/`bi_minus`/`bi_star`/`bi_car`/
`bi_cdr`/`bi_cons`), paying full call-dispatch overhead forever, even
in code that never touches the redefinition at runtime.

Implemented as runtime call-site quickening: the first time a still-
generic `OP_CALLGLOBAL` site's target resolves to one of these
builtins with a matching argument count, the instruction is rewritten
in place to a new `OP_QCALLGLOBAL_*` opcode (`icecreme/opcodes.h`, appended
after `OP_COUNT` — runtime-only, never serialized) that re-checks the
global's *current* value against the exact expected builtin pointer on
every execution and permanently deopts back to plain `OP_CALLGLOBAL`
the instant that check fails (a genuine redefinition). See
`doc/internals/optimization-icecreme.md`'s "Call-site quickening" section for the
implementation and measured effect.

icecreme already had a *compile-time-only* version of this general idea in
two other places — the integer fast-path wrappers inlined into
arithmetic/comparison opcodes (`doc/internals/optimization-icecreme.md`, Section 3)
and the counted-loop fusion opcodes (OP_FORLOOP*,
OP_FORLOOPGUARDEDINC/DEC, `doc/internals/optimization-general.md`) — this is the
first place icecreme makes that kind of specialization decision at runtime
instead of purely ahead of time.

### 3. Call-site quickening for record accessors — **implemented**

The follow-on this item's own correction note (item 1 above) flagged:
top-level `define-record-type` field accessors are exactly the same
shape of problem as item 2's builtins, just with a `RecordCallable`
(`RC_ACCESSOR`) behind the global cell instead of a `T_BUILTIN`
function pointer — `(point-x p)` always compiles to a plain
`OP_CALLGLOBAL`, never a fused op, since accessors aren't part of the
compiler's static fusion list at all. `quicken_callglobal_op`
(`icecreme/vm.c`) now recognizes this case too, rewriting such a call site
to a new `OP_QCALLGLOBAL_RECACC` opcode that re-checks the global's
current value (tag, `RC_ACCESSOR` kind, and the accessor's own
`RecordType*` by pointer identity) and the argument's own record type
on every execution, reading the field directly on a match and
deopting back to plain `OP_CALLGLOBAL` otherwise — same pattern as
item 2, same file. See `doc/internals/optimization-icecreme.md`'s "Call-site
quickening for record accessors" section for the implementation and
measured effect (~22% faster on a hot accessor loop), and
`spec/creme/record_accessor_quicken_spec.scm` for the correctness
coverage (quicken, deopt-on-redefinition, re-quicken, and wrong-
record-type-still-raises, all exercised directly).

### 4. Copy-and-patch template compilation (if real native codegen is wanted)

If inline caching and quickening aren't enough and actual native code
generation becomes worth the investment, CPython 3.13's copy-and-patch
technique is the realistic middle ground: precompiled per-opcode
machine-code templates ("stencils") are copied into a code buffer and
patched with operands, glued together for a hot code path. No SSA IR,
no real register allocator, no method-JIT-grade optimizer — closer in
engineering cost to quickening than to a full JIT.

icecreme's use of the **Boehm conservative GC** is a real advantage here:
the collector already scans the C stack (and would scan a JIT code
buffer's stack frames) conservatively, so JIT'd/quickened code doesn't
need precise stack maps or explicit safepoint polling the way a
precise-GC'd VM (JVM, V8) requires. That's normally the hardest part of
adding a JIT tier, and it's mostly already solved here for free.

---

## Not worth pursuing (for this project)

### Full method-JIT or tracing JIT

SSA-form IR, a real register allocator, an x86-64 (or multi-arch)
native code backend, on-stack replacement, and deoptimization frame
reconstruction (LuaJIT-style tracing, or TurboFan/HotSpot C2-style
method compilation) is a multi-week-to-multi-month undertaking on its
own. For this project specifically, the gains such a tier would target
— hot numeric loops — substantially overlap with what icecreme's *ahead-of-
time* compiler already captures via static counted-loop fusion and
inlined arithmetic fast paths. The marginal benefit over items 1–4
above doesn't currently look worth the engineering and maintenance
cost (a JIT tier also means maintaining two correctness-equivalent
execution paths indefinitely).

### Tiered compilation (multiple JIT tiers, e.g. V8's
Ignition→Sparkplug→Maglev→TurboFan or HotSpot's five tiers)

Only relevant once there's more than one compilation strategy to tier
between. Not applicable until (and unless) item 4 or the "not worth
pursuing" full JIT actually exists.

### Escape analysis / partial escape analysis, aggressive loop
optimizations (unrolling, invariant code motion, bounds-check
elimination) as a JIT-time pass

These are classic optimizing-compiler passes that assume a real IR and
a real code generator already exist. Without one, there's nowhere to
attach them. Revisit only alongside item 4, not before.

---

## Suggested order

1. ~~Inline caching for globals~~ — dropped, see item 1's correction note
   above (nothing to cache; global access was already O(1)).
2. Call-site quickening for primitive calls — **done**, see
   `doc/internals/optimization-icecreme.md`'s "Call-site quickening for primitive
   calls" section for the measured effect.
3. Call-site quickening for record accessors — **done**, the same
   technique applied to `define-record-type` field accessors; see
   `doc/internals/optimization-icecreme.md`'s "Call-site quickening for record
   accessors" section for the measured effect.
4. Copy-and-patch native codegen — only if quickening turns out
   insufficient somewhere and real native code generation is
   specifically wanted.
5. Full JIT / tiered compilation / escape analysis — not currently
   recommended; revisit only if 4 ships and still leaves a measured gap.
