/* (creme actor) — a Fiber-per-actor message-passing runtime, ported here
 * as a real-OS-thread-per-actor one (see actor.c's own header comment
 * for the full design and how it maps onto src/creme/modules/creme/
 * actor.cr). Phase 2: local spawn/send!/receive!/self/monitor/
 * register!/whereis/down. Later phases add the 'local same-process
 * transport and real TCP/Unix distribution on top of the same
 * registry/mailbox primitives. */
#ifndef CVM_ACTOR_H
#define CVM_ACTOR_H

#include "vm.h"

void cvm_register_actor_builtins(VM *vm);

#endif
