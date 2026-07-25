/* --profile support — see profiler.h and vm.h's Profiler/VmSample/
 * NativeSample doc comments, and cvm/README.md's "Profiling" section for
 * scope/trade-offs (most notably: the native sampler mostly shows
 * cvm_dispatch/builtins, not per-Scheme-function detail, since this VM
 * doesn't recurse through the C stack for Scheme-level calls). */
#include <dlfcn.h>
#include <execinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gc.h>

#include "opcodes.h"
#include "profiler.h"

/* int -> mnemonic for the on-disk op ids in opcodes.h, same declaration
 * order as that enum. Kept here (not opcodes.h) so it isn't duplicated/
 * flagged as an unused static in every other TU that only needs the enum
 * itself — this table is only ever read by the report functions below. */
static const char *op_name(int op) {
  static const char *const names[OP_COUNT] = {
      [OP_LOADK] = "LoadK", [OP_LOADNIL] = "LoadNil", [OP_LOADTRUE] = "LoadTrue",
      [OP_LOADFALSE] = "LoadFalse", [OP_MOVE] = "Move", [OP_GETUPVAL] = "GetUpval",
      [OP_GETGLOBAL] = "GetGlobal", [OP_DEFGLOBAL] = "DefGlobal", [OP_ADD] = "Add",
      [OP_SUB] = "Sub", [OP_CONS] = "Cons", [OP_ISNULL] = "IsNull", [OP_NUMEQ] = "NumEq",
      [OP_ADDIMM] = "AddImm", [OP_SUBIMM] = "SubImm", [OP_MULIMM] = "MulImm",
      [OP_TESTLTIMM] = "TestLtImm", [OP_TESTEQIMM] = "TestEqImm", [OP_TESTLT] = "TestLt",
      [OP_TESTLTUP] = "TestLtUp", [OP_TESTEQUP] = "TestEqUp", [OP_TESTFALSE] = "TestFalse",
      [OP_JMP] = "Jmp", [OP_CXR] = "Cxr", [OP_ABS] = "Abs", [OP_CLOSURE] = "Closure",
      [OP_HELPERFORM] = "HelperForm", [OP_CALL] = "Call", [OP_TAILCALL] = "TailCall",
      [OP_CALLGLOBAL] = "CallGlobal", [OP_TAILCALLGLOBAL] = "TailCallGlobal",
      [OP_CALLLOCAL] = "CallLocal", [OP_TAILCALLLOCAL] = "TailCallLocal",
      [OP_CALLUPVAL] = "CallUpval", [OP_TAILCALLUPVAL] = "TailCallUpval",
      [OP_RETURN] = "Return", [OP_ADDRETURN] = "AddReturn", [OP_VECREFUP] = "VecRefUp",
      [OP_VECSETUP] = "VecSetUp", [OP_NOT] = "Not", [OP_QUASIQUOTE] = "Quasiquote",
      [OP_MUL] = "Mul", [OP_NUMLT] = "NumLt", [OP_NUMGE] = "NumGe", [OP_NUMLTIMM] = "NumLtImm",
      [OP_NUMGTIMM] = "NumGtImm", [OP_NUMEQIMM] = "NumEqImm", [OP_ADDUP] = "AddUp",
      [OP_NUMGEUP] = "NumGeUp", [OP_NUMLEUP] = "NumLeUp", [OP_ISPAIR] = "IsPair",
      [OP_ISEQ] = "IsEq", [OP_SETUPVAL] = "SetUpval", [OP_VECREFIMM] = "VecRefImm",
      [OP_VECSETIMM] = "VecSetImm", [OP_STRREFIMM] = "StrRefImm", [OP_STRREFUP] = "StrRefUp",
      [OP_TESTGE] = "TestGe", [OP_TESTGTIMM] = "TestGtImm", [OP_TESTISEQ] = "TestIsEq",
      [OP_CASEDISPATCH] = "CaseDispatch", [OP_NUMLE] = "NumLe", [OP_NUMGT] = "NumGt",
      [OP_NUMLEIMM] = "NumLeImm", [OP_NUMGEIMM] = "NumGeImm", [OP_SUBUP] = "SubUp",
      [OP_MULUP] = "MulUp", [OP_NUMLTUP] = "NumLtUp", [OP_NUMGTUP] = "NumGtUp",
      [OP_NUMEQUP] = "NumEqUp", [OP_ISEQIMM] = "IsEqImm", [OP_ISEQUP] = "IsEqUp",
      [OP_TESTLE] = "TestLe", [OP_TESTGT] = "TestGt", [OP_TESTLEIMM] = "TestLeImm",
      [OP_TESTGEIMM] = "TestGeImm", [OP_TESTISEQIMM] = "TestIsEqImm", [OP_VECREF] = "VecRef",
      [OP_VECLEN] = "VecLen", [OP_VECSET] = "VecSet", [OP_VECLENUP] = "VecLenUp",
      [OP_CASEMATCH] = "CaseMatch", [OP_SUBRETURN] = "SubReturn", [OP_MULRETURN] = "MulReturn",
      /* Not implemented yet (see vm.c's L_UNIMPL) — named anyway so a
       * profile report / abort message referencing one of these by ordinal
       * still prints a real mnemonic instead of "?". */
      [OP_SETGLOBAL] = "SetGlobal", [OP_STRREF] = "StrRef", [OP_STRSET] = "StrSet",
      [OP_BVREF] = "BvRef", [OP_BVSET] = "BvSet", [OP_CMPZERO] = "CmpZero",
      [OP_BVREFIMM] = "BvRefImm", [OP_STRSETIMM] = "StrSetImm", [OP_BVSETIMM] = "BvSetImm",
      [OP_STRSETUP] = "StrSetUp", [OP_BVREFUP] = "BvRefUp", [OP_BVSETUP] = "BvSetUp",
      [OP_THROW] = "Throw", [OP_TESTEQ] = "TestEq", [OP_TESTLEUP] = "TestLeUp",
      [OP_TESTGTUP] = "TestGtUp", [OP_TESTGEUP] = "TestGeUp", [OP_TESTISEQUP] = "TestIsEqUp",
      [OP_RETURNGLOBAL] = "ReturnGlobal", [OP_RETURNUPVAL] = "ReturnUpval",
      [OP_NUMLTRETURN] = "NumLtReturn", [OP_NUMLERETURN] = "NumLeReturn",
      [OP_NUMGTRETURN] = "NumGtReturn", [OP_NUMGERETURN] = "NumGeReturn",
      [OP_NUMEQRETURN] = "NumEqReturn", [OP_ISEQRETURN] = "IsEqReturn",
      [OP_MAKECASECLOSURE] = "MakeCaseClosure", [OP_DESTRUCTURE] = "Destructure",
      [OP_PARAMPUSH] = "ParamPush", [OP_PARAMPOP] = "ParamPop",
      [OP_PUSHHANDLER] = "PushHandler", [OP_POPHANDLER] = "PopHandler", [OP_GUARDRERAISE] = "GuardReraise",
      [OP_MAKEPROMISE] = "MakePromise", [OP_HELPERFORMLOCAL] = "HelperFormLocal",
  };
  if (op < 0 || op >= OP_COUNT || !names[op]) return "?";
  return names[op];
}

/* ---- VM-level sampler (prof-vm analog) ---- */

void cvm_profiler_tick(VM *vm, Frame *frame) {
  Profiler *p = &vm->profiler;
  if (--p->vm_countdown > 0) return;

  Chunk *chunk = frame->chunk;
  int ip = frame->ip;
  VmSample *slot = NULL;
  for (int i = 0; i < p->n_vm_samples; i++) {
    if (p->vm_samples[i].chunk == chunk && p->vm_samples[i].ip == ip) {
      slot = &p->vm_samples[i];
      break;
    }
  }
  if (slot) {
    slot->count++;
  } else if (p->n_vm_samples < CVM_PROFILE_VM_SAMPLES_CAP) {
    slot = &p->vm_samples[p->n_vm_samples++];
    slot->chunk = chunk;
    slot->ip = ip;
    slot->count = 1;
  }
  /* else: distinct (chunk, ip) table is full — further NEW sites are
   * silently dropped (existing ones keep accumulating). Fine at this
   * table's size for a bench-scale program; see vm.h's own comment. */

  /* Jittered reseed, uniform in [1, 2*vm_interval] — mirrors
   * src/scheme/eval/interpreter.cr's tick_sample anti-aliasing jitter, so
   * the sampler doesn't beat in lockstep with a fixed-length recursive
   * call and always land on the same instruction. */
  p->vm_countdown = 1 + rand() % (2 * p->vm_interval);
}

/* ---- native sampler (prof-native analog) ---- */

/* A signal handler can't be handed vm directly (its signature is fixed), so
 * this is the one piece of global state here — set only while a profiled
 * run is in flight, between cvm_profiler_start_native/_stop_native. */
static VM *g_profiled_vm = NULL;

/* backtrace(3) isn't formally on POSIX's async-signal-safe list, but it's
 * the standard technique real sampling profilers (gperftools, etc.) use
 * from a SIGPROF handler in practice: no malloc, no symbol resolution here —
 * just a fixed-size array of return addresses, resolved to names later in
 * cvm_profiler_report (well outside signal context). */
static void sigprof_handler(int sig) {
  (void)sig;
  VM *vm = g_profiled_vm;
  if (!vm) return;
  Profiler *p = &vm->profiler;
  if (p->n_native_samples >= CVM_PROFILE_NATIVE_SAMPLES_CAP) return;
  NativeSample *s = &p->native_samples[p->n_native_samples++];
  s->n_pcs = backtrace(s->pcs, (int)(sizeof(s->pcs) / sizeof(s->pcs[0])));
}

void cvm_profiler_start_native(VM *vm) {
  Profiler *p = &vm->profiler;
  p->native_samples = GC_MALLOC(sizeof(NativeSample) * CVM_PROFILE_NATIVE_SAMPLES_CAP);
  p->n_native_samples = 0;
  g_profiled_vm = vm;

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = sigprof_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  sigaction(SIGPROF, &sa, &p->old_sigprof_action);

  /* ~1ms sampling interval — matches a typical sampling-profiler default. */
  struct itimerval timer;
  timer.it_interval.tv_sec = 0;
  timer.it_interval.tv_usec = 1000;
  timer.it_value = timer.it_interval;
  setitimer(ITIMER_PROF, &timer, &p->old_itimer);
}

void cvm_profiler_stop_native(VM *vm) {
  Profiler *p = &vm->profiler;
  struct itimerval zero;
  memset(&zero, 0, sizeof(zero));
  setitimer(ITIMER_PROF, &zero, NULL);
  setitimer(ITIMER_PROF, &p->old_itimer, NULL);
  sigaction(SIGPROF, &p->old_sigprof_action, NULL);
  g_profiled_vm = NULL;
}

/* ---- report ---- */

static int cmp_vm_sample_desc(const void *a, const void *b) {
  long ca = ((const VmSample *)a)->count, cb = ((const VmSample *)b)->count;
  return ca < cb ? 1 : (ca > cb ? -1 : 0);
}

static void report_vm_samples(VM *vm) {
  Profiler *p = &vm->profiler;
  qsort(p->vm_samples, (size_t)p->n_vm_samples, sizeof(VmSample), cmp_vm_sample_desc);

  long total = 0;
  for (int i = 0; i < p->n_vm_samples; i++) total += p->vm_samples[i].count;

  printf("\nhot Scheme functions (%ld samples, ~1 per %d instructions)\n", total, p->vm_interval);
  printf("  %-4s %6s %8s  %-20s %-16s %s\n", "#", "%", "count", "function", "location", "op");
  int shown = p->n_vm_samples < 20 ? p->n_vm_samples : 20;
  for (int i = 0; i < shown; i++) {
    Chunk *c = p->vm_samples[i].chunk;
    int ip = p->vm_samples[i].ip;
    Instruction *ins = &c->instrs[ip];
    char loc[128];
    if (ins->has_pos) {
      snprintf(loc, sizeof(loc), "%s:%d", ins->file ? ins->file : (vm->source_file ? vm->source_file : "?"), ins->line);
    } else {
      snprintf(loc, sizeof(loc), "-");
    }
    double pct = total ? 100.0 * (double)p->vm_samples[i].count / (double)total : 0.0;
    printf("  %-4d %6.1f %8ld  %-20s %-16s %s\n", i + 1, pct, p->vm_samples[i].count, c->name, loc,
           op_name(ins->op));
  }
}

typedef struct {
  char name[256];
  long count;
} NativeAgg;

static int cmp_native_agg_desc(const void *a, const void *b) {
  long ca = ((const NativeAgg *)a)->count, cb = ((const NativeAgg *)b)->count;
  return ca < cb ? 1 : (ca > cb ? -1 : 0);
}

#define CVM_PROFILE_NATIVE_AGG_CAP 4096

static void report_native_samples(VM *vm) {
  Profiler *p = &vm->profiler;
  NativeAgg *agg = GC_MALLOC(sizeof(NativeAgg) * CVM_PROFILE_NATIVE_AGG_CAP);
  int n_agg = 0;

  for (int i = 0; i < p->n_native_samples; i++) {
    NativeSample *s = &p->native_samples[i];
    if (s->n_pcs <= 0) continue;
    /* pcs[0]/pcs[1] are sigprof_handler itself and the kernel's signal
     * trampoline (e.g. Darwin's `_sigtramp`) — always present, never useful.
     * pcs[2] is the first frame actually interrupted; fall back toward 0 if
     * an unusually shallow capture didn't reach it. */
    int idx = s->n_pcs > 2 ? 2 : s->n_pcs - 1;
    void *pc = s->pcs[idx];

    char namebuf[256];
    Dl_info info;
    if (dladdr(pc, &info) && info.dli_sname) {
      snprintf(namebuf, sizeof(namebuf), "%s", info.dli_sname);
    } else {
      snprintf(namebuf, sizeof(namebuf), "%p", pc);
    }

    int found = -1;
    for (int j = 0; j < n_agg; j++) {
      if (strcmp(agg[j].name, namebuf) == 0) {
        found = j;
        break;
      }
    }
    if (found >= 0) {
      agg[found].count++;
    } else if (n_agg < CVM_PROFILE_NATIVE_AGG_CAP) {
      snprintf(agg[n_agg].name, sizeof(agg[n_agg].name), "%s", namebuf);
      agg[n_agg].count = 1;
      n_agg++;
    }
  }

  qsort(agg, (size_t)n_agg, sizeof(NativeAgg), cmp_native_agg_desc);
  long total = 0;
  for (int i = 0; i < n_agg; i++) total += agg[i].count;

  printf("\nhot C frames (%ld samples, ~1ms interval)\n", total);
  printf("  note: cvm runs Scheme calls through its own explicit Frame array,\n"
         "  not C recursion, so this mostly reflects real C time (builtins,\n"
         "  GC, cvm_dispatch itself) rather than per-Scheme-function detail —\n"
         "  see the \"hot Scheme functions\" table above for that.\n");
  printf("  %-4s %6s %8s  %s\n", "#", "%", "count", "frame");
  int shown = n_agg < 20 ? n_agg : 20;
  for (int i = 0; i < shown; i++) {
    double pct = total ? 100.0 * (double)agg[i].count / (double)total : 0.0;
    printf("  %-4d %6.1f %8ld  %s\n", i + 1, pct, agg[i].count, agg[i].name);
  }
}

void cvm_profiler_report(VM *vm) {
  report_vm_samples(vm);
  report_native_samples(vm);
  printf("\n");
}
