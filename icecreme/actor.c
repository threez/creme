/* (creme actor) — see actor.h. A port of src/creme/modules/creme/actor.cr
 * (948 lines: Fiber-per-actor + Channel mailboxes + an optional TCP/Unix/
 * 'local distributed transport) onto REAL OS THREADS instead of Crystal's
 * cooperative Fibers, per explicit direction (see this project's own
 * planning doc for the alternatives considered and why).
 *
 * Phase 2: purely local actors -- spawn/send!/receive!/self/monitor/
 * register!/whereis/actor-ref-id and the <down> record, all within one
 * implicit process-wide ActorSystem. Phase 3 (this file, now): multiple
 * independent ActorSystems ("nodes") in the same process --
 * start-node/node-name/node-address/stop-node! for the 'local transport,
 * with register!/whereis scoped per-node and spawn inheriting its
 * spawning actor's own current node. Every actor gets its OWN VM (see
 * vm.c's creme_new_child_vm) running on its own pthread; icecreme's bytecode dispatch
 * loop always reads globals through whichever `VM*` it's handed, so a
 * Closure/thunk captured in the spawning thread runs correctly against
 * the CHILD's own copied globals table the moment creme_apply(child_vm,
 * thunk, ...) is called from that actor's own thread -- no special
 * Closure-side support needed at all (Closure carries only a Chunk* +
 * upvalues, never a VM pointer -- see vm.h's own struct Closure).
 *
 * Mailbox delivery shares Value pointers directly between actors (no
 * serialization for local delivery, matching native's own "arrives as
 * the SAME object" semantics) -- safe because Boehm GC's own allocator
 * is thread-safe for concurrent GC_MALLOC from different registered
 * threads, which is the only icecreme-specific thread-safety property this
 * relies on; two actors mutating a SHARED mutable pair/vector/string
 * they both hold a reference to is a real hazard, but not a new one --
 * Crystal's own fiber scheduler already runs across multiple real OS
 * threads by default, so native code has the identical hazard today.
 *
 * KNOWN ENVIRONMENT GOTCHA (this session's own finding, reproduced in
 * total isolation with no icecreme code involved at all): on this project's
 * FreeBSD dev environment's boehm-gc-threaded 8.2.10 build,
 * GC_unregister_my_thread() itself segfaults. Every actor thread here
 * therefore deliberately never calls it -- a short-lived thread that
 * stays registered after it exits is a well-documented, merely
 * resource-leaking Boehm GC trade-off (the collector keeps scanning a
 * dead thread's now-static stack range harmlessly until process exit),
 * nowhere near as bad as a segfault. If a future environment's GC build
 * doesn't have this bug, calling it would be a safe, purely cosmetic
 * addition -- just isn't worth the risk of reintroducing this crash
 * blindly.
 */
#include "builtin_config.h"

#if CREME_WITH_ACTOR

#include <arpa/inet.h>
#include <errno.h>
#include <gc.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <openssl/hmac.h>
#include <openssl/rand.h>

#include "actor.h"
#include "embed.h"

#define MAILBOX_CAP 64

typedef struct {
  pthread_mutex_t mutex;
  pthread_cond_t not_full;
  pthread_cond_t not_empty;
  Value buf[MAILBOX_CAP];
  int head, tail, count;
} Mailbox;

static void mailbox_init(Mailbox *mb) {
  pthread_mutex_init(&mb->mutex, NULL);
  pthread_cond_init(&mb->not_full, NULL);
  pthread_cond_init(&mb->not_empty, NULL);
  mb->head = mb->tail = mb->count = 0;
}

/* Blocks the PRODUCER when full -- matches native's own bounded
 * Channel(64) exactly, including that a slow receiver stalls the
 * sender, not just an unboundedly queued backlog. */
static void mailbox_send(Mailbox *mb, Value v) {
  pthread_mutex_lock(&mb->mutex);
  while (mb->count >= MAILBOX_CAP) pthread_cond_wait(&mb->not_full, &mb->mutex);
  mb->buf[mb->tail] = v;
  mb->tail = (mb->tail + 1) % MAILBOX_CAP;
  mb->count++;
  pthread_cond_signal(&mb->not_empty);
  pthread_mutex_unlock(&mb->mutex);
}

static Value mailbox_receive(Mailbox *mb) {
  pthread_mutex_lock(&mb->mutex);
  while (mb->count == 0) pthread_cond_wait(&mb->not_empty, &mb->mutex);
  Value v = mb->buf[mb->head];
  mb->head = (mb->head + 1) % MAILBOX_CAP;
  mb->count--;
  pthread_cond_signal(&mb->not_full);
  pthread_mutex_unlock(&mb->mutex);
  return v;
}

/* Phase 3: what used to be one implicit process-wide registry is now a
 * struct any number of independent "nodes" can each have their own copy
 * of -- mirrors native's own ActorSystem (actor.cr), one instance per
 * Interpreter, threaded through as `current_interp.actor_system`. icecreme has
 * no per-Interpreter concept to hang this off of, so instead each
 * ActorContext directly carries the ActorSystem* it belongs to (see
 * below); a fresh script starts with every actor implicitly in
 * g_default_system until/unless its own thread calls start-node, which
 * reassigns THAT THREAD's own current ActorContext to a new system (its
 * own future spawn()ed children then inherit that new system, exactly
 * like native's `child.actor_system = system` inheritance). */
/* Phase 4: one cached outbound TCP/Unix connection per peer -- `key` is
 * "tcp:host:port" or "unix:path" (mirrors native's own
 * ActorAddress#connection_key). write_mutex serializes frames from
 * multiple actor threads sending to the SAME peer concurrently; unlike
 * native's own cached-Channel-plus-dedicated-writer-fiber design, icecreme's
 * actor threads can just block directly on a real blocking socket write
 * under this mutex -- there's no fiber-scheduler starvation concern here
 * to design around, so a plain mutex is a deliberate simplification, not
 * a missing piece. */
typedef struct Connection {
  char *key;
  int fd;
  pthread_mutex_t write_mutex;
  struct Connection *next;
} Connection;

typedef struct ActorSystem {
  pthread_mutex_t mutex;
  struct ActorContext *actors;
  struct NameEntry *names;
  struct MonitorEntry *monitors;
  long next_actor_id;
  char *node_name; /* NULL for the implicit default system (not a 'local
                     * node at all -- node-name/node-address abort on it,
                     * matching native's "not a node" case). */
  int node_name_len;
  struct ActorSystem *next; /* g_local_nodes linked list */

  /* Phase 4: 'tcp/'unix node state -- exactly one of tcp_host/unix_path
   * is non-NULL for a real network node (mirrors native's own
   * bind_host+bind_port / unix_path split); all three of these are NULL
   * for both the default system and a 'local node. */
  char *cookie;
  int cookie_len;
  char *tcp_host;
  int tcp_port;
  char *unix_path;
  int listener_fd; /* -1 if this system never called start-node 'tcp/'unix */
  pthread_t accept_thread;
  Connection *connections; /* outbound cache, guarded by `mutex` above */
  /* The VM whose globals a message decoded off the wire for THIS system
   * should resolve record-type names against -- captured once at
   * start-node time (the calling actor's own VM), mirroring native's own
   * ActorSystem#global_env (captured from whichever Interpreter created
   * it). Every actor sharing a node was compiled from the same whole-
   * program build, so any one of their VMs' globals tables has the same
   * record types at the same slots -- this is just "pick one". */
  VM *creator_vm;
} ActorSystem;

typedef struct ActorContext {
  char *id; /* GC_MALLOC'd, nul-terminated -- a plain sequential counter
             * here (icecreme's own id scheme, not necessarily matching
             * native's own id format -- nothing depends on the two
             * agreeing, ids are only ever compared within icecreme's own
             * registry). */
  VM *vm;
  pthread_t thread; /* the main "actor" (never spawned, wraps the
                      * script's own top-level VM via ensure_context)
                      * has no meaningful thread field -- only spawn()'d
                      * contexts set this. */
  Mailbox mailbox;
  ActorSystem *system; /* which node this actor lives in -- ONLY ever
                         * read/written by this context's OWN thread (the
                         * thread that owns g_current_actor == this), so
                         * unlike every other field below this needs no
                         * lock of its own. */
  struct ActorContext *next; /* this system's own `actors` linked list */
} ActorContext;

enum { ADDR_NONE = 0, ADDR_TCP = 1, ADDR_UNIX = 2 };

/* A Scheme-visible actor-ref value (T_BOX, BOX_KIND_ACTOR_REF). Two
 * shapes: `local_ctx` set means a direct, process-wide-valid pointer --
 * covers every 'local-transport ref (see Phase 3's own comment on why no
 * "localize_refs"-style rewriting is ever needed for those) as well as
 * every ordinary same-process ref. `local_ctx` NULL means a genuine
 * remote ref (Phase 4) that can only be reached over a real socket --
 * `addr_kind`/host+port or path say which peer, matching native's own
 * ActorRefData#local?/address split for exactly this case (and ONLY this
 * case; icecreme never needs the split for 'local since that's always
 * eagerly resolved to a local_ctx, even when minted via remote-ref off a
 * "local://" URI -- see bi_remote_ref). */
typedef struct {
  char *id;
  ActorContext *local_ctx;
  int addr_kind;
  char *host;
  int port;
  char *path;
} ActorRef;

static Value v_actor_ref(char *id, ActorContext *ctx) {
  ActorRef *ref = GC_MALLOC(sizeof(ActorRef));
  ref->id = id;
  ref->local_ctx = ctx;
  ref->addr_kind = ADDR_NONE;
  return v_box(ref, BOX_KIND_ACTOR_REF);
}

static Value v_actor_ref_tcp(char *id, const char *host, int port) {
  ActorRef *ref = GC_MALLOC(sizeof(ActorRef));
  ref->id = id;
  ref->local_ctx = NULL;
  ref->addr_kind = ADDR_TCP;
  ref->host = (char *)host;
  ref->port = port;
  return v_box(ref, BOX_KIND_ACTOR_REF);
}

static Value v_actor_ref_unix(char *id, const char *path) {
  ActorRef *ref = GC_MALLOC(sizeof(ActorRef));
  ref->id = id;
  ref->local_ctx = NULL;
  ref->addr_kind = ADDR_UNIX;
  ref->path = (char *)path;
  return v_box(ref, BOX_KIND_ACTOR_REF);
}

typedef struct NameEntry {
  char *name;
  int name_len;
  char *id;
  struct NameEntry *next;
} NameEntry;

typedef struct MonitorEntry {
  char *watcher_id;
  char *target_id;
  struct MonitorEntry *next;
} MonitorEntry;

/* The implicit "default node" -- every actor lives here until/unless its
 * own thread calls start-node. Exactly one of these exists for the whole
 * process (node_name/tcp_host/unix_path all stay NULL, marking it as
 * "not a real node" for node-name/node-address/node-port/node-path,
 * which all abort on it). */
static ActorSystem g_default_system = {
    PTHREAD_MUTEX_INITIALIZER, NULL, NULL, NULL, 1, NULL, 0, NULL,
    NULL, 0, NULL, 0, NULL, -1, 0, NULL, NULL};

/* Process-wide registry of every NAMED (start-node'd) 'local system, so a
 * ref/id minted in one system can still be found by name from another --
 * mirrors native's own LocalNodeRegistry (actor.cr) exactly. */
static pthread_mutex_t g_node_registry_mutex = PTHREAD_MUTEX_INITIALIZER;
static ActorSystem *g_local_nodes = NULL;

/* The calling OS thread's own actor identity -- set once, either by
 * spawn()'s thread entry function (immediately, before the thunk runs)
 * or lazily by ensure_context() the first time the MAIN script thread
 * itself calls self!/receive!/monitor (mirrors native's own
 * ensure_context: "even the main script fiber gets one, lazily"). */
static _Thread_local ActorContext *g_current_actor = NULL;

/* Caller must hold sys->mutex. */
static ActorContext *find_context_by_id_locked(ActorSystem *sys, const char *id) {
  for (ActorContext *c = sys->actors; c; c = c->next) {
    if (strcmp(c->id, id) == 0) return c;
  }
  return NULL;
}

/* Caller must hold sys->mutex. */
static char *find_id_by_name_locked(ActorSystem *sys, const char *name, int name_len) {
  for (NameEntry *n = sys->names; n; n = n->next) {
    if (n->name_len == name_len && memcmp(n->name, name, (size_t)name_len) == 0) return n->id;
  }
  return NULL;
}

static ActorContext *new_actor_context(VM *vm_for_ctx, ActorSystem *sys) {
  ActorContext *ctx = GC_MALLOC(sizeof(ActorContext));
  ctx->vm = vm_for_ctx;
  ctx->system = sys;
  mailbox_init(&ctx->mailbox);

  char buf[32];
  pthread_mutex_lock(&sys->mutex);
  int n = snprintf(buf, sizeof(buf), "%ld", sys->next_actor_id++);
  char *id = GC_MALLOC((size_t)(n + 1));
  memcpy(id, buf, (size_t)(n + 1));
  ctx->id = id;
  ctx->next = sys->actors;
  sys->actors = ctx;
  pthread_mutex_unlock(&sys->mutex);
  return ctx;
}

/* self/receive!/monitor's own "who am I" -- see g_current_actor's own
 * comment. Always wraps the CALLING thread's real `vm` (never a copy),
 * so the main script's own top-level VM becomes its own actor context
 * exactly once, on first use, starting out in the default system. */
static ActorContext *ensure_context(VM *vm) {
  if (g_current_actor) return g_current_actor;
  ActorContext *ctx = new_actor_context(vm, &g_default_system);
  g_current_actor = ctx;
  return ctx;
}

/* start-node reassigns ctx->system, but that alone isn't enough: whereis
 * (via find_id_by_name_locked -> find_context_by_id_locked) resolves a
 * registered name back to an ActorContext* by searching the SYSTEM's own
 * `actors` linked list -- so ctx must actually be UNLINKED from its old
 * system and RELINKED into the new one, not just have its `system` field
 * repointed. Locks whichever system has the lower address first, so two
 * actors swapping systems in opposite directions at the same time can
 * never deadlock against each other. */
static void move_context_to_system(ActorContext *ctx, ActorSystem *new_sys) {
  ActorSystem *old_sys = ctx->system;
  if (old_sys == new_sys) return;

  ActorSystem *first = old_sys < new_sys ? old_sys : new_sys;
  ActorSystem *second = old_sys < new_sys ? new_sys : old_sys;
  pthread_mutex_lock(&first->mutex);
  pthread_mutex_lock(&second->mutex);

  ActorContext **pp = &old_sys->actors;
  while (*pp) {
    if (*pp == ctx) *pp = (*pp)->next;
    else pp = &(*pp)->next;
  }
  ctx->next = new_sys->actors;
  new_sys->actors = ctx;
  ctx->system = new_sys;

  /* new_sys->next_actor_id is independent of whatever system ctx's id
   * was minted in (new_actor_context, above) -- a freshly alloc_actor_
   * system'd sys always starts counting from 1, with no idea ctx is
   * moving in still carrying (say) "1" from its old system. Without
   * this, the FIRST actor spawned afterward in new_sys (bi_spawn's own
   * new_actor_context call) mints that same "1" again, and two distinct
   * ActorContexts end up sharing one id -- notify_down/monitor/whereis
   * all key strictly off ctx->id string equality (find_context_by_id_
   * locked), so a collision silently routes a <down> notification (or
   * any addressed send) to whichever of the two same-id contexts happens
   * to come first in new_sys->actors, not necessarily the intended one.
   * Concretely: examples/34-actor-ping-pong.scm's own `(start-node ...)`
   * followed by `(spawn ...)` + `(monitor ...)` + `(receive!)` used to
   * hang forever this way -- the moved-in main-script ctx and the freshly
   * spawned child both got id "1" in the node's own system, so the
   * child's own exit notification could be delivered back to the CHILD's
   * own (already-exited) mailbox instead of the watching main script's,
   * leaving its `(receive!)` blocked with nothing ever arriving. */
  long ctx_id_n = strtol(ctx->id, NULL, 10);
  if (ctx_id_n >= new_sys->next_actor_id) new_sys->next_actor_id = ctx_id_n + 1;

  pthread_mutex_unlock(&second->mutex);
  pthread_mutex_unlock(&first->mutex);
}

typedef struct PReader PReader;

static char *dupn(const char *s, int len) {
  char *out = GC_MALLOC((size_t)(len > 0 ? len : 1) + 1);
  if (len > 0) memcpy(out, s, (size_t)len);
  out[len > 0 ? len : 0] = '\0';
  return out;
}

/* The full dialable URI for actor `id` on `sys`, whichever transport it
 * was started with -- mirrors native's own node_address_uri (shared by
 * local_ref_uri, for embedding a local ref in an outgoing tcp:/unix:
 * message, and the node-address builtin). Aborts (via creme_abort -- only
 * ever called from an actual actor's own thread, see write_datum/
 * bi_node_address) if `sys` was never given to start-node at all. */
static char *node_address_uri(ActorSystem *sys, const char *id, int id_len) {
  int n;
  char *buf;
  if (sys->tcp_host) {
    n = snprintf(NULL, 0, "tcp://%.*s@%s:%d", id_len, id, sys->tcp_host, sys->tcp_port);
    buf = GC_MALLOC((size_t)(n + 1));
    snprintf(buf, (size_t)(n + 1), "tcp://%.*s@%s:%d", id_len, id, sys->tcp_host, sys->tcp_port);
  } else if (sys->unix_path) {
    n = snprintf(NULL, 0, "unix://%.*s@%s", id_len, id, sys->unix_path);
    buf = GC_MALLOC((size_t)(n + 1));
    snprintf(buf, (size_t)(n + 1), "unix://%.*s@%s", id_len, id, sys->unix_path);
  } else if (sys->node_name) {
    n = snprintf(NULL, 0, "local://%.*s@%.*s", id_len, id, sys->node_name_len, sys->node_name);
    buf = GC_MALLOC((size_t)(n + 1));
    snprintf(buf, (size_t)(n + 1), "local://%.*s@%.*s", id_len, id, sys->node_name_len, sys->node_name);
  } else {
    creme_abort("actor: start-node has not been called");
  }
  return buf;
}

/* Parses `<scheme>://<id>@<address>` (actor.cr's own URI grammar exactly
 * -- see this project's own header comment) and builds the matching
 * ActorRef Value: for tcp:/unix:, a genuine remote ref (see ActorRef's
 * own comment); for local:, EAGERLY resolved to a direct ActorContext*
 * by looking the named node up in g_local_nodes and the id up in that
 * node's own registry -- icecreme never needs a "remote-shaped" ref for
 * 'local (see ActorRef's comment on why). `decode_ctx`, if non-NULL, is
 * the PReader currently unwinding a just-received wire message -- errors
 * then go through preader_fail (safe from a network I/O thread with no
 * VM of its own) instead of creme_abort (only safe from an actual actor's
 * own thread, e.g. remote-ref's builtin call site, decode_ctx == NULL). */
static Value make_ref_from_uri(const char *uri, int len, const char *who, PReader *decode_ctx);

/* <down> record type -- built via icecreme's existing RecordType/SchemeRecord
 * machinery (value.h), lazily and thread-safely, mirroring native's own
 * DOWN_TYPE (actor.cr:300) exactly: fields ["ref", "reason"]. */
static pthread_mutex_t g_down_type_mutex = PTHREAD_MUTEX_INITIALIZER;
static RecordType *g_down_type = NULL;

static RecordType *get_down_type(void) {
  pthread_mutex_lock(&g_down_type_mutex);
  if (!g_down_type) {
    RecordType *rt = GC_MALLOC(sizeof(RecordType));
    rt->name = v_sym("<down>", 6);
    rt->field_names = GC_MALLOC(sizeof(Value) * 2);
    rt->field_names[0] = v_sym("ref", 3);
    rt->field_names[1] = v_sym("reason", 6);
    rt->n_fields = 2;
    g_down_type = rt;
  }
  pthread_mutex_unlock(&g_down_type_mutex);
  return g_down_type;
}

/* Resolves monitor/register!'s own target argument: a registered name
 * (symbol or string) or a LOCAL actor-ref box -- both, like native's own
 * monitor/register!, reject a genuinely remote (Phase 4 TCP/Unix) ref
 * outright (matching native's "cannot monitor/register a remote actor
 * reference", actor.cr:387/397), since neither operation makes sense
 * without a real local mailbox/registry entry to act on. A NAME is
 * resolved within the CALLING actor's own current system (names are
 * per-node, matching native's own per-ActorSystem namespacing --
 * whereis/register! never see another node's names, only an explicit
 * ref crosses that boundary). A REF always carries its own absolute
 * ActorContext* directly when local, valid regardless of which system
 * it was minted in (see ActorRef's own comment), so no system lookup is
 * needed for that branch at all. Aborts (matching native's own
 * "error on unknown name"/similar) rather than returning NULL. send!'s
 * own target resolution is separate (see bi_send_bang) since send! (
 * unlike monitor/register!) DOES support a remote ref. */
static ActorContext *resolve_target(VM *vm, Value v, const char *who) {
  if (v.tag == T_SYM || v.tag == T_STR) {
    ActorSystem *sys = ensure_context(vm)->system;
    pthread_mutex_lock(&sys->mutex);
    char *id = find_id_by_name_locked(sys, v.as.chars, v.aux);
    ActorContext *ctx = id ? find_context_by_id_locked(sys, id) : NULL;
    pthread_mutex_unlock(&sys->mutex);
    if (!ctx) creme_abort("%s: unknown actor name", who);
    return ctx;
  }
  if (v.tag == T_BOX && v.aux == BOX_KIND_ACTOR_REF) {
    ActorRef *ref = v.as.ptr;
    if (ref->local_ctx) return ref->local_ctx;
    creme_abort("%s: cannot %s a remote actor reference", who, who);
  }
  creme_abort("%s: expected an actor name or ref", who);
}

/* Notifies every monitor watching `ctx` with a <down> message carrying
 * ctx's own ref and `reason` (#f for a clean exit, a T_STR for an
 * error). Collects the watcher list under the registry lock, then sends
 * to each mailbox AFTER releasing it -- mailbox_send can block on a full
 * mailbox, and blocking while holding g_registry_mutex would risk
 * stalling every other actor's spawn/register!/monitor/exit against a
 * single slow watcher. Capped at 64 monitors per actor -- a generous,
 * deliberately bounded prototype limit, not unbounded growth. */
static void notify_down(ActorContext *ctx, Value reason) {
  RecordType *down_type = get_down_type();
  Value self_ref = v_actor_ref(ctx->id, ctx);

  ActorContext *targets[64];
  int n_targets = 0;

  ActorSystem *sys = ctx->system;
  pthread_mutex_lock(&sys->mutex);
  for (MonitorEntry *m = sys->monitors; m; m = m->next) {
    if (strcmp(m->target_id, ctx->id) == 0) {
      ActorContext *watcher = find_context_by_id_locked(sys, m->watcher_id);
      if (watcher && n_targets < 64) targets[n_targets++] = watcher;
    }
  }
  pthread_mutex_unlock(&sys->mutex);

  for (int i = 0; i < n_targets; i++) {
    SchemeRecord *rec = GC_MALLOC(sizeof(SchemeRecord));
    rec->type = down_type;
    rec->fields = GC_MALLOC(sizeof(Value) * 2);
    rec->fields[0] = self_ref;
    rec->fields[1] = reason;
    mailbox_send(&targets[i]->mailbox, v_record(rec));
  }
}

/* Removes `ctx` from every registry list (g_actors, any name pointing at
 * it, any monitor entry mentioning it either as watcher or target) --
 * cleanup so a long-running program spawning/retiring many actors
 * doesn't grow these lists unboundedly. Does NOT free ctx/its VM/its
 * mailbox's mutex+condvars (GC-managed, and destroying a pthread
 * mutex/condvar a blocked waiter might still reference would be its own
 * hazard) -- a deliberate, documented small leak per dead actor,
 * matching this project's existing "prototype, don't over-engineer"
 * convention. */
static void unregister_actor(ActorContext *ctx) {
  ActorSystem *sys = ctx->system;
  pthread_mutex_lock(&sys->mutex);

  ActorContext **pp = &sys->actors;
  while (*pp) {
    if (*pp == ctx) *pp = (*pp)->next;
    else pp = &(*pp)->next;
  }

  NameEntry **np = &sys->names;
  while (*np) {
    if (strcmp((*np)->id, ctx->id) == 0) *np = (*np)->next;
    else np = &(*np)->next;
  }

  MonitorEntry **mp = &sys->monitors;
  while (*mp) {
    if (strcmp((*mp)->watcher_id, ctx->id) == 0 || strcmp((*mp)->target_id, ctx->id) == 0) *mp = (*mp)->next;
    else mp = &(*mp)->next;
  }

  pthread_mutex_unlock(&sys->mutex);
}

typedef struct {
  ActorContext *ctx;
  Value thunk;
} SpawnArgs;

static void *actor_thread_main(void *arg) {
  SpawnArgs *sa = arg;
  ActorContext *ctx = sa->ctx;
  Value thunk = sa->thunk;

  struct GC_stack_base sb;
  GC_get_stack_base(&sb);
  GC_register_my_thread(&sb);

  creme_set_current_vm(ctx->vm);
  g_current_actor = ctx;
  ctx->vm->has_actor_unwind = 1;

  /* Matches native's own spawn exactly (actor.cr:339): a clean exit's
   * reason is the SYMBOL 'normal, not #f -- only an error exit's reason
   * is a string. */
  Value reason = v_sym("normal", 6);
  if (setjmp(ctx->vm->actor_unwind) == 0) {
    creme_apply(ctx->vm, thunk, NULL, 0);
  } else {
    /* abort_message lives inside ctx->vm's own GC_MALLOC'd allocation --
     * sharing this pointer directly as the T_STR's own backing bytes
     * (rather than copying) is safe under Boehm GC's conservative,
     * interior-pointer-aware collection: as long as this Value is
     * reachable, the WHOLE containing vm block (abort_message included)
     * is kept alive, exactly like any other interior pointer into a
     * GC_MALLOC'd struct. */
    reason = v_str(ctx->vm->abort_message, (int)strlen(ctx->vm->abort_message));
  }

  notify_down(ctx, reason);
  unregister_actor(ctx);
  /* Deliberately no GC_unregister_my_thread() -- see this file's own
   * header comment. */
  return NULL;
}

static Value bi_spawn(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "spawn");
  VM *child_vm = creme_new_child_vm(vm);
  /* A spawned actor inherits the SPAWNING actor's own current system --
   * mirrors native's `child.actor_system = system` (actor.cr). */
  ActorContext *ctx = new_actor_context(child_vm, ensure_context(vm)->system);

  SpawnArgs *sa = GC_MALLOC(sizeof(SpawnArgs));
  sa->ctx = ctx;
  sa->thunk = args[0];

  pthread_t tid;
  if (pthread_create(&tid, NULL, actor_thread_main, sa) != 0) creme_abort("spawn: failed to create a thread");
  ctx->thread = tid;

  return v_actor_ref(ctx->id, ctx);
}

/* ===========================================================================
 * Phase 4: TCP/Unix transport -- wire (de)serialization, HMAC-SHA256
 * handshake, framing, and connection lifecycle. See this file's own
 * header comment and the project's own planning doc for the one
 * deliberate scope decision here: this is a MINIMAL native datum reader/
 * writer covering exactly what an actor message needs (numbers, strings,
 * symbols, chars, booleans, nil, pairs, vectors, records, actor refs),
 * matching native's own wire SHAPE (`("@record" "<type>" field...)`,
 * `"@ref:<uri>"`) but NOT byte-identical to native's own text (native
 * reuses its full Scheme reader/write_string; icecreme has no native C-level
 * Scheme reader to reuse) -- icecreme-to-icecreme distribution works correctly,
 * exact interop with a real native Crystal node on the wire is not a
 * goal of this pass.
 * ========================================================================= */

#define NONCE_SIZE 32
enum { FRAME_HANDSHAKE = 1, FRAME_DELIVER = 2, FRAME_ERROR = 3 };

/* ---- growable output buffer + writer ------------------------------------ */

typedef struct {
  char *buf;
  size_t len, cap;
} WBuf;

static void wbuf_init(WBuf *w) {
  w->cap = 64;
  w->buf = GC_MALLOC(w->cap);
  w->len = 0;
}

static void wbuf_reserve(WBuf *w, size_t extra) {
  if (w->len + extra <= w->cap) return;
  size_t newcap = w->cap * 2;
  while (newcap < w->len + extra) newcap *= 2;
  char *nb = GC_MALLOC(newcap);
  memcpy(nb, w->buf, w->len);
  w->buf = nb;
  w->cap = newcap;
}

static void wbuf_putc(WBuf *w, char c) {
  wbuf_reserve(w, 1);
  w->buf[w->len++] = c;
}

static void wbuf_puts(WBuf *w, const char *s, size_t n) {
  wbuf_reserve(w, n);
  memcpy(w->buf + w->len, s, n);
  w->len += n;
}

static void wbuf_printf(WBuf *w, const char *fmt, ...) {
  char tmp[64];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  if (n < (int)sizeof(tmp)) {
    wbuf_puts(w, tmp, (size_t)n);
    return;
  }
  char *big = GC_MALLOC((size_t)n + 1);
  va_start(ap, fmt);
  vsnprintf(big, (size_t)n + 1, fmt, ap);
  va_end(ap);
  wbuf_puts(w, big, (size_t)n);
}

static void write_string_escaped(WBuf *w, const char *s, int len) {
  wbuf_putc(w, '"');
  for (int i = 0; i < len; i++) {
    char c = s[i];
    if (c == '"' || c == '\\') wbuf_putc(w, '\\');
    wbuf_putc(w, c);
  }
  wbuf_putc(w, '"');
}

/* Only ever called from the SENDING actor's own thread (send_remote,
 * below) -- creme_abort on an unsupported value is correct here, exactly
 * like any other actor-thread error (kills just this actor, notifies its
 * monitors -- see vm.c's own per-actor escape hatch). */
static void write_datum(WBuf *w, Value v, ActorSystem *sys) {
  switch (v.tag) {
    case T_NIL:
      wbuf_puts(w, "()", 2);
      return;
    case T_BOOL:
      wbuf_puts(w, v.as.b ? "#t" : "#f", 2);
      return;
    case T_INT:
      wbuf_printf(w, "%lld", (long long)v.as.i);
      return;
    case T_FLOAT: {
      char tmp[64];
      int n = snprintf(tmp, sizeof(tmp), "%.17g", v.as.f);
      wbuf_puts(w, tmp, (size_t)n);
      if (!strchr(tmp, '.') && !strchr(tmp, 'e') && !strchr(tmp, 'n') /* nan/inf */) wbuf_puts(w, ".0", 2);
      return;
    }
    case T_CHAR: {
      wbuf_puts(w, "#\\", 2);
      int64_t cp = v.as.i;
      if (cp >= 32 && cp < 127) {
        wbuf_putc(w, (char)cp);
      } else {
        wbuf_printf(w, "x%llx;", (long long)cp);
      }
      return;
    }
    case T_STR:
      write_string_escaped(w, v.as.chars, v.aux);
      return;
    case T_SYM:
      wbuf_puts(w, v.as.chars, (size_t)v.aux);
      return;
    case T_PAIR: {
      wbuf_putc(w, '(');
      Value cur = v;
      int first = 1;
      while (cur.tag == T_PAIR) {
        if (!first) wbuf_putc(w, ' ');
        first = 0;
        write_datum(w, cur.as.pair->car, sys);
        cur = cur.as.pair->cdr;
      }
      if (cur.tag != T_NIL) {
        wbuf_puts(w, " . ", 3);
        write_datum(w, cur, sys);
      }
      wbuf_putc(w, ')');
      return;
    }
    case T_VECTOR: {
      wbuf_puts(w, "#(", 2);
      for (int i = 0; i < v.as.vec->len; i++) {
        if (i) wbuf_putc(w, ' ');
        write_datum(w, v.as.vec->items[i], sys);
      }
      wbuf_putc(w, ')');
      return;
    }
    case T_RECORD: {
      RecordType *rt = v.as.record->type;
      wbuf_puts(w, "(\"@record\" ", 11);
      write_string_escaped(w, rt->name.as.chars, rt->name.aux);
      for (int i = 0; i < rt->n_fields; i++) {
        wbuf_putc(w, ' ');
        write_datum(w, v.as.record->fields[i], sys);
      }
      wbuf_putc(w, ')');
      return;
    }
    case T_BOX:
      if (v.aux == BOX_KIND_ACTOR_REF) {
        ActorRef *ref = v.as.ptr;
        char *uri;
        if (ref->local_ctx) {
          uri = node_address_uri(sys, ref->id, (int)strlen(ref->id));
        } else if (ref->addr_kind == ADDR_TCP) {
          int n = snprintf(NULL, 0, "tcp://%s@%s:%d", ref->id, ref->host, ref->port);
          uri = GC_MALLOC((size_t)(n + 1));
          snprintf(uri, (size_t)(n + 1), "tcp://%s@%s:%d", ref->id, ref->host, ref->port);
        } else {
          int n = snprintf(NULL, 0, "unix://%s@%s", ref->id, ref->path);
          uri = GC_MALLOC((size_t)(n + 1));
          snprintf(uri, (size_t)(n + 1), "unix://%s@%s", ref->id, ref->path);
        }
        int n2 = snprintf(NULL, 0, "@ref:%s", uri);
        char *full = GC_MALLOC((size_t)(n2 + 1));
        snprintf(full, (size_t)(n2 + 1), "@ref:%s", uri);
        write_string_escaped(w, full, n2);
        return;
      }
      creme_abort("actor: cannot send this value over the wire (unsupported box kind %d)", v.aux);
      return;
    default:
      creme_abort("actor: cannot send this value over the wire (unsupported value type)");
  }
}

static void encode_message(Value msg, ActorSystem *sys, char **out_buf, int *out_len) {
  WBuf w;
  wbuf_init(&w);
  write_datum(&w, msg, sys);
  *out_buf = w.buf;
  *out_len = (int)w.len;
}

/* ---- reader (only ever runs on a network I/O thread, never on an actual
 * actor's own VM thread -- see preader_fail's own comment on why it uses
 * its own longjmp escape instead of creme_abort) --------------------------- */

struct PReader {
  const char *s;
  int pos, len;
  VM *vm; /* for resolving an "@record" type name against */
  jmp_buf err_jb;
  char errbuf[256];
};

/* decode_message (the only caller) always runs on a bare network I/O
 * thread with no VM of its own on this call stack -- g_current_vm is
 * unset there, so creme_abort's fallback would kill the WHOLE PROCESS on a
 * single malformed inbound message (see vm.c's creme_abort: no
 * has_actor_unwind to longjmp to means it falls straight through to
 * exit(1)). This is this reader's own, entirely separate escape hatch:
 * unwinds straight back to decode_message's own setjmp, which just drops
 * the one bad message -- mirrors native's own handle_inbound
 * `rescue IO::Error | SchemeRuntimeError` (quietly drop a bad connection/
 * frame, never crash the process). */
static void preader_fail(PReader *r, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(r->errbuf, sizeof(r->errbuf), fmt, ap);
  va_end(ap);
  longjmp(r->err_jb, 1);
}

static void preader_skip_ws(PReader *r) {
  while (r->pos < r->len) {
    char c = r->s[r->pos];
    if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
    r->pos++;
  }
}

static Value read_datum(PReader *r);

static int wire_list_len(Value lst) {
  int n = 0;
  while (lst.tag == T_PAIR) {
    n++;
    lst = lst.as.pair->cdr;
  }
  return n;
}

static Value read_string(PReader *r) {
  r->pos++; /* opening quote */
  char stackbuf[256];
  char *heap = NULL;
  size_t n = 0, cap = 0;
  while (r->pos < r->len && r->s[r->pos] != '"') {
    char c = r->s[r->pos++];
    if (c == '\\' && r->pos < r->len) c = r->s[r->pos++];
    if (heap) {
      if (n >= cap) {
        size_t nc = cap * 2;
        char *nb = GC_MALLOC(nc);
        memcpy(nb, heap, n);
        heap = nb;
        cap = nc;
      }
      heap[n++] = c;
    } else if (n < sizeof(stackbuf)) {
      stackbuf[n++] = c;
    } else {
      cap = sizeof(stackbuf) * 2;
      heap = GC_MALLOC(cap);
      memcpy(heap, stackbuf, n);
      heap[n++] = c;
    }
  }
  if (r->pos >= r->len) preader_fail(r, "actor: malformed wire data (unterminated string)");
  r->pos++; /* closing quote */
  char *out;
  if (heap) {
    out = heap;
  } else {
    out = GC_MALLOC((size_t)(n > 0 ? n : 1));
    memcpy(out, stackbuf, n);
  }
  if (n >= 5 && memcmp(out, "@ref:", 5) == 0) {
    return make_ref_from_uri(out + 5, (int)n - 5, "actor", r);
  }
  return v_str(out, (int)n);
}

static Value read_list(PReader *r) {
  r->pos++; /* consume '(' */
  Value items[256];
  int n = 0;
  Value tail = v_nil();
  int has_tail = 0;
  for (;;) {
    preader_skip_ws(r);
    if (r->pos >= r->len) preader_fail(r, "actor: malformed wire data (unterminated list)");
    if (r->s[r->pos] == ')') {
      r->pos++;
      break;
    }
    if (r->s[r->pos] == '.' && r->pos + 1 < r->len && (r->s[r->pos + 1] == ' ' || r->s[r->pos + 1] == '(')) {
      r->pos++;
      preader_skip_ws(r);
      tail = read_datum(r);
      has_tail = 1;
      preader_skip_ws(r);
      if (r->pos >= r->len || r->s[r->pos] != ')') preader_fail(r, "actor: malformed wire data (bad dotted list)");
      r->pos++;
      break;
    }
    if (n >= 256) preader_fail(r, "actor: wire list too long (256-element prototype cap)");
    items[n++] = read_datum(r);
  }

  if (!has_tail && n >= 2 && items[0].tag == T_STR && items[0].aux == 7 &&
      memcmp(items[0].as.chars, "@record", 7) == 0) {
    Value type_name_v = items[1];
    if (type_name_v.tag != T_STR) preader_fail(r, "actor: malformed @record wire data (missing type name)");
    int slot = -1;
    for (int i = 0; i < r->vm->n_globals; i++) {
      const char *gn = r->vm->globals[i].name;
      if (r->vm->globals[i].bound && r->vm->globals[i].value.tag == T_RECORD_TYPE &&
          (int)strlen(gn) == type_name_v.aux && memcmp(gn, type_name_v.as.chars, (size_t)type_name_v.aux) == 0) {
        slot = i;
        break;
      }
    }
    if (slot < 0) {
      preader_fail(r, "actor: received unknown record type '%.*s' over the network", type_name_v.aux, type_name_v.as.chars);
    }
    RecordType *rt = r->vm->globals[slot].value.as.record_type;
    SchemeRecord *rec = GC_MALLOC(sizeof(SchemeRecord));
    rec->type = rt;
    int nf = n - 2;
    rec->fields = GC_MALLOC(sizeof(Value) * (size_t)(nf > 0 ? nf : 1));
    for (int i = 0; i < nf; i++) rec->fields[i] = items[2 + i];
    return v_record(rec);
  }

  Value result = has_tail ? tail : v_nil();
  for (int i = n - 1; i >= 0; i--) {
    result = creme_raw_cons(items[i], result);
  }
  return result;
}

static Value read_datum(PReader *r) {
  preader_skip_ws(r);
  if (r->pos >= r->len) preader_fail(r, "actor: malformed wire data (unexpected end)");
  char c = r->s[r->pos];
  if (c == '(') return read_list(r);
  if (c == '"') return read_string(r);
  if (c == '#') {
    if (r->pos + 1 < r->len && r->s[r->pos + 1] == '(') {
      r->pos++; /* consume '#', leave '(' for read_list */
      Value lst = read_list(r);
      int n = wire_list_len(lst);
      Vector *vec = GC_MALLOC(sizeof(Vector));
      vec->items = GC_MALLOC(sizeof(Value) * (size_t)(n > 0 ? n : 1));
      vec->len = n;
      Value cur = lst;
      for (int i = 0; i < n; i++) {
        vec->items[i] = cur.as.pair->car;
        cur = cur.as.pair->cdr;
      }
      return v_vector(vec);
    }
    if (r->pos + 1 < r->len && r->s[r->pos + 1] == 't') {
      r->pos += 2;
      return v_bool(1);
    }
    if (r->pos + 1 < r->len && r->s[r->pos + 1] == 'f') {
      r->pos += 2;
      return v_bool(0);
    }
    if (r->pos + 1 < r->len && r->s[r->pos + 1] == '\\') {
      r->pos += 2;
      if (r->pos < r->len && r->s[r->pos] == 'x') {
        int start = ++r->pos;
        while (r->pos < r->len && r->s[r->pos] != ';') r->pos++;
        long cp = strtol(r->s + start, NULL, 16);
        if (r->pos < r->len) r->pos++; /* consume ';' */
        return v_char(cp);
      }
      if (r->pos >= r->len) preader_fail(r, "actor: malformed wire data (truncated char literal)");
      char ch = r->s[r->pos++];
      return v_char((unsigned char)ch);
    }
    preader_fail(r, "actor: malformed wire data (unknown # syntax)");
  }
  int start = r->pos;
  while (r->pos < r->len && r->s[r->pos] != ' ' && r->s[r->pos] != '\t' && r->s[r->pos] != '\n' && r->s[r->pos] != '\r' &&
         r->s[r->pos] != '(' && r->s[r->pos] != ')') {
    r->pos++;
  }
  int tok_len = r->pos - start;
  const char *tok = r->s + start;
  if (tok_len == 0) preader_fail(r, "actor: malformed wire data (empty token)");
  char *end;
  long long iv = strtoll(tok, &end, 10);
  if (end == tok + tok_len) return v_int(iv);
  double dv = strtod(tok, &end);
  if (end == tok + tok_len) return v_float(dv);
  return v_sym(dupn(tok, tok_len), tok_len);
}

/* Returns 0 (and drops the message) on any malformed wire data --
 * always called from handle_inbound, a bare network I/O thread, never
 * from an actor's own VM thread. */
static int decode_message(const char *text, int text_len, VM *vm, Value *out) {
  PReader r;
  r.s = text;
  r.pos = 0;
  r.len = text_len;
  r.vm = vm;
  if (setjmp(r.err_jb) != 0) return 0;
  *out = read_datum(&r);
  return 1;
}

static Value make_ref_from_uri(const char *uri, int len, const char *who, PReader *decode_ctx) {
#define URI_FAIL(...)                                            \
  do {                                                            \
    if (decode_ctx) preader_fail(decode_ctx, __VA_ARGS__);         \
    else creme_abort(__VA_ARGS__);                                  \
    return v_nil(); /* unreached */                                \
  } while (0)

  const char *colon = memchr(uri, ':', (size_t)len);
  if (!colon || colon + 2 >= uri + len || colon[1] != '/' || colon[2] != '/') URI_FAIL("%s: malformed actor URI", who);
  int scheme_len = (int)(colon - uri);
  const char *rest = colon + 3;
  int rest_len = len - (int)(rest - uri);
  const char *at = memchr(rest, '@', (size_t)rest_len);
  if (!at) URI_FAIL("%s: malformed actor URI", who);
  int id_len = (int)(at - rest);
  char *id = dupn(rest, id_len);
  const char *addr = at + 1;
  int addr_len = rest_len - (int)(addr - rest);

  if (scheme_len == 3 && memcmp(uri, "tcp", 3) == 0) {
    int ci = -1;
    for (int i = addr_len - 1; i >= 0; i--) {
      if (addr[i] == ':') {
        ci = i;
        break;
      }
    }
    if (ci < 0) URI_FAIL("%s: malformed tcp actor URI (missing port)", who);
    char *host = dupn(addr, ci);
    char portbuf[16];
    int plen = addr_len - ci - 1;
    if (plen <= 0 || plen >= (int)sizeof(portbuf)) URI_FAIL("%s: malformed tcp actor URI (bad port)", who);
    memcpy(portbuf, addr + ci + 1, (size_t)plen);
    portbuf[plen] = '\0';
    return v_actor_ref_tcp(id, host, atoi(portbuf));
  }
  if (scheme_len == 4 && memcmp(uri, "unix", 4) == 0) {
    char *path = dupn(addr, addr_len);
    return v_actor_ref_unix(id, path);
  }
  if (scheme_len == 5 && memcmp(uri, "local", 5) == 0) {
    pthread_mutex_lock(&g_node_registry_mutex);
    ActorSystem *target = NULL;
    for (ActorSystem *s = g_local_nodes; s; s = s->next) {
      if (s->node_name_len == addr_len && memcmp(s->node_name, addr, (size_t)addr_len) == 0) {
        target = s;
        break;
      }
    }
    pthread_mutex_unlock(&g_node_registry_mutex);
    if (!target) URI_FAIL("%s: no local node registered as '%.*s'", who, addr_len, addr);
    pthread_mutex_lock(&target->mutex);
    ActorContext *ctx = find_context_by_id_locked(target, id);
    pthread_mutex_unlock(&target->mutex);
    if (!ctx) URI_FAIL("%s: no such local actor '%s' on node '%.*s'", who, id, addr_len, addr);
    return v_actor_ref(id, ctx);
  }
  URI_FAIL("%s: unknown actor URI scheme (expected tcp/unix/local)", who);
#undef URI_FAIL
}

/* ---- HMAC-SHA256 handshake + frame I/O ----------------------------------- */

static void hmac_sha256(const char *key, int key_len, const unsigned char *data, int data_len, unsigned char out[32]) {
  unsigned int outlen = 0;
  HMAC(EVP_sha256(), key, key_len, data, (size_t)data_len, out, &outlen);
}

static int const_time_eq(const unsigned char *a, const unsigned char *b, int n) {
  unsigned char r = 0;
  for (int i = 0; i < n; i++) r |= (unsigned char)(a[i] ^ b[i]);
  return r == 0;
}

static int write_all(int fd, const void *buf, size_t n) {
  const char *p = buf;
  size_t left = n;
  while (left > 0) {
    ssize_t w = write(fd, p, left);
    if (w < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (w == 0) return -1;
    p += w;
    left -= (size_t)w;
  }
  return 0;
}

static int read_all(int fd, void *buf, size_t n) {
  char *p = buf;
  size_t left = n;
  while (left > 0) {
    ssize_t r = read(fd, p, left);
    if (r < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (r == 0) return -1; /* peer closed */
    p += r;
    left -= (size_t)r;
  }
  return 0;
}

static int write_frame_fd(int fd, uint8_t type, const unsigned char *body, uint32_t body_len) {
  unsigned char hdr[5];
  hdr[0] = type;
  hdr[1] = (unsigned char)(body_len >> 24);
  hdr[2] = (unsigned char)(body_len >> 16);
  hdr[3] = (unsigned char)(body_len >> 8);
  hdr[4] = (unsigned char)(body_len);
  if (write_all(fd, hdr, sizeof(hdr)) != 0) return -1;
  if (body_len > 0 && write_all(fd, body, body_len) != 0) return -1;
  return 0;
}

static int read_frame_fd(int fd, uint8_t *type, unsigned char **body, uint32_t *body_len) {
  unsigned char hdr[5];
  if (read_all(fd, hdr, sizeof(hdr)) != 0) return -1;
  *type = hdr[0];
  uint32_t len = ((uint32_t)hdr[1] << 24) | ((uint32_t)hdr[2] << 16) | ((uint32_t)hdr[3] << 8) | (uint32_t)hdr[4];
  unsigned char *buf = len > 0 ? GC_MALLOC(len) : NULL;
  if (len > 0 && read_all(fd, buf, len) != 0) return -1;
  *body = buf;
  *body_len = len;
  return 0;
}

static int handshake_initiate(int fd, const char *cookie, int cookie_len) {
  unsigned char nonce[NONCE_SIZE];
  RAND_bytes(nonce, NONCE_SIZE);
  unsigned char mac[32];
  hmac_sha256(cookie, cookie_len, nonce, NONCE_SIZE, mac);
  unsigned char body[NONCE_SIZE * 2];
  memcpy(body, nonce, NONCE_SIZE);
  memcpy(body + NONCE_SIZE, mac, 32);
  if (write_frame_fd(fd, FRAME_HANDSHAKE, body, sizeof(body)) != 0) return -1;

  uint8_t type;
  unsigned char *rbody;
  uint32_t rlen;
  if (read_frame_fd(fd, &type, &rbody, &rlen) != 0) return -1;
  if (type != FRAME_HANDSHAKE || rlen != NONCE_SIZE * 2) return -1;
  unsigned char *resp_nonce = rbody, *resp_hmac = rbody + NONCE_SIZE;
  unsigned char combined[NONCE_SIZE * 2];
  memcpy(combined, nonce, NONCE_SIZE);
  memcpy(combined + NONCE_SIZE, resp_nonce, NONCE_SIZE);
  unsigned char expected[32];
  hmac_sha256(cookie, cookie_len, combined, NONCE_SIZE * 2, expected);
  if (!const_time_eq(resp_hmac, expected, 32)) return -1;
  return 0;
}

static int handshake_respond(int fd, const char *cookie, int cookie_len) {
  uint8_t type;
  unsigned char *body;
  uint32_t len;
  if (read_frame_fd(fd, &type, &body, &len) != 0) return -1;
  if (type != FRAME_HANDSHAKE || len != NONCE_SIZE * 2) return -1;
  unsigned char *init_nonce = body, *init_hmac = body + NONCE_SIZE;
  unsigned char expected[32];
  hmac_sha256(cookie, cookie_len, init_nonce, NONCE_SIZE, expected);
  if (!const_time_eq(init_hmac, expected, 32)) {
    write_frame_fd(fd, FRAME_ERROR, (const unsigned char *)"authentication failed", 21);
    return -1;
  }
  unsigned char resp_nonce[NONCE_SIZE];
  RAND_bytes(resp_nonce, NONCE_SIZE);
  unsigned char combined[NONCE_SIZE * 2];
  memcpy(combined, init_nonce, NONCE_SIZE);
  memcpy(combined + NONCE_SIZE, resp_nonce, NONCE_SIZE);
  unsigned char resp_hmac[32];
  hmac_sha256(cookie, cookie_len, combined, NONCE_SIZE * 2, resp_hmac);
  unsigned char resp_body[NONCE_SIZE * 2];
  memcpy(resp_body, resp_nonce, NONCE_SIZE);
  memcpy(resp_body + NONCE_SIZE, resp_hmac, 32);
  if (write_frame_fd(fd, FRAME_HANDSHAKE, resp_body, sizeof(resp_body)) != 0) return -1;
  return 0;
}

static unsigned char *build_deliver_body(const char *to, int to_len, const char *payload, int payload_len, uint32_t *out_len) {
  uint32_t total = (uint32_t)(2 + to_len + payload_len);
  unsigned char *buf = GC_MALLOC(total);
  buf[0] = (unsigned char)(to_len >> 8);
  buf[1] = (unsigned char)(to_len);
  memcpy(buf + 2, to, (size_t)to_len);
  memcpy(buf + 2 + to_len, payload, (size_t)payload_len);
  *out_len = total;
  return buf;
}

static int parse_deliver_body(const unsigned char *body, uint32_t body_len, const char **to, int *to_len, const char **payload, int *payload_len) {
  if (body_len < 2) return -1;
  int tl = ((int)body[0] << 8) | (int)body[1];
  if ((uint32_t)(2 + tl) > body_len) return -1;
  *to = (const char *)(body + 2);
  *to_len = tl;
  *payload = (const char *)(body + 2 + tl);
  *payload_len = (int)(body_len - 2 - (uint32_t)tl);
  return 0;
}

/* ---- connection lifecycle ------------------------------------------------ */

static Connection *find_connection_locked(ActorSystem *sys, const char *key, int key_len) {
  for (Connection *c = sys->connections; c; c = c->next) {
    if ((int)strlen(c->key) == key_len && memcmp(c->key, key, (size_t)key_len) == 0) return c;
  }
  return NULL;
}

/* Connects + handshakes a brand new outbound socket -- always called
 * from an actual actor's own thread (send_remote), so creme_abort on
 * failure is correct here (kills just this actor). */
static Connection *dial(ActorSystem *sys, int addr_kind, const char *host, int port, const char *path) {
  if (!sys->cookie) creme_abort("send!: start-node must be called before contacting a remote actor");
  int fd;
  if (addr_kind == ADDR_TCP) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    struct addrinfo *res;
    char portbuf[16];
    snprintf(portbuf, sizeof(portbuf), "%d", port);
    if (getaddrinfo(host, portbuf, &hints, &res) != 0) creme_abort("send!: could not resolve host '%s'", host);
    fd = -1;
    for (struct addrinfo *rp = res; rp; rp = rp->ai_next) {
      fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
      if (fd < 0) continue;
      if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
      close(fd);
      fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) creme_abort("send!: connection to %s:%d failed", host, port);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  } else {
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) creme_abort("send!: could not create a unix socket");
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
      close(fd);
      creme_abort("send!: connection to unix socket '%s' failed", path);
    }
  }
  if (handshake_initiate(fd, sys->cookie, sys->cookie_len) != 0) {
    close(fd);
    creme_abort("send!: handshake failed or was rejected");
  }
  Connection *conn = GC_MALLOC(sizeof(Connection));
  pthread_mutex_init(&conn->write_mutex, NULL);
  conn->fd = fd;
  conn->key = NULL;
  conn->next = NULL;
  return conn;
}

/* Dials OUTSIDE sys->mutex -- connect()/handshake can block for a while,
 * and holding the lock across that would stall every other actor on
 * this node touching the registry for no reason. A harmless race is
 * possible (two actors both dial the same never-yet-cached peer
 * concurrently) -- resolved by re-checking the cache once the new
 * connection is ready and discarding the loser, matching native's own
 * `@connections[key] ||= yield` (also not atomic across the dial
 * itself, same race, same resolution). */
static Connection *connection_for(ActorSystem *sys, const char *key, int key_len, int addr_kind, const char *host, int port, const char *path) {
  pthread_mutex_lock(&sys->mutex);
  Connection *existing = find_connection_locked(sys, key, key_len);
  pthread_mutex_unlock(&sys->mutex);
  if (existing) return existing;

  Connection *fresh = dial(sys, addr_kind, host, port, path);
  fresh->key = dupn(key, key_len);

  pthread_mutex_lock(&sys->mutex);
  existing = find_connection_locked(sys, key, key_len);
  if (existing) {
    pthread_mutex_unlock(&sys->mutex);
    close(fresh->fd);
    return existing;
  }
  fresh->next = sys->connections;
  sys->connections = fresh;
  pthread_mutex_unlock(&sys->mutex);
  return fresh;
}

static void send_remote(ActorSystem *sys, ActorRef *ref, Value msg) {
  char *payload;
  int payload_len;
  encode_message(msg, sys, &payload, &payload_len);

  uint32_t body_len;
  unsigned char *body = build_deliver_body(ref->id, (int)strlen(ref->id), payload, payload_len, &body_len);

  char key[512];
  Connection *conn;
  if (ref->addr_kind == ADDR_TCP) {
    snprintf(key, sizeof(key), "tcp:%s:%d", ref->host, ref->port);
    conn = connection_for(sys, key, (int)strlen(key), ADDR_TCP, ref->host, ref->port, NULL);
  } else {
    snprintf(key, sizeof(key), "unix:%s", ref->path);
    conn = connection_for(sys, key, (int)strlen(key), ADDR_UNIX, NULL, 0, ref->path);
  }

  pthread_mutex_lock(&conn->write_mutex);
  int rc = write_frame_fd(conn->fd, FRAME_DELIVER, body, body_len);
  pthread_mutex_unlock(&conn->write_mutex);
  if (rc != 0) creme_abort("send!: connection to %s failed", ref->id);
}

/* ---- inbound: one pthread per accepted connection ------------------------ */

typedef struct {
  int fd;
  ActorSystem *sys;
} InboundArgs;

static void *handle_inbound_main(void *arg) {
  InboundArgs *ia = arg;
  int fd = ia->fd;
  ActorSystem *sys = ia->sys;

  struct GC_stack_base sb;
  GC_get_stack_base(&sb);
  GC_register_my_thread(&sb);

  if (handshake_respond(fd, sys->cookie, sys->cookie_len) != 0) {
    close(fd);
    return NULL;
  }

  for (;;) {
    uint8_t type;
    unsigned char *body;
    uint32_t body_len;
    if (read_frame_fd(fd, &type, &body, &body_len) != 0) break;
    if (type != FRAME_DELIVER) continue;

    const char *to, *payload;
    int to_len, payload_len;
    if (parse_deliver_body(body, body_len, &to, &to_len, &payload, &payload_len) != 0) continue;

    Value msg;
    if (!decode_message(payload, payload_len, sys->creator_vm, &msg)) continue; /* malformed -- drop quietly */

    /* deliver_local's own by-id-then-by-name fallback (actor.cr:256-261). */
    char *to_copy = dupn(to, to_len);
    pthread_mutex_lock(&sys->mutex);
    ActorContext *target = find_context_by_id_locked(sys, to_copy);
    if (!target) {
      char *id = find_id_by_name_locked(sys, to_copy, to_len);
      if (id) target = find_context_by_id_locked(sys, id);
    }
    pthread_mutex_unlock(&sys->mutex);
    if (target) mailbox_send(&target->mailbox, msg);
  }

  close(fd);
  return NULL;
}

typedef struct {
  int listener_fd;
  ActorSystem *sys;
} AcceptArgs;

static void *accept_loop_main(void *arg) {
  AcceptArgs *aa = arg;
  int listener_fd = aa->listener_fd;
  ActorSystem *sys = aa->sys;

  struct GC_stack_base sb;
  GC_get_stack_base(&sb);
  GC_register_my_thread(&sb);

  for (;;) {
    int fd = accept(listener_fd, NULL, NULL);
    if (fd < 0) {
      if (errno == EINTR) continue;
      break; /* listener closed (stop-node!) or a real error -- either way, stop accepting */
    }
    InboundArgs *ia = GC_MALLOC(sizeof(InboundArgs));
    ia->fd = fd;
    ia->sys = sys;
    pthread_t tid;
    if (pthread_create(&tid, NULL, handle_inbound_main, ia) != 0) {
      close(fd);
      continue;
    }
    pthread_detach(tid);
  }
  return NULL;
}

static Value bi_send_bang(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "send!");
  Value target = args[0];
  if (target.tag == T_SYM || target.tag == T_STR) {
    ActorContext *ctx = resolve_target(vm, target, "send!");
    mailbox_send(&ctx->mailbox, args[1]);
    return v_nil();
  }
  if (target.tag == T_BOX && target.aux == BOX_KIND_ACTOR_REF) {
    ActorRef *ref = target.as.ptr;
    if (ref->local_ctx) {
      mailbox_send(&ref->local_ctx->mailbox, args[1]);
    } else {
      send_remote(ensure_context(vm)->system, ref, args[1]);
    }
    return v_nil();
  }
  creme_abort("send!: expected an actor reference or registered name");
}

static Value bi_receive_bang(VM *vm, Value *args, int nargs) {
  (void)args;
  (void)nargs;
  ActorContext *ctx = ensure_context(vm);
  return mailbox_receive(&ctx->mailbox);
}

static Value bi_self(VM *vm, Value *args, int nargs) {
  (void)args;
  (void)nargs;
  ActorContext *ctx = ensure_context(vm);
  return v_actor_ref(ctx->id, ctx);
}

static Value bi_monitor(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "monitor");
  ActorContext *watcher = ensure_context(vm);
  ActorContext *target = resolve_target(vm, args[0], "monitor");

  MonitorEntry *me = GC_MALLOC(sizeof(MonitorEntry));
  me->watcher_id = watcher->id;
  me->target_id = target->id;

  /* Stored in the TARGET's own system -- notify_down only ever looks in
   * ctx->system's own monitor list when that actor exits, so a
   * cross-system monitor (watcher in one 'local node, target in
   * another) must be filed there, not in the watcher's system. */
  ActorSystem *sys = target->system;
  pthread_mutex_lock(&sys->mutex);
  me->next = sys->monitors;
  sys->monitors = me;
  pthread_mutex_unlock(&sys->mutex);
  return v_nil();
}

static Value bi_register_bang(VM *vm, Value *args, int nargs) {
  if (nargs < 2 || (args[0].tag != T_SYM && args[0].tag != T_STR) || args[1].tag != T_BOX || args[1].aux != BOX_KIND_ACTOR_REF) {
    creme_abort("register!: expected (name ref)");
  }
  ActorRef *ref = args[1].as.ptr;

  NameEntry *ne = GC_MALLOC(sizeof(NameEntry));
  ne->name = GC_MALLOC((size_t)(args[0].aux ? args[0].aux : 1));
  memcpy(ne->name, args[0].as.chars, (size_t)args[0].aux);
  ne->name_len = args[0].aux;
  ne->id = ref->id;

  /* register!/whereis are per-system -- a name registered in one 'local
   * node is invisible to whereis in another, matching native's own
   * per-ActorSystem namespacing. Filed in the CALLING actor's own
   * current system (the same system register!'s target actually lives
   * in, in every normal usage). */
  ActorSystem *sys = ensure_context(vm)->system;
  pthread_mutex_lock(&sys->mutex);
  /* Replaces any existing entry for this name outright -- re-
   * registering a name is allowed, matching a supervisor's own
   * restart-and-re-register pattern; the OLD entry (if any) is simply
   * unlinked. */
  NameEntry **pp = &sys->names;
  while (*pp) {
    if ((*pp)->name_len == ne->name_len && memcmp((*pp)->name, ne->name, (size_t)ne->name_len) == 0) *pp = (*pp)->next;
    else pp = &(*pp)->next;
  }
  ne->next = sys->names;
  sys->names = ne;
  pthread_mutex_unlock(&sys->mutex);
  return v_nil();
}

static Value bi_whereis(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || (args[0].tag != T_SYM && args[0].tag != T_STR)) creme_abort("whereis: expected a name");
  ActorSystem *sys = ensure_context(vm)->system;
  pthread_mutex_lock(&sys->mutex);
  char *id = find_id_by_name_locked(sys, args[0].as.chars, args[0].aux);
  ActorContext *ctx = id ? find_context_by_id_locked(sys, id) : NULL;
  pthread_mutex_unlock(&sys->mutex);
  return ctx ? v_actor_ref(ctx->id, ctx) : v_bool(0);
}

static Value bi_actor_ref_id(VM *vm, Value *args, int nargs) {
  (void)vm;
  ActorRef *ref = creme_arg_box(args, nargs, 0, BOX_KIND_ACTOR_REF, "actor-ref-id");
  return v_str(ref->id, (int)strlen(ref->id));
}

static ActorSystem *alloc_actor_system(void) {
  ActorSystem *sys = GC_MALLOC(sizeof(ActorSystem));
  pthread_mutex_init(&sys->mutex, NULL);
  sys->actors = NULL;
  sys->names = NULL;
  sys->monitors = NULL;
  sys->next_actor_id = 1;
  sys->node_name = NULL;
  sys->node_name_len = 0;
  sys->next = NULL;
  sys->cookie = NULL;
  sys->cookie_len = 0;
  sys->tcp_host = NULL;
  sys->tcp_port = -1;
  sys->unix_path = NULL;
  sys->listener_fd = -1;
  sys->connections = NULL;
  sys->creator_vm = NULL;
  return sys;
}

static void start_tcp_node(ActorSystem *sys, const char *host, int host_len, int port, const char *cookie, int cookie_len) {
  sys->tcp_host = dupn(host, host_len);
  sys->cookie = dupn(cookie, cookie_len);
  sys->cookie_len = cookie_len;

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;
  hints.ai_flags = AI_PASSIVE;
  struct addrinfo *res;
  char portbuf[16];
  snprintf(portbuf, sizeof(portbuf), "%d", port);
  if (getaddrinfo(host_len > 0 ? sys->tcp_host : NULL, portbuf, &hints, &res) != 0) {
    creme_abort("start-node: could not resolve host '%s'", sys->tcp_host);
  }
  int fd = -1;
  for (struct addrinfo *rp = res; rp; rp = rp->ai_next) {
    fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (fd < 0) continue;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0) creme_abort("start-node: could not bind %s:%d", sys->tcp_host, port);
  if (listen(fd, 64) != 0) {
    close(fd);
    creme_abort("start-node: listen failed");
  }

  struct sockaddr_storage actual;
  socklen_t alen = sizeof(actual);
  if (getsockname(fd, (struct sockaddr *)&actual, &alen) == 0) {
    if (actual.ss_family == AF_INET) port = ntohs(((struct sockaddr_in *)&actual)->sin_port);
    else if (actual.ss_family == AF_INET6) port = ntohs(((struct sockaddr_in6 *)&actual)->sin6_port);
  }
  sys->tcp_port = port;
  sys->listener_fd = fd;

  AcceptArgs *aa = GC_MALLOC(sizeof(AcceptArgs));
  aa->listener_fd = fd;
  aa->sys = sys;
  if (pthread_create(&sys->accept_thread, NULL, accept_loop_main, aa) != 0) creme_abort("start-node: failed to start the accept thread");
  pthread_detach(sys->accept_thread);
}

static void start_unix_node(ActorSystem *sys, const char *path, int path_len, const char *cookie, int cookie_len) {
  sys->unix_path = dupn(path, path_len);
  sys->cookie = dupn(cookie, cookie_len);
  sys->cookie_len = cookie_len;

  unlink(sys->unix_path); /* drop a stale socket file from a prior crashed run */
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) creme_abort("start-node: could not create a unix socket");
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, sys->unix_path, sizeof(addr.sun_path) - 1);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(fd);
    creme_abort("start-node: could not bind unix socket '%s'", sys->unix_path);
  }
  if (listen(fd, 64) != 0) {
    close(fd);
    creme_abort("start-node: listen failed");
  }
  sys->listener_fd = fd;

  AcceptArgs *aa = GC_MALLOC(sizeof(AcceptArgs));
  aa->listener_fd = fd;
  aa->sys = sys;
  if (pthread_create(&sys->accept_thread, NULL, accept_loop_main, aa) != 0) creme_abort("start-node: failed to start the accept thread");
  pthread_detach(sys->accept_thread);
}

/* start-node: (start-node 'tcp host port cookie), (start-node 'unix path
 * cookie), (start-node 'local name cookie), or the legacy untagged
 * (start-node host port cookie) == 'tcp (kept working forever for
 * backward compatibility, matching native exactly -- actor.cr's own
 * comment). Allocates a brand new ActorSystem and reassigns the CALLING
 * thread's own current ActorContext to it (mirroring native's own
 * `current_interp.actor_system = system`) so any FUTURE spawn() from
 * this same thread lands its children in the new system too. */
static Value bi_start_node(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 3, "start-node");
  ActorSystem *sys = alloc_actor_system();
  sys->creator_vm = vm;

  if (args[0].tag == T_SYM) {
    int tlen = args[0].aux;
    const char *tag = args[0].as.chars;
    if (tlen == 3 && memcmp(tag, "tcp", 3) == 0) {
      if (nargs < 4 || args[1].tag != T_STR || args[2].tag != T_INT || args[3].tag != T_STR) {
        creme_abort("start-node: 'tcp expects (host port cookie)");
      }
      start_tcp_node(sys, args[1].as.chars, args[1].aux, (int)args[2].as.i, args[3].as.chars, args[3].aux);
    } else if (tlen == 4 && memcmp(tag, "unix", 4) == 0) {
      if (nargs < 3 || args[1].tag != T_STR || args[2].tag != T_STR) creme_abort("start-node: 'unix expects (path cookie)");
      start_unix_node(sys, args[1].as.chars, args[1].aux, args[2].as.chars, args[2].aux);
    } else if (tlen == 5 && memcmp(tag, "local", 5) == 0) {
      if (nargs < 3 || (args[1].tag != T_SYM && args[1].tag != T_STR) || (args[2].tag != T_SYM && args[2].tag != T_STR)) {
        creme_abort("start-node: 'local expects (name cookie)");
      }
      sys->node_name = dupn(args[1].as.chars, args[1].aux);
      sys->node_name_len = args[1].aux;
      sys->cookie = dupn(args[2].as.chars, args[2].aux);
      sys->cookie_len = args[2].aux;
      pthread_mutex_lock(&g_node_registry_mutex);
      sys->next = g_local_nodes;
      g_local_nodes = sys;
      pthread_mutex_unlock(&g_node_registry_mutex);
    } else {
      creme_abort("start-node: unknown transport '%.*s', expected 'tcp, 'unix, or 'local", tlen, tag);
    }
  } else {
    if (args[0].tag != T_STR || args[1].tag != T_INT || args[2].tag != T_STR) creme_abort("start-node: expected (host port cookie)");
    start_tcp_node(sys, args[0].as.chars, args[0].aux, (int)args[1].as.i, args[2].as.chars, args[2].aux);
  }

  move_context_to_system(ensure_context(vm), sys);
  return v_box(sys, BOX_KIND_ACTOR_NODE);
}

static ActorSystem *node_arg(Value v, const char *who) {
  if (v.tag != T_BOX || v.aux != BOX_KIND_ACTOR_NODE) creme_abort("%s: expected a node handle", who);
  return v.as.ptr;
}

/* node-name: 0 args means "the calling actor's own current node", 1 arg
 * means an explicit node handle -- matches native's own optional-arg
 * signature. */
static Value bi_node_name(VM *vm, Value *args, int nargs) {
  ActorSystem *sys = (nargs >= 1) ? node_arg(args[0], "node-name") : ensure_context(vm)->system;
  if (!sys->node_name) creme_abort("node-name: this node has no name (started as 'tcp or 'unix, or start-node has not been called)");
  return v_str(sys->node_name, sys->node_name_len);
}

static Value bi_node_port(VM *vm, Value *args, int nargs) {
  ActorSystem *sys = (nargs >= 1) ? node_arg(args[0], "node-port") : ensure_context(vm)->system;
  if (sys->tcp_port < 0) creme_abort("node-port: this node has no TCP port (started as 'unix or 'local, or start-node has not been called)");
  return v_int(sys->tcp_port);
}

static Value bi_node_path(VM *vm, Value *args, int nargs) {
  ActorSystem *sys = (nargs >= 1) ? node_arg(args[0], "node-path") : ensure_context(vm)->system;
  if (!sys->unix_path) creme_abort("node-path: this node has no socket path (started as 'tcp or 'local, or start-node has not been called)");
  return v_str(sys->unix_path, (int)strlen(sys->unix_path));
}

/* node-address: builds the dialable URI for an actor on `node`, whichever
 * transport it was started with -- accepts a raw id string, a bare symbol
 * (e.g. a name registered via (creme actor-supervisor)'s child-spec, as
 * examples/34-actor-ping-pong.scm does), or an actor-ref (its id is
 * extracted) as the second argument. Symbols and strings share the same
 * chars/aux layout in this prototype's value model (see value.h's T_SYM),
 * so no separate extraction path is needed. */
static Value bi_node_address(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "node-address");
  ActorSystem *sys = node_arg(args[0], "node-address");

  const char *id_chars;
  int id_len;
  if (args[1].tag == T_STR || args[1].tag == T_SYM) {
    id_chars = args[1].as.chars;
    id_len = args[1].aux;
  } else if (args[1].tag == T_BOX && args[1].aux == BOX_KIND_ACTOR_REF) {
    ActorRef *ref = args[1].as.ptr;
    id_chars = ref->id;
    id_len = (int)strlen(ref->id);
  } else {
    creme_abort("node-address: expected a string id or an actor ref");
  }

  char *uri = node_address_uri(sys, id_chars, id_len);
  return v_str(uri, (int)strlen(uri));
}

static Value bi_remote_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  int len;
  const char *uri = creme_arg_bytes(args, nargs, 0, "remote-ref", &len);
  return make_ref_from_uri(uri, len, "remote-ref", NULL);
}

/* stop-node!: 0 args means "the calling actor's own current node", 1 arg
 * an explicit node handle. Closes the listener (if any, for 'tcp/'unix)
 * and every cached outbound connection, then -- for 'local only --
 * unregisters from g_local_nodes; future-sent refs into it simply become
 * unreachable, matching native's own shutdown! for every transport. */
static Value bi_stop_node_bang(VM *vm, Value *args, int nargs) {
  ActorSystem *sys = (nargs >= 1) ? node_arg(args[0], "stop-node!") : ensure_context(vm)->system;

  pthread_mutex_lock(&sys->mutex);
  if (sys->listener_fd >= 0) {
    close(sys->listener_fd);
    sys->listener_fd = -1;
  }
  for (Connection *c = sys->connections; c; c = c->next) close(c->fd);
  sys->connections = NULL;
  pthread_mutex_unlock(&sys->mutex);

  if (sys->node_name) {
    pthread_mutex_lock(&g_node_registry_mutex);
    ActorSystem **pp = &g_local_nodes;
    while (*pp) {
      if (*pp == sys) *pp = (*pp)->next;
      else pp = &(*pp)->next;
    }
    pthread_mutex_unlock(&g_node_registry_mutex);
  }
  return v_nil();
}

static Value bi_down_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "down?");
  return v_bool(args[0].tag == T_RECORD && args[0].as.record->type == get_down_type());
}

static Value bi_down_ref(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_RECORD || args[0].as.record->type != get_down_type()) creme_abort("down-ref: expected a <down> record");
  return args[0].as.record->fields[0];
}

static Value bi_down_reason(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_RECORD || args[0].as.record->type != get_down_type()) creme_abort("down-reason: expected a <down> record");
  return args[0].as.record->fields[1];
}

void creme_register_actor_builtins(VM *vm) {
  creme_register_builtin(vm, "spawn", bi_spawn);
  creme_register_builtin(vm, "send!", bi_send_bang);
  creme_register_builtin(vm, "receive!", bi_receive_bang);
  creme_register_builtin(vm, "self", bi_self);
  creme_register_builtin(vm, "monitor", bi_monitor);
  creme_register_builtin(vm, "register!", bi_register_bang);
  creme_register_builtin(vm, "whereis", bi_whereis);
  creme_register_builtin(vm, "actor-ref-id", bi_actor_ref_id);
  creme_register_builtin(vm, "down?", bi_down_p);
  creme_register_builtin(vm, "down-ref", bi_down_ref);
  creme_register_builtin(vm, "down-reason", bi_down_reason);
  creme_register_builtin(vm, "start-node", bi_start_node);
  creme_register_builtin(vm, "node-name", bi_node_name);
  creme_register_builtin(vm, "node-port", bi_node_port);
  creme_register_builtin(vm, "node-path", bi_node_path);
  creme_register_builtin(vm, "node-address", bi_node_address);
  creme_register_builtin(vm, "remote-ref", bi_remote_ref);
  creme_register_builtin(vm, "stop-node!", bi_stop_node_bang);
}

#endif /* CREME_WITH_ACTOR */
