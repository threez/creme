/* Stable on-disk opcode ids. MUST stay byte-for-byte in sync with
 * src/scheme/compile/cvm_serializer.cr's OP_IDS table — that Crystal table,
 * not Scheme::Op's own enum ordinals, is what actually gets written to a
 * .cvmc file, specifically so this file doesn't have to track every reorder
 * of the real (~130-entry) Op enum. If bench/creme.scm ever starts emitting
 * an op not listed here, the serializer raises at emit time rather than
 * silently producing a file this loader would misread. */
#ifndef CVM_OPCODES_H
#define CVM_OPCODES_H

enum {
  OP_LOADK = 0,
  OP_LOADNIL = 1,
  OP_LOADTRUE = 2,
  OP_LOADFALSE = 3,
  OP_MOVE = 4,
  OP_GETUPVAL = 5,
  OP_GETGLOBAL = 6,
  OP_DEFGLOBAL = 7,
  OP_ADD = 8,
  OP_SUB = 9,
  OP_CONS = 10,
  OP_ISNULL = 11,
  OP_NUMEQ = 12,
  OP_ADDIMM = 13,
  OP_SUBIMM = 14,
  OP_MULIMM = 15,
  OP_TESTLTIMM = 16,
  OP_TESTEQIMM = 17,
  OP_TESTLT = 18,
  OP_TESTLTUP = 19,
  OP_TESTEQUP = 20,
  OP_TESTFALSE = 21,
  OP_JMP = 22,
  OP_CXR = 23,
  OP_ABS = 24,
  OP_CLOSURE = 25,
  OP_HELPERFORM = 26,
  OP_CALL = 27,
  OP_TAILCALL = 28,
  OP_CALLGLOBAL = 29,
  OP_TAILCALLGLOBAL = 30,
  OP_CALLLOCAL = 31,
  OP_TAILCALLLOCAL = 32,
  OP_CALLUPVAL = 33,
  OP_TAILCALLUPVAL = 34,
  OP_RETURN = 35,
  OP_ADDRETURN = 36,
  OP_VECREFUP = 37,
  OP_VECSETUP = 38,
  OP_NOT = 39,
  OP_QUASIQUOTE = 40,
  OP_MUL = 41,
  OP_NUMLT = 42,
  OP_NUMGE = 43,
  OP_NUMLTIMM = 44,
  OP_NUMGTIMM = 45,
  OP_NUMEQIMM = 46,
  OP_ADDUP = 47,
  OP_NUMGEUP = 48,
  OP_NUMLEUP = 49,
  OP_ISPAIR = 50,
  OP_ISEQ = 51,
  OP_SETUPVAL = 52,
  OP_VECREFIMM = 53,
  OP_VECSETIMM = 54,
  OP_STRREFIMM = 55,
  OP_STRREFUP = 56,
  OP_TESTGE = 57,
  OP_TESTGTIMM = 58,
  OP_TESTISEQ = 59,
  OP_CASEDISPATCH = 60,
  OP_NUMLE = 61,
  OP_NUMGT = 62,
  OP_NUMLEIMM = 63,
  OP_NUMGEIMM = 64,
  OP_SUBUP = 65,
  OP_MULUP = 66,
  OP_NUMLTUP = 67,
  OP_NUMGTUP = 68,
  OP_NUMEQUP = 69,
  OP_ISEQIMM = 70,
  OP_ISEQUP = 71,
  OP_TESTLE = 72,
  OP_TESTGT = 73,
  OP_TESTLEIMM = 74,
  OP_TESTGEIMM = 75,
  OP_TESTISEQIMM = 76,
  OP_VECREF = 77,
  OP_VECLEN = 78,
  OP_VECSET = 79,
  OP_VECLENUP = 80,
  OP_CASEMATCH = 81,
  OP_SUBRETURN = 82,
  OP_MULRETURN = 83,
  OP_COUNT = 84,
};

/* int -> mnemonic lookup for these ids lives in profiler.c (cvm_op_name),
 * not here — kept out of this header so it isn't duplicated (and flagged as
 * unused) in every other TU that just needs the enum. */

/* On-disk const-pool type tags — mirrors CVMSerializer::TAG_*. */
enum {
  CTAG_INT = 0,
  CTAG_FLOAT = 1,
  CTAG_SYM = 2,
  CTAG_STR = 3,
  CTAG_BOOL = 4,
  CTAG_NIL = 5,
  CTAG_PAIR = 6,
  CTAG_VECTOR = 7,
  CTAG_CHAR = 8,
};

/* On-disk Op::CaseDispatch key tags — mirrors chunk.cr's CaseDispatchKey. */
enum {
  CDK_INT = 0,
  CDK_CHAR = 1,
  CDK_SYM = 2,
  CDK_BOOL = 3,
  CDK_NIL = 4,
};

/* On-disk QQTemplate node tags — mirrors CVMSerializer::QQ_*. See
 * cvm_serializer.cr's write_qq_template for the exact tree shape; QQ_HOLE/
 * QQ_SPLICE carry no payload (see that file's comment on why). */
enum {
  QQ_CONST = 0,
  QQ_HOLE = 1,
  QQ_SPLICE = 2,
  QQ_LIST = 3,
  QQ_VECTOR = 4,
};

#endif
