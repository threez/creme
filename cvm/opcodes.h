/* On-disk opcode ids — these ARE Scheme::Op's own enum ordinals now
 * (src/scheme/compile/opcode.cr), in that enum's exact declaration order.
 * This file used to keep its own compacted 84-entry numbering in lockstep
 * by hand with a separate Crystal-side table (CVMSerializer::OP_IDS); that
 * table and the "CVM2" format it wrote are gone — cvm now reads "SCB1"
 * directly (see loader.c), the same format the real Crystal VM's
 * ChunkSerializer/ChunkDeserializer already round-trip. If Scheme::Op is
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
  OP_COUNT = 119,
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
