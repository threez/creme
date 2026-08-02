/* --profile support for icecreme — see vm.h's Profiler/VmSample/NativeSample
 * struct doc comments for the data this owns, and icecreme/README.md's
 * "Profiling" section for the two samplers' scope/trade-offs. */
#ifndef CVM_PROFILER_H
#define CVM_PROFILER_H

#include "vm.h"

/* Called once per dispatched instruction from vm.c's NEXT() (both the
 * computed-goto and switch dispatch variants), only when
 * vm->profiler.enabled — a cooperative, jittered-interval instruction
 * counter mirroring src/creme/eval/interpreter.cr's tick_sample. `frame` is
 * the CURRENT top frame (already cached as a local in cvm_dispatch), about
 * to execute the instruction at frame->ip. */
void cvm_profiler_tick(VM *vm, Frame *frame);

/* Installs a SIGPROF handler + ITIMER_PROF interval timer that captures a
 * raw backtrace (via backtrace(3), signal-safe: no malloc/symbol lookup)
 * into vm->profiler.native_samples. Call right before running the loaded
 * program; cvm_profiler_stop_native must be called before the process exits
 * (or before printing the report) to restore the previous handler/timer. */
void cvm_profiler_start_native(VM *vm);
void cvm_profiler_stop_native(VM *vm);

/* Prints the "hot Scheme functions" (from vm_samples, symbolized via each
 * chunk's name + the sampled instruction's source line) and "hot C frames"
 * (from native_samples, symbolized via dladdr() after the run) tables to
 * stdout. Call after cvm_profiler_stop_native. */
void cvm_profiler_report(VM *vm);

#endif
