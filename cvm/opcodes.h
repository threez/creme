/* On-disk opcode ids — these ARE Creme::Op's own enum ordinals now
 * (src/creme/compile/opcode.cr), in that enum's exact declaration order.
 * This file used to keep its own compacted 84-entry numbering in lockstep
 * by hand with a separate Crystal-side table (CVMSerializer::OP_IDS); that
 * table and the "CVM2" format it wrote are gone — cvm now reads "SCB1"
 * directly (see loader.c), the same format the real Crystal VM's
 * ChunkSerializer/ChunkDeserializer already round-trip. If Creme::Op is
 * ever reordered/extended, this enum must be updated to match — there is
 * no other indirection left to absorb that change.
 *
 * Every op has a real entry here, including ones cvm/vm.c doesn't
 * implement yet (see cvm/README.md for current coverage) — their
 * dispatch-table slot aborts cleanly rather than being absent, so
 * OP_COUNT/array sizing/bounds-checking stay correct regardless of
 * implementation status. */
#ifndef CVM_OPCODES_H
#define CVM_OPCODES_H

enum {
  OP_LOADK = 0,
  OP_LOADNIL = 1,
  OP_LOADTRUE = 2,
  OP_LOADFALSE = 3,
  OP_MOVE = 4,
  OP_GETUPVAL = 5,
  OP_SETUPVAL = 6,
  OP_GETGLOBAL = 7,
  OP_DEFGLOBAL = 8,
  OP_SETGLOBAL = 9,
  OP_ADD = 10,
  OP_SUB = 11,
  OP_MUL = 12,
  OP_NUMLT = 13,
  OP_NUMLE = 14,
  OP_NUMGT = 15,
  OP_NUMGE = 16,
  OP_NUMEQ = 17,
  OP_VECREF = 18,
  OP_VECSET = 19,
  OP_VECLEN = 20,
  OP_STRREF = 21,
  OP_STRSET = 22,
  OP_BVREF = 23,
  OP_BVSET = 24,
  OP_CONS = 25,
  OP_NOT = 26,
  OP_ISNULL = 27,
  OP_ISPAIR = 28,
  OP_ISEQ = 29,
  OP_CXR = 30,
  OP_ABS = 31,
  OP_CMPZERO = 32,
  OP_ADDIMM = 33,
  OP_SUBIMM = 34,
  OP_MULIMM = 35,
  OP_NUMLTIMM = 36,
  OP_NUMLEIMM = 37,
  OP_NUMGTIMM = 38,
  OP_NUMGEIMM = 39,
  OP_NUMEQIMM = 40,
  OP_ISEQIMM = 41,
  OP_ADDUP = 42,
  OP_SUBUP = 43,
  OP_MULUP = 44,
  OP_NUMLTUP = 45,
  OP_NUMLEUP = 46,
  OP_NUMGTUP = 47,
  OP_NUMGEUP = 48,
  OP_NUMEQUP = 49,
  OP_ISEQUP = 50,
  OP_VECREFIMM = 51,
  OP_STRREFIMM = 52,
  OP_BVREFIMM = 53,
  OP_VECSETIMM = 54,
  OP_STRSETIMM = 55,
  OP_BVSETIMM = 56,
  OP_VECREFUP = 57,
  OP_VECSETUP = 58,
  OP_VECLENUP = 59,
  OP_STRREFUP = 60,
  OP_STRSETUP = 61,
  OP_BVREFUP = 62,
  OP_BVSETUP = 63,
  OP_CASEMATCH = 64,
  OP_CASEDISPATCH = 65,
  OP_THROW = 66,
  OP_JMP = 67,
  OP_TESTFALSE = 68,
  OP_TESTLT = 69,
  OP_TESTLE = 70,
  OP_TESTGT = 71,
  OP_TESTGE = 72,
  OP_TESTEQ = 73,
  OP_TESTISEQ = 74,
  OP_TESTLTIMM = 75,
  OP_TESTLEIMM = 76,
  OP_TESTGTIMM = 77,
  OP_TESTGEIMM = 78,
  OP_TESTEQIMM = 79,
  OP_TESTISEQIMM = 80,
  OP_TESTLTUP = 81,
  OP_TESTLEUP = 82,
  OP_TESTGTUP = 83,
  OP_TESTGEUP = 84,
  OP_TESTEQUP = 85,
  OP_TESTISEQUP = 86,
  OP_CALL = 87,
  OP_TAILCALL = 88,
  OP_CALLGLOBAL = 89,
  OP_TAILCALLGLOBAL = 90,
  OP_CALLLOCAL = 91,
  OP_TAILCALLLOCAL = 92,
  OP_CALLUPVAL = 93,
  OP_TAILCALLUPVAL = 94,
  OP_RETURN = 95,
  OP_RETURNGLOBAL = 96,
  OP_RETURNUPVAL = 97,
  OP_ADDRETURN = 98,
  OP_SUBRETURN = 99,
  OP_MULRETURN = 100,
  OP_NUMLTRETURN = 101,
  OP_NUMLERETURN = 102,
  OP_NUMGTRETURN = 103,
  OP_NUMGERETURN = 104,
  OP_NUMEQRETURN = 105,
  OP_ISEQRETURN = 106,
  OP_CLOSURE = 107,
  OP_MAKECASECLOSURE = 108,
  OP_DESTRUCTURE = 109,
  OP_PARAMPUSH = 110,
  OP_PARAMPOP = 111,
  OP_PUSHHANDLER = 112,
  OP_POPHANDLER = 113,
  OP_GUARDRERAISE = 114,
  OP_QUASIQUOTE = 115,
  OP_MAKEPROMISE = 116,
  OP_HELPERFORM = 117,
  OP_HELPERFORMLOCAL = 118,
  /* a=counter register, b=forward jump offset (skip loop if zero-trip),
   * c=limit register, d=step immediate (nonzero int32). Range is INCLUSIVE
   * of limit (Lua FORLOOP-style — see Creme::Op::ForPrep's own doc
   * comment in opcode.cr). */
  OP_FORPREP = 119,
  /* a=counter register, b=backward jump offset (to the instruction after
   * OP_FORPREP), c=limit register, d=step immediate (same convention as
   * OP_FORPREP). counter += d; if still in range vs limit, jump backward. */
  OP_FORLOOP = 120,
  /* ForLoop's counterpart for a counted loop recursing through a GLOBAL binding (an
   * ordinary self-recursive `(define (f ...) ...)`, not a let-loop/do) -- see
   * Creme::Op::ForLoopGuardedInc/Dec's own doc comment in opcode.cr for the full
   * rationale. a=counter register, b=backward jump offset (same convention as
   * OP_FORLOOP), c=limit register. Step is implicit: +1 for OP_FORLOOPGUARDEDINC, -1 for
   * OP_FORLOOPGUARDEDDEC -- freeing d (OP_FORLOOP's step slot) to instead hold a
   * pre-resolved global slot index (see loader.c's resolve_globals -- same convention
   * OP_CALLGLOBAL's own d already uses) naming the recursed-to function's own global
   * binding. Every iteration: counter += step; test in-range vs limit as usual; ALSO
   * re-fetch that global's current value and compare it (pointer identity) against the
   * closure that's currently executing -- only take the backward jump if BOTH hold. A
   * redefinition (identity mismatch) and ordinary range-exhaustion both just fall
   * through (no jump); OP_TESTGLOBALIDENTITY, immediately following the loop, tells them
   * apart. */
  OP_FORLOOPGUARDEDINC = 121,
  OP_FORLOOPGUARDEDDEC = 122,
  /* Runs once, right after an OP_FORLOOPGUARDEDINC/DEC loop exits (NOT hot). a=global
   * slot index (same convention as OP_FORLOOPGUARDEDINC/DEC's own d), b=forward jump
   * offset. Re-fetches that global's current value and compares it (pointer identity) to
   * the currently-executing closure: identical means the loop ran to genuine completion
   * (fall through to the ordinary base-case value); different means a mid-loop
   * redefinition ended it early (jump forward by b to a deopt block -- the plain,
   * unfused compilation of the original `if`). */
  OP_TESTGLOBALIDENTITY = 123,
  OP_COUNT = 124,

  /* Runtime-only opcodes below this point — NEVER present in a serialized
   * chunk (nothing on-disk ever encodes an id >= OP_COUNT, and loader.c's
   * bytecode reader has no reason to produce one). These exist purely for
   * cvm's own in-process call-site quickening: vm.c's OP_CALLGLOBAL case
   * rewrites an instruction to one of these in place, the first time that
   * call site's target turns out to be a specific well-known builtin
   * (`+`, `-`, `*`, `car`, `cdr`, `cons`, `modulo` — see builtins.c's
   * bi_plus/bi_minus/bi_star/bi_car/bi_cdr/bi_cons/bi_modulo doc comment
   * for why the self-hosted bootstrap compiler ever compiles these as an
   * ordinary CallGlobal in the first place, unlike the native compiler's
   * fused Add/Sub/Cons ops) with a matching argument count, OR a
   * `define-record-type` field accessor/constructor (OP_QCALLGLOBAL_
   * RECACC/OP_QCALLGLOBAL_RECCTOR — every top-level record accessor and
   * constructor is a T_RECORD_CALLABLE behind an ordinary CallGlobal too,
   * never a fused op of its own; see vm.c's quicken_callglobal_op doc
   * comment). Each one re-checks its target global's CURRENT value
   * against the exact expected builtin (or record-accessor/constructor
   * kind) every time it runs and deopts back to a plain OP_CALLGLOBAL —
   * permanently, for that call site — the instant that check fails (a
   * redefinition). Appended after OP_COUNT specifically so a newly added
   * on-disk op id can never collide with one of these.
   *
   * OP_QCALLGLOBAL_ADD3 exists alongside OP_QCALLGLOBAL_ADD2 because `+`
   * is genuinely called with 3 arguments at real call sites (e.g.
   * `(+ acc (point-x p) (point-y p))`) — the compiler's own static
   * arithmetic fusion only ever handles 2-operand shapes (see
   * doc/optimization-cvm.md Section 3), so any 3-arg `+` call always
   * compiles to a plain CallGlobal regardless of redefinition tracking,
   * exactly the same "quickening is the only optimization that ever
   * reaches this call site" situation the 2-arg opcodes already handle.
   * `-`/`*` don't get a 3-arg sibling here since no 3-arg call site for
   * either has actually been found hot yet — add one the same way if one
   * ever is. `cons` has no 3-arg form at all (R7RS `cons` is always
   * exactly 2 arguments). */
  OP_QCALLGLOBAL_ADD2 = OP_COUNT,
  OP_QCALLGLOBAL_SUB2,
  OP_QCALLGLOBAL_MUL2,
  OP_QCALLGLOBAL_CONS2,
  OP_QCALLGLOBAL_CAR1,
  OP_QCALLGLOBAL_CDR1,
  OP_QCALLGLOBAL_RECACC,
  /* define-record-type constructor -- the constructor-side counterpart of
   * OP_QCALLGLOBAL_RECACC just above: a top-level record constructor is
   * ALSO a T_RECORD_CALLABLE (kind RC_CTOR) behind an ordinary CallGlobal,
   * never a fused op of its own, so it needs the exact same treatment.
   * Native creme's own vm.cr gained this first (QCallGlobalRecCtor) —
   * this ports it here for parity; see vm.c's quicken_callglobal_op and
   * this op's own CASE for the details (build the SchemeRecord straight
   * from the call's own argument registers, same as call_record_callable's
   * RC_CTOR case already does, just skipping dispatch_call to get there). */
  OP_QCALLGLOBAL_RECCTOR,
  OP_QCALLGLOBAL_ADD3,
  OP_QCALLGLOBAL_MOD2,
  /* string-append (2-arg)/number->string (1-arg, implicit radix 10) and
   * (creme hash-table)'s hash-table-set!/hash-table-ref -- native creme's
   * own vm.cr gained all four first (QCallGlobalStrAppend2/
   * QCallGlobalNumToStr1/QCallGlobalHashSet/QCallGlobalHashRef), ported
   * here for parity. Each identity-checks a global cell's current value
   * against bi_string_append/bi_number_to_string/bi_hash_table_set/
   * bi_hash_table_ref (exposed non-`static` in vm.h for exactly this,
   * same as bi_plus/etc.) and, on a match, calls that same C function
   * DIRECTLY with the call's own argument registers -- skipping
   * dispatch_call's own (already cheap, but non-zero) tag-check chain to
   * get there, not skipping any argument-array allocation the way native
   * creme's version does (cvm's dispatch_call already passes a raw stack
   * slice to every builtin call, quickened or not -- see its own T_BUILTIN
   * branch). No separate argument-type validation here: an unquickened
   * call to the same C function would hit the exact same cvm_abort on bad
   * input, and cvm_abort's own longjmp-to-nearest-guard-handler unwinds
   * correctly regardless of how many C frames are between it and that
   * handler, so calling the builtin directly here (bypassing dispatch_
   * call) changes nothing about error/guard behavior. HashRef quickens at
   * both its 2- and 3-arg forms (its own internal logic already handles
   * both correctly, including "key not found"). */
  OP_QCALLGLOBAL_STRAPPEND2,
  OP_QCALLGLOBAL_NUMTOSTR1,
  OP_QCALLGLOBAL_HASHSET,
  OP_QCALLGLOBAL_HASHREF,
  OP_QUICK_COUNT,
};

/* int -> mnemonic lookup for these ids lives in profiler.c (cvm_op_name),
 * not here — kept out of this header so it isn't duplicated (and flagged as
 * unused) in every other TU that just needs the enum. */

/* On-disk const-pool type tags — mirrors ChunkSerializer::TAG_* (SCB1),
 * NOT the old CVM2-only CTAG_* numbering (different order, and CVM2 had
 * no RATIONAL/COMPLEX/BLOB/BUILTIN tags at all). */
enum {
  TAG_INT = 0,
  TAG_FLOAT = 1,
  TAG_RATIONAL = 2,
  TAG_COMPLEX = 3,
  TAG_SYM = 4,
  TAG_STR = 5,
  TAG_BOOL = 6,
  TAG_NIL = 7,
  TAG_CHAR = 8,
  TAG_PAIR = 9,
  TAG_VECTOR = 10,
  TAG_BLOB = 11,
  TAG_BUILTIN = 12,
  /* Datum labels (R7RS #n=/#n#) -- see chunk_serializer.cr's own
   * TAG_LABEL_DEF/TAG_LABEL_REF doc comment for the wire shape; loader.c's
   * read_datum builds the matching Reader-side label table. */
  TAG_LABEL_DEF = 13,
  TAG_LABEL_REF = 14,
};

/* On-disk Op::CaseDispatch key tags — mirrors chunk.cr's CaseDispatchKey.
 * Unchanged from the old CVM2 numbering. */
enum {
  CDK_INT = 0,
  CDK_CHAR = 1,
  CDK_SYM = 2,
  CDK_BOOL = 3,
  CDK_NIL = 4,
};

/* On-disk QQTemplate node tags — mirrors ChunkSerializer::QQ_*. See
 * chunk_serializer.cr's write_qq_template for the exact tree shape;
 * QQ_HOLE/QQ_SPLICE carry no payload (see that file's comment on why).
 * Unchanged from the old CVM2 numbering. */
enum {
  QQ_CONST = 0,
  QQ_HOLE = 1,
  QQ_SPLICE = 2,
  QQ_LIST = 3,
  QQ_VECTOR = 4,
};

#endif
