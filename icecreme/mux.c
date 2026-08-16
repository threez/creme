/* (creme mux) — see mux.h.
 *
 * Request alist: (("method" . STR) ("path" . STR) ("path-params" . ALIST)
 * ("headers" . ALIST) ("remote-addr" . STR) ("body" . STR)) — exactly
 * mux.cr's own `request_to_scheme` contract. Response alist read back:
 * (("status" . N) ("headers" . ALIST) ("body" . STR)) — mux.cr's
 * `write_response`, minus its streaming-callable-body case (never used by
 * the demo-todo app this targets).
 *
 * Backed by raw blocking sockets + picohttpparser (vendor/picohttpparser,
 * MIT/Perl dual-licensed) for HTTP/1.1 request-line/header parsing.
 *
 * Threading model: `mux-listen!` runs its OWN I/O loop on the calling
 * thread (this call blocks forever -- see mux-close! below for how it
 * ever stops), using poll(2) to multiplex reads/writes across every
 * accepted connection from that SINGLE thread -- not a thread per
 * connection (an earlier version of this file did that; see git
 * history). One poll() loop needs only one OS thread regardless of
 * connection count. A thread-per-connection model was replaced with
 * this one after benchmarking (see git history for the numbers): CPU
 * oversubscription turned out NOT to be the cost (switching to a single
 * poll() loop while keeping everything else the same measurably changed
 * nothing) -- the real cost, confirmed by that same experiment, is
 * described below.
 *
 * icecreme's own `VM` struct (see vm.h) has a single shared operand stack/
 * frame array/handler stack — it is NOT safe for two threads to call
 * creme_apply against the same VM concurrently. `mux-listen!`'s optional
 * 3rd argument, an "options" string-keyed alist (e.g. '(("pool" . 8))),
 * can carry a "pool" entry that picks how request dispatch handles that
 * (see bi_mux_listen for the full options alist, which also takes
 * "host"):
 *
 *   - `#f` (the default) -- NO pool at all: the I/O thread itself calls
 *     dispatch_request inline, against one dedicated VM (g_inline_vm),
 *     right in the poll loop. Zero extra threads, zero cross-thread
 *     handoff, but also zero parallelism: every request is fully
 *     serialized on the one I/O thread. Best choice for cheap/fast
 *     handlers, and for most of this prototype's own callers, which is
 *     why it's the default; the pool is better once individual requests
 *     do enough CPU work that real parallel dispatch across cores
 *     outweighs having more than one I/O thread at all.
 *   - `#t` or an explicit integer: a GROWABLE POOL of fully independent
 *     I/O threads, each with its OWN child VM (creme_new_child_vm — the
 *     exact mechanism actor.c's own `spawn` already uses for the
 *     identical reason) and its OWN SO_REUSEPORT listener bound to the
 *     same host:port (see bind_listener/pool_worker_loop, below, for the
 *     full design and the mutex-handoff cost an earlier fixed-pool-plus-
 *     queue version of this paid instead — on FreeBSD, over half of all
 *     sampled C-level time under load was the mutex/condvar syscall
 *     backing that queue, not app work). Each worker accepts, parses,
 *     and dispatches its own connections end to end; the KERNEL load-
 *     balances new connections across the pool's listeners, not this
 *     file. This works because a `Closure` carries only a `Chunk*` +
 *     upvalues, never a `VM*` (vm.h) — the exact same route-handler
 *     closure registered against the original VM can be `creme_apply`'d
 *     against any worker's VM without modification, identical to how a
 *     spawned actor's captured thunk runs correctly against its own
 *     copied globals table.
 *
 * Either way, dispatch gets the same `creme_set_current_vm`/
 * `has_actor_unwind`/`setjmp(vm->actor_unwind)` treatment actor.c's own
 * thread entry function gives a spawned actor (dispatch_with_recovery,
 * below): an uncaught `creme_abort` while handling one request (a route
 * handler's own bug, a malformed builtin call, ...) degrades to a
 * synthesized 500 response for just that request, instead of taking the
 * whole process down — a real robustness improvement this file's own
 * original top-level-VM-only design never had (the main script's VM
 * leaves has_actor_unwind at its zero-init default, so an uncaught abort
 * there always falls through to creme_abort's plain print+exit(1)
 * backstop).
 *
 * picohttpparser has no chunked-REQUEST-body support of its own beyond
 * phr_decode_chunked's raw dechunking primitive, and no notion of
 * keep-alive/Content-Length at all — this file supplies that: Content-
 * Length-bounded body reads, a minimal chunked-request dechunk loop
 * (forcing `Connection: close` afterward — see conn_advance's own
 * comment on why), and HTTP/1.0-vs-1.1 keep-alive defaulting.
 *
 * Routing is backed by (creme radix)'s own shared RadixTree core
 * (radix.c/radix.h) -- a byte-radix trie, keyed per route as `"/" +
 * METHOD + pattern` (mirroring native mux.cr's own `threez/mux.cr`
 * shard, which keys its single underlying Radix::Tree the exact same
 * way). ":name" segments (matching (creme mux)'s own path-param syntax
 * that surf.sld already assumes) and "*name" catch-all segments are
 * both supported; a static route always wins over an overlapping
 * ":name"/"*name" one REGARDLESS of registration order (see radix.c's
 * own header comment for why), and there is no route-count, path-depth,
 * or per-segment length cap the way an earlier fixed-size-segment-array
 * version of this file had (see git history) -- matching bounded only
 * by actual request/pattern length.
 *
 * Deliberate simplification vs. the real mux.cr: middleware (mux-use!,
 * used only for surf.sld's request-logging middleware here) can OBSERVE
 * the request and the final response's status code but can't actually
 * rewrite the response — the real mux.cr's middleware chain wraps the
 * literal response-writing process; replicating that exactly would need
 * genuine delimited continuations this prototype has no way to express.
 * Since the one middleware this app actually registers (surf-log-
 * middleware) only logs and returns the status unchanged, this
 * simplification doesn't change this app's observable behavior. */
#include "builtin_config.h"

#if CREME_WITH_MUX

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <gc.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "picohttpparser.h"
#include "sds.h"

#include "embed.h"
#include "mux.h"
#include "radix.h"

/* One route's payload in the shared RadixTree (see mux.c's own header
 * comment) -- boxed the same way radix.c's own Scheme-facing builtins
 * box a plain Value, just with a Value-typed handler instead of an
 * opaque one, since routing here always resolves to a Scheme closure. */
typedef struct {
  Value handler; /* (lambda (request) response-alist) */
} RouteHandler;

typedef struct {
  RadixTree *routes; /* keyed "/" + METHOD + pattern -> RouteHandler* */
  Value *middlewares; /* each (lambda (request next) ...) */
  int n_middlewares, cap_middlewares;
} MuxApp;

typedef struct {
  MuxApp *app;
  int fd; /* the listening socket -- mux-close! just close()s this */
  char *host;
  char *port;
  int uses_pool; /* mux-close! must close every pool listener (g_pool_fds), not just `fd` */
} MuxServer;

static MuxApp *as_mux_app(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_MUX_ROUTER, who);
}

static MuxServer *as_mux_server(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_MUX_SERVER, who);
}

static char *gc_strndup(const char *s, size_t len) {
  char *copy = GC_MALLOC(len ? len : 1);
  memcpy(copy, s, len);
  return copy;
}

static Value v_gcstr(const char *s, size_t len) {
  return creme_bytes_value(s, (int)len);
}

/* Same as v_gcstr, but for a C string literal (e.g. the alist keys below) —
 * T_STR is mutable (string-set!) as of Group C, so a Value pointing
 * directly at a literal in .rodata would segfault the moment Scheme code
 * mutated it; every literal handed to Scheme needs its own GC-owned copy. */
static Value v_litstr(const char *s) {
  return creme_cstr_value(s);
}

/* ---- registration ---- */

static Value bi_mux_router(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  MuxApp *app = GC_MALLOC(sizeof(MuxApp));
  app->routes = radix_tree_new();
  return v_box(app, BOX_KIND_MUX_ROUTER);
}

static Value bi_mux_router_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mux-router?");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_MUX_ROUTER);
}

/* Builds the same `"/" + METHOD + pattern` synthetic key dispatch_request
 * later looks up (mirroring native mux.cr's own `threez/mux.cr` shard,
 * which keys its single Radix::Tree the identical way) and stores it in
 * the app's shared RadixTree -- re-registering the exact same method+
 * pattern just overwrites the earlier handler (see radix.c's own header
 * comment), not an error. */
static void register_route(VM *vm, Value *args, int nargs, const char *method) {
  (void)vm;
  creme_check_min_args(nargs, 3, "mux-route!");
  int pathlen;
  const char *path = creme_arg_bytes(args, nargs, 1, "mux-route!", &pathlen);
  MuxApp *app = as_mux_app(args[0], "mux-route!");

  size_t method_len = strlen(method);
  size_t key_len = 1 + method_len + (size_t)pathlen;
  char *key = GC_MALLOC(key_len ? key_len : 1);
  key[0] = '/';
  memcpy(key + 1, method, method_len);
  memcpy(key + 1 + method_len, path, (size_t)pathlen);

  RouteHandler *rh = GC_MALLOC(sizeof(RouteHandler));
  rh->handler = args[2];
  radix_tree_add(app->routes, key, key_len, rh);
}

static Value bi_mux_get(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "GET"); return v_nil(); }
static Value bi_mux_head(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "HEAD"); return v_nil(); }
static Value bi_mux_post(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "POST"); return v_nil(); }
static Value bi_mux_put(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "PUT"); return v_nil(); }
static Value bi_mux_delete(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "DELETE"); return v_nil(); }
static Value bi_mux_patch(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "PATCH"); return v_nil(); }

static Value bi_mux_use(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "mux-use!");
  MuxApp *app = as_mux_app(args[0], "mux-use!");
  if (app->n_middlewares >= app->cap_middlewares) {
    app->cap_middlewares = app->cap_middlewares ? app->cap_middlewares * 2 : 4;
    app->middlewares = GC_REALLOC(app->middlewares, sizeof(Value) * (size_t)app->cap_middlewares);
  }
  app->middlewares[app->n_middlewares++] = args[1];
  return v_nil();
}

/* ---- alist helpers ---- */

static Value alist_ref(Value alist, const char *key) {
  size_t klen = strlen(key);
  Value cur = alist;
  while (cur.tag == T_PAIR) {
    Value pair = cur.as.pair->car;
    if (pair.tag == T_PAIR && pair.as.pair->car.tag == T_STR &&
        (size_t)pair.as.pair->car.aux == klen &&
        memcmp(pair.as.pair->car.as.chars, key, klen) == 0) {
      return pair.as.pair->cdr;
    }
    cur = cur.as.pair->cdr;
  }
  return v_nil();
}

/* ---- length-bounded case-insensitive helpers (picohttpparser's header
 * name/value pointers are slices into the read buffer, NOT NUL-terminated,
 * unlike http.c's own ci_eq/ci_contains, which take plain C strings). ---- */

static int ci_eq_len(const char *a, size_t alen, const char *b) {
  size_t blen = strlen(b);
  if (alen != blen) return 0;
  for (size_t i = 0; i < alen; i++) {
    if (tolower((unsigned char)a[i]) != tolower((unsigned char)b[i])) return 0;
  }
  return 1;
}

static int ci_contains_len(const char *hay, size_t haylen, const char *needle) {
  size_t nlen = strlen(needle);
  if (nlen == 0) return 1;
  for (size_t i = 0; i + nlen <= haylen; i++) {
    size_t j = 0;
    while (j < nlen && tolower((unsigned char)hay[i + j]) == tolower((unsigned char)needle[j])) j++;
    if (j == nlen) return 1;
  }
  return 0;
}

/* -1 on a non-digit anywhere (malformed Content-Length) -- callers treat that
 * the same as "absent". -2 on numeric overflow: WITHOUT this, a long-enough
 * digit string wraps `v` to a negative value, the caller's `content_length > 0`
 * test then fails, the request is dispatched body-less, and the real body bytes
 * are reparsed as a second pipelined request (classic request smuggling). */
static long parse_long_len(const char *s, size_t len) {
  if (len == 0) return -1;
  long v = 0;
  for (size_t i = 0; i < len; i++) {
    if (s[i] < '0' || s[i] > '9') return -1;
    if (v > (LONG_MAX - 9) / 10) return -2;
    v = v * 10 + (s[i] - '0');
  }
  return v;
}

static const char *status_reason(int status) {
  switch (status) {
  case 100: return "Continue";
  case 101: return "Switching Protocols";
  case 200: return "OK";
  case 201: return "Created";
  case 202: return "Accepted";
  case 204: return "No Content";
  case 206: return "Partial Content";
  case 301: return "Moved Permanently";
  case 302: return "Found";
  case 303: return "See Other";
  case 304: return "Not Modified";
  case 307: return "Temporary Redirect";
  case 308: return "Permanent Redirect";
  case 400: return "Bad Request";
  case 401: return "Unauthorized";
  case 403: return "Forbidden";
  case 404: return "Not Found";
  case 405: return "Method Not Allowed";
  case 409: return "Conflict";
  case 410: return "Gone";
  case 413: return "Payload Too Large";
  case 414: return "URI Too Long";
  case 415: return "Unsupported Media Type";
  case 422: return "Unprocessable Entity";
  case 429: return "Too Many Requests";
  case 500: return "Internal Server Error";
  case 501: return "Not Implemented";
  case 502: return "Bad Gateway";
  case 503: return "Service Unavailable";
  case 504: return "Gateway Timeout";
  default: return "";
  }
}

#define MUX_MAX_HEADERS 100
/* Request-size caps: without them a single client can grow c->buf/chunk_body
 * without bound (endless headers with no CRLFCRLF, a huge Content-Length, or an
 * endless chunked stream) and exhaust memory. */
#define MUX_MAX_HEADER_BYTES (64 * 1024)
#define MUX_MAX_BODY_BYTES (64L * 1024 * 1024)
/* Generous fixed cap on captured ":name"/"*name" route params per
 * request -- same "small fixed shape, not adversarial" reasoning as
 * MUX_MAX_HEADERS above; extra captures beyond this are silently
 * dropped (radix_tree_find's own documented behavior). */
#define MUX_MAX_PARAMS 32

/* ---- request building ---- */

static Value build_request(VM *vm, const char *method, size_t method_len, const char *path, size_t path_len,
                            const struct phr_header *headers, size_t num_headers, const char *body, size_t body_len,
                            const char *remote_addr, Value path_params) {
  Value hlist = v_nil();
  for (size_t i = 0; i < num_headers; i++) {
    if (!headers[i].name) continue; /* a multiline-header continuation line -- see phr_header's own doc comment */
    Value name = v_gcstr(headers[i].name, headers[i].name_len);
    Value value = v_gcstr(headers[i].value, headers[i].value_len);
    hlist = creme_cons(vm, creme_cons(vm, name, value), hlist);
  }

  Value request = v_nil();
  request = creme_cons(vm, creme_cons(vm, v_litstr("body"), v_gcstr(body, body_len)), request);
  request = creme_cons(vm, creme_cons(vm, v_litstr("remote-addr"), v_litstr(remote_addr)), request);
  request = creme_cons(vm, creme_cons(vm, v_litstr("headers"), hlist), request);
  request = creme_cons(vm, creme_cons(vm, v_litstr("path-params"), path_params), request);
  request = creme_cons(vm, creme_cons(vm, v_litstr("path"), v_gcstr(path, path_len)), request);
  request = creme_cons(vm, creme_cons(vm, v_litstr("method"), v_gcstr(method, method_len)), request);
  return request;
}

/* ---- response writing ---- */

/* Appends a full status-line + headers + body onto *out (grown via
 * sdscatlen/sdscatprintf, same as strings.c's own sds usage). */
static void write_response(VM *vm, sds *out, Value response, int keep_alive) {
  Value status_v = alist_ref(response, "status");
  int status = (status_v.tag == T_INT) ? (int)status_v.as.i : 200;
  Value body = alist_ref(response, "body");

  Value body_str;
  if (body.tag == T_STR) {
    body_str = body;
  } else if (body.tag == T_CLOSURE || body.tag == T_CASE_CLOSURE || body.tag == T_BUILTIN) {
    /* mux.cr's own "streaming callable body" case: the handler passed a
     * (lambda (port) ...) instead of a pre-built string (surf-html/
     * surf-json pass write-page!/write-todos-json! straight through
     * unconverted -- see surf.sld's own `(if (or (string? body)
     * (procedure? body)) body ...)`). This prototype has no true
     * incremental streaming port (Port is a plain in-memory buffer, same
     * one open-output-string already uses) -- buffer the whole body, then
     * write it in one shot, which is behaviorally equivalent for any
     * caller that isn't relying on partial flushes. */
    Port *port = GC_MALLOC(sizeof(Port));
    port->kind = PORT_KIND_OUTPUT_STRING; /* GC_MALLOC zero-inits, which would otherwise default to PORT_KIND_STDOUT (0) and misroute writes straight to real stdout instead of buffering here */
    Value port_val = v_port(port);
    creme_apply(vm, body, &port_val, 1);
    body_str = v_str(port->buf, port->len);
  } else {
    body_str = v_litstr("");
  }

  *out = sdscatprintf(*out, "HTTP/1.1 %d %s\r\n", status, status_reason(status));

  Value cur = alist_ref(response, "headers");
  while (cur.tag == T_PAIR) {
    Value pair = cur.as.pair->car;
    if (pair.tag == T_PAIR && pair.as.pair->car.tag == T_STR && pair.as.pair->cdr.tag == T_STR) {
      Value k = pair.as.pair->car, v = pair.as.pair->cdr;
      /* Skip a caller-supplied Content-Length/Connection -- this file
       * always computes and appends its own below, so a duplicate here
       * would just add a second, ignorable header line rather than a
       * genuine conflict, but there's no reason to emit it twice. */
      if (!ci_eq_len(k.as.chars, (size_t)k.aux, "content-length") && !ci_eq_len(k.as.chars, (size_t)k.aux, "connection")) {
        *out = sdscatlen(*out, k.as.chars, (size_t)k.aux);
        *out = sdscatlen(*out, ": ", 2);
        *out = sdscatlen(*out, v.as.chars, (size_t)v.aux);
        *out = sdscatlen(*out, "\r\n", 2);
      }
    }
    cur = cur.as.pair->cdr;
  }

  *out = sdscatprintf(*out, "Content-Length: %d\r\nConnection: %s\r\n\r\n", body_str.aux, keep_alive ? "keep-alive" : "close");
  *out = sdscatlen(*out, body_str.as.chars, (size_t)body_str.aux);
}

/* A synthetic response for cases dispatch never reaches Scheme at all
 * (no matching route, or a malformed request) -- same wire format as
 * write_response, just without a VM-sourced alist to read from. */
static void write_status_response(sds *out, int status, const char *body, int keep_alive) {
  *out = sdscatprintf(*out, "HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\nConnection: %s\r\n\r\n%s", status,
                       status_reason(status), strlen(body), keep_alive ? "keep-alive" : "close", body);
}

/* ---- middleware "next" thunk ----
 * See this file's own header comment: middleware here can only observe the
 * final status, not rewrite the response. _Thread_local (not a plain
 * global) since dispatch_request may now run concurrently across multiple
 * pool workers -- each on its own VM/thread, matching the same idiom
 * vm.c's g_current_vm and builtins.c's port-restore stacks already use
 * for exactly this "one VM per thread" shape (see those files' own
 * comments). */
static _Thread_local Value g_next_status;

static Value bi_next_thunk(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return g_next_status;
}

/* ---- dispatch ----
 * Called against whichever VM the caller (pool_worker_loop, or the
 * inline I/O loop) owns -- see this file's own header comment for why
 * no shared VM/lock is needed here at all. */
static void dispatch_request(VM *vm, MuxApp *app, const char *method, size_t method_len, const char *path, size_t path_len,
                              const struct phr_header *headers, size_t num_headers, const char *body, size_t body_len,
                              const char *remote_addr, int keep_alive, sds *out) {
  /* Same synthetic "/" + METHOD + path key register_route built at
   * registration time (see that function's own comment) -- GC_MALLOC'd
   * rather than a fixed stack buffer since there's no path-length cap
   * to bound it by any more (see this file's own header comment). */
  size_t key_len = 1 + method_len + path_len;
  char *key = GC_MALLOC(key_len ? key_len : 1);
  key[0] = '/';
  memcpy(key + 1, method, method_len);
  memcpy(key + 1 + method_len, path, path_len);

  RadixParam params[MUX_MAX_PARAMS];
  int nparams;
  RouteHandler *rh = radix_tree_find(app->routes, key, key_len, params, &nparams, MUX_MAX_PARAMS);

  if (!rh) {
    write_status_response(out, 404, "Not Found", keep_alive);
    return;
  }

  Value path_params = v_nil();
  for (int i = 0; i < nparams; i++) {
    path_params =
        creme_cons(vm, creme_cons(vm, v_gcstr(params[i].name, params[i].name_len), v_gcstr(params[i].value, params[i].value_len)), path_params);
  }

  Value request = build_request(vm, method, method_len, path, path_len, headers, num_headers, body, body_len, remote_addr, path_params);
  Value response = creme_apply(vm, rh->handler, &request, 1);

  Value status_v = alist_ref(response, "status");
  g_next_status = (status_v.tag == T_INT) ? status_v : v_int(200);
  Value next = v_builtin(bi_next_thunk);
  for (int i = 0; i < app->n_middlewares; i++) {
    Value margs[2] = {request, next};
    creme_apply(vm, app->middlewares[i], margs, 2);
  }

  write_response(vm, out, response, keep_alive);
}

/* ---- connection state ----
 * One per accepted connection, GC_MALLOC'd (its `buf`/`chunk_body` sds
 * fields are only reachable through it, so it must itself be GC-visible
 * -- see the g_pfds/g_pconns arrays below, which are what actually keep
 * a live Conn reachable while the I/O thread has it under poll() watch).
 * Owned by exactly one of: the I/O thread's own poll() slot array (being
 * read from), the job queue (queued for a worker), a worker thread
 * (being dispatched), or the ready list (handed back, awaiting the I/O
 * thread) -- never two of these at once, so no field here needs its own
 * lock; `next` is reused as queue linkage for whichever of the job
 * queue/ready list it's currently sitting in. */
typedef enum { CONN_READING_HEADERS, CONN_READING_BODY } ConnPhase;

typedef struct Conn {
  int fd;
  MuxApp *app;
  char remote_addr[64];

  sds buf;
  size_t last_len;
  ConnPhase phase;

  const char *method;
  size_t method_len;
  const char *path;
  size_t path_len;
  struct phr_header headers[MUX_MAX_HEADERS];
  size_t num_headers;
  size_t header_len;
  int minor_version;

  long content_length;
  int chunked;
  int keep_alive;
  sds chunk_body;
  struct phr_chunked_decoder decoder;

  const char *body;
  size_t body_len;

  struct Conn *next;
} Conn;

/* ---- connection I/O (single thread, poll(2)-multiplexed) ---- */

/* EAGAIN-safe: `fd` may be O_NONBLOCK (every connection fd here is --
 * see bi_mux_listen), so a write from a worker thread (finishing a
 * request) or from the I/O thread itself (a synthesized 400 response,
 * before a Conn even exists) can legitimately hit backpressure. Blocking
 * on a short poll() for POLLOUT before retrying is simplest and correct
 * either way; a slow client stalls only the one thread writing to it. */
static void write_all_sds(int fd, sds buf) {
  size_t left = sdslen(buf);
  const char *p = buf;
  while (left > 0) {
    ssize_t w = write(fd, p, left);
    if (w < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        struct pollfd pfd = {fd, POLLOUT, 0};
        poll(&pfd, 1, -1);
        continue;
      }
      return; /* best-effort: the peer is likely gone, nothing more to do */
    }
    if (w == 0) return;
    p += (size_t)w;
    left -= (size_t)w;
  }
}

/* -2: no data available right now (EAGAIN/EWOULDBLOCK/EINTR) -- not an
 * error, just wait for the next POLLIN. -1: hard error or a clean peer
 * close. >=0: bytes actually read. */
static ssize_t conn_read_into(Conn *c) {
  sds *target = (c->phase == CONN_READING_BODY && c->chunked) ? &c->chunk_body : &c->buf;
  char chunk[4096];
  ssize_t r = recv(c->fd, chunk, sizeof(chunk), 0);
  if (r < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -2;
    return -1;
  }
  if (r == 0) return -1;
  *target = sdscatlen(*target, chunk, (size_t)r);
  return r;
}

/* Advances `c`'s parse state as far as the bytes already buffered allow.
 * Returns 1 once a full request (method/path/headers/body, all stashed
 * on `c`) is ready to dispatch, 0 if more bytes are needed (keep polling
 * this fd for POLLIN), or -1 if a parse/decode error was already
 * responded to (400) and the connection should be closed. */
/* Write a bare status line + close-marker response, for the request-rejection
 * paths (400/413/431). Mirrors the inline 400 handling already used below. */
static void conn_error_response(Conn *c, int status, const char *reason) {
  sds errbuf = sdsempty();
  write_status_response(&errbuf, status, reason, 0);
  write_all_sds(c->fd, errbuf);
  sdsfree(errbuf);
}

static int conn_advance(Conn *c) {
  if (c->phase == CONN_READING_HEADERS) {
    size_t num_headers = MUX_MAX_HEADERS;
    int pret = phr_parse_request(c->buf, sdslen(c->buf), &c->method, &c->method_len, &c->path, &c->path_len, &c->minor_version,
                                  c->headers, &num_headers, c->last_len);
    if (pret == -2) {
      if (sdslen(c->buf) > MUX_MAX_HEADER_BYTES) { /* headers never terminated */
        conn_error_response(c, 431, "Request Header Fields Too Large");
        return -1;
      }
      c->last_len = sdslen(c->buf);
      return 0;
    }
    if (pret == -1) {
      sds errbuf = sdsempty();
      write_status_response(&errbuf, 400, "Bad Request", 0);
      write_all_sds(c->fd, errbuf);
      sdsfree(errbuf);
      return -1;
    }
    c->num_headers = num_headers;
    c->header_len = (size_t)pret;
    c->content_length = -1;
    c->chunked = 0;
    int saw_content_length = 0;
    c->keep_alive = c->minor_version >= 1; /* HTTP/1.1 defaults to persistent, 1.0 to close, unless overridden below */
    for (size_t i = 0; i < c->num_headers; i++) {
      if (!c->headers[i].name) continue;
      if (ci_eq_len(c->headers[i].name, c->headers[i].name_len, "content-length")) {
        saw_content_length = 1;
        c->content_length = parse_long_len(c->headers[i].value, c->headers[i].value_len);
      } else if (ci_eq_len(c->headers[i].name, c->headers[i].name_len, "transfer-encoding")) {
        if (ci_contains_len(c->headers[i].value, c->headers[i].value_len, "chunked")) c->chunked = 1;
      } else if (ci_eq_len(c->headers[i].name, c->headers[i].name_len, "connection")) {
        if (ci_contains_len(c->headers[i].value, c->headers[i].value_len, "close")) c->keep_alive = 0;
        else if (ci_contains_len(c->headers[i].value, c->headers[i].value_len, "keep-alive")) c->keep_alive = 1;
      }
    }
    /* A present-but-invalid Content-Length must be rejected, never treated as
     * "absent" (-1): otherwise the request is dispatched body-less and the real
     * body bytes are reparsed as a pipelined request (smuggling). -2 = numeric
     * overflow / too big (413); -1 with the header present = non-numeric/empty
     * (400); a valid value over the cap = 413. */
    if (c->content_length == -2 || c->content_length > MUX_MAX_BODY_BYTES) {
      conn_error_response(c, 413, "Payload Too Large");
      return -1;
    }
    if (saw_content_length && c->content_length < 0) {
      conn_error_response(c, 400, "Bad Request");
      return -1;
    }
    if (c->chunked) {
      /* No client in this codebase ever sends a chunked REQUEST body
       * (http.c's own HTTP client only dechunks RESPONSES) -- this exists
       * only for a hypothetical other client, kept deliberately simple:
       * decode into a SEPARATE buffer (phr_decode_chunked rewrites its
       * input in place, and doing that to `c->buf` itself would make
       * tracking any leftover pipelined bytes past this request far
       * trickier), then force the connection closed afterward rather
       * than trying to reconcile `c->buf`'s own leftover tracking against
       * bytes that were actually read into `c->chunk_body` instead. */
      c->keep_alive = 0;
      memset(&c->decoder, 0, sizeof(c->decoder));
      c->decoder.consume_trailer = 1;
      c->chunk_body = sdscatlen(sdsempty(), c->buf + c->header_len, sdslen(c->buf) - c->header_len);
    }
    c->phase = CONN_READING_BODY;
  }

  if (c->chunked) {
    if (sdslen(c->chunk_body) > (size_t)MUX_MAX_BODY_BYTES) { /* endless chunked stream */
      conn_error_response(c, 413, "Payload Too Large");
      return -1;
    }
    size_t bufsz = sdslen(c->chunk_body);
    ssize_t rret = phr_decode_chunked(&c->decoder, c->chunk_body, &bufsz);
    sdssetlen(c->chunk_body, bufsz);
    if (rret == -1) {
      sds errbuf = sdsempty();
      write_status_response(&errbuf, 400, "Bad Request", 0);
      write_all_sds(c->fd, errbuf);
      sdsfree(errbuf);
      return -1;
    }
    if (rret == -2) return 0;
    c->body = c->chunk_body;
    c->body_len = sdslen(c->chunk_body);
    return 1;
  }
  if (c->content_length > 0) {
    size_t need = c->header_len + (size_t)c->content_length;
    if (sdslen(c->buf) < need) return 0;
    c->body = c->buf + c->header_len;
    c->body_len = (size_t)c->content_length;
    return 1;
  }
  c->body = "";
  c->body_len = 0;
  return 1;
}

static void set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* ---- dispatch: pooled or inline ----
 * `mux-listen!`'s optional 3rd argument (`options`, a string-keyed
 * alist -- see bi_mux_listen, below) can carry a "pool" entry that picks
 * how a fully-read request gets from the I/O loop to a VM:
 *
 *   #t (default) or <integer N> -- a GROWABLE pool of fully independent
 *     I/O threads, each with its OWN child VM (creme_new_child_vm) and its
 *     OWN SO_REUSEPORT listener bound to the same host:port -- see this
 *     file's own header comment and pool_worker_loop's, below, for the
 *     full rationale and history (an earlier version of this handed a
 *     fully-read `Conn` to a FIXED pool via a locked queue; profiling
 *     that under concurrent load found the queue's own mutex/condvar
 *     handoff, not app work, dominating C-level time -- on FreeBSD, over
 *     half of all sampled time was _umtx_op_err, the syscall backing
 *     pthread_mutex_lock/pthread_cond_wait). Each worker accepts,
 *     parses, and dispatches its own connections end to end, with zero
 *     cross-thread handoff of any kind; the KERNEL, not this file,
 *     load-balances new connections across the pool's listeners (see
 *     bind_listener's SO_REUSEPORT). #t's max defaults to the visible
 *     CPU count x 8 (mux_auto_pool_size() x 8); an explicit integer sets
 *     max directly. Either way the pool never drops below `pool_min`
 *     (mux_pool_min, 8 by default, or the requested max itself if that's
 *     smaller) -- those floor workers are "permanent" and never self-
 *     terminate. Beyond the floor, pool_try_grow spins up an extra
 *     worker once an existing one's own connection count crosses a
 *     high-water mark, and that extra worker's own pool_worker_loop
 *     shrinks itself back out once it's sat idle long enough -- see
 *     POOL_GROW_HIGH_WATER/POOL_SHRINK_IDLE_TICKS, below.
 *   #f -- NO pool at all: the I/O thread itself calls dispatch_request
 *     inline, against one dedicated VM (g_inline_vm), right in the poll
 *     loop -- zero extra threads, zero cross-thread handoff, but also
 *     zero parallelism: every request is fully serialized on the one
 *     I/O thread. Best choice for cheap/fast handlers or when requests
 *     never need real concurrency. */

/* Resets `c`'s parse state for the next keep-alive request on the same
 * connection (drop the just-consumed prefix, keep any already-buffered
 * pipelined bytes) -- shared by both the pooled and inline dispatch
 * paths below. */
static void conn_reset_for_next_request(Conn *c) {
  size_t consumed = c->header_len + (c->content_length > 0 ? (size_t)c->content_length : 0);
  if (sdslen(c->buf) > consumed) {
    sdsrange(c->buf, (ssize_t)consumed, -1);
  } else {
    sdsclear(c->buf);
  }
  c->last_len = 0;
  c->phase = CONN_READING_HEADERS;
}

/* Runs dispatch_request against `vm`, with the same creme_abort-safety-net
 * setjmp(vm->actor_unwind) actor.c's own thread entry function uses for a
 * spawned actor: an uncaught abort while handling this one request
 * degrades to a synthesized 500 instead of taking down whatever thread
 * (a pool worker, or the I/O thread itself in inline mode) is running
 * it. `vm` must already have has_actor_unwind set and be the CURRENT vm
 * (creme_set_current_vm) for the calling thread -- both pool workers and
 * bi_mux_listen's own inline path set this up once, not per-call. */
static sds dispatch_with_recovery(VM *vm, Conn *c) {
  sds out = sdsempty();
  if (setjmp(vm->actor_unwind) == 0) {
    dispatch_request(vm, c->app, c->method, c->method_len, c->path, c->path_len, c->headers, c->num_headers, c->body, c->body_len,
                      c->remote_addr, c->keep_alive, &out);
  } else {
    sdsfree(out);
    out = sdsempty();
    write_status_response(&out, 500, vm->abort_message, c->keep_alive);
  }
  return out;
}

/* Sized off the visible CPU count x 8 -- generous headroom for a growable
 * pool's MAX, not a fixed count (see pool_worker_loop's own header
 * comment): the pool only actually spawns beyond `pool_min` when a
 * worker's own connection count crosses POOL_GROW_HIGH_WATER, so sizing
 * this generously costs nothing at rest. Used when mux-listen!'s "pool"
 * option is #t (the default pool-enabled case) rather than an explicit
 * integer, which sets max directly instead. */
static int mux_auto_pool_max(void) {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  if (n < 2) n = 2;
  if (n > 16) n = 16;
  return (int)n * 8;
}

/* Inline mode's one dedicated VM (pool #f) -- a fresh child VM rather
 * than reusing the CALLING vm directly, specifically so setjmp(vm->
 * actor_unwind) here can't clobber a jmp_buf some OUTER context (e.g. if
 * mux-listen! was itself called from inside a spawned actor's own
 * thunk) already has a live, still-meaningful setjmp target installed
 * in. This VM is used ONLY by bi_mux_listen's own poll loop, on the SAME
 * thread that called mux-listen! -- no pthread_create at all. */
static VM *g_inline_vm;

/* ---- an I/O thread's own poll() fd set ----
 * Two parallel, index-aligned, growable arrays rather than one combined
 * struct, since poll(2) itself needs a contiguous `struct pollfd` array
 * with no interleaved padding. Slot 0 is always that thread's listener.
 * Slot 1 is the wake pipe's read end IF a pool is in use (reserved == 2);
 * with no pool (reserved == 1) there's nothing to wake this thread FROM
 * another thread, so no wake pipe is even created. Neither reserved slot
 * is ever removed. Bundled into a struct (rather than bare globals) so
 * the reuseport-per-thread model (below) can give each of its own I/O
 * threads an independent set with no cross-thread contention at all --
 * the classic single-I/O-thread models (inline, pooled) just keep one
 * instance of this on the stack of the one thread that owns it. No lock
 * needed for a SlotSet itself (only g_ready/g_job_queue, which really do
 * cross threads, need one). */
typedef struct {
  struct pollfd *pfds;
  Conn **pconns;
  int n_slots, cap_slots;
  int reserved_slots;
} SlotSet;

static void slots_add(SlotSet *s, int fd, short events, Conn *conn) {
  if (s->n_slots >= s->cap_slots) {
    s->cap_slots = s->cap_slots ? s->cap_slots * 2 : 32;
    s->pfds = GC_REALLOC(s->pfds, sizeof(struct pollfd) * (size_t)s->cap_slots);
    s->pconns = GC_REALLOC(s->pconns, sizeof(Conn *) * (size_t)s->cap_slots);
  }
  s->pfds[s->n_slots].fd = fd;
  s->pfds[s->n_slots].events = events;
  s->pfds[s->n_slots].revents = 0;
  s->pconns[s->n_slots] = conn;
  s->n_slots++;
}

/* Swap-remove: slot i is discarded, the current last slot moves into its
 * place. Safe to call while iterating slots in REVERSE (high index to
 * low, i always >= s->reserved_slots) -- see that loop's own comment in
 * bi_mux_listen/pool_worker_loop. */
static void slots_remove(SlotSet *s, int i) {
  s->n_slots--;
  s->pfds[i] = s->pfds[s->n_slots];
  s->pconns[i] = s->pconns[s->n_slots];
}

/* ---- growable pool: SO_REUSEPORT, one fully independent I/O thread per
 * worker, no cross-thread handoff at all ----
 * Each worker binds its own listener to the SAME host:port via
 * SO_REUSEPORT and runs the exact same accept/read/parse/dispatch loop
 * as `pool #f`'s inline mode above -- but on its own thread and its own
 * child VM. The kernel's own SYN-to-listener load balancing (which, like
 * the accept-queue wakeup this file's own header comment already relies
 * on, uses exclusive/single-waiter wakeup rather than a thundering herd)
 * decides which worker's listener a given incoming connection lands on;
 * from that point on, that ONE worker owns the connection for its
 * entire life -- no queue, no condvar, no wake pipe, no cross-thread
 * anything. Trade-off: connections are pinned to whichever worker
 * accepted them, so a pathological mix of a few very long-lived
 * connections could load one worker more than others -- not a concern
 * for this app's own short-lived request/response HTTP traffic.
 *
 * `pool_min` workers are spawned up front and are "permanent" (never
 * self-terminate, guaranteeing the pool never shrinks below that floor).
 * Beyond the floor, the pool grows and shrinks with load:
 *   - a worker whose own connection count crosses POOL_GROW_HIGH_WATER
 *     tries to spawn one more (non-permanent) worker, up to pool_max;
 *   - a non-permanent worker that's had ZERO connections for
 *     POOL_SHRINK_IDLE_TICKS consecutive poll() timeouts closes its own
 *     listener and exits, shrinking the pool back down.
 * poll()'s timeout (rather than -1/infinite, used everywhere else in
 * this file) is what lets an idle non-permanent worker notice it should
 * shrink even with no fd activity at all. */
#define POOL_POLL_TIMEOUT_MS 3000
#define POOL_GROW_HIGH_WATER 4
#define POOL_SHRINK_IDLE_TICKS 3

typedef struct {
  char host[256];
  char port[32];
  MuxApp *app;
  VM *parent_vm;
  int max;
} PoolConfig;

static PoolConfig g_pool_cfg;
static int g_pool_count; /* atomic; current live worker count, permanent + grown */

/* Every listener fd currently backing the pool (one per live worker) --
 * tracked so mux-close! can close all of them, not just the first.
 * Mutex-protected since workers add/remove themselves as the pool grows
 * and shrinks, concurrently with a possible mux-close! from yet another
 * thread. */
typedef struct {
  int *fds;
  int n, cap;
  pthread_mutex_t mu;
} FdSet;

static FdSet g_pool_fds;

static int bind_listener(const char *host, const char *port_str, int reuseport);

static void fdset_add(FdSet *s, int fd) {
  pthread_mutex_lock(&s->mu);
  if (s->n >= s->cap) {
    s->cap = s->cap ? s->cap * 2 : 8;
    s->fds = GC_REALLOC(s->fds, sizeof(int) * (size_t)s->cap);
  }
  s->fds[s->n++] = fd;
  pthread_mutex_unlock(&s->mu);
}

/* Remove fd from the set AND close it, atomically under the set's lock, but
 * only if it's still present. This is what makes a shrinking worker and
 * mux-close! safe to race: whichever reaches a given fd first (under the same
 * mutex) closes it and takes it out of the set; the other finds it gone and
 * does nothing, so the fd is never closed twice (which could otherwise close an
 * unrelated fd that reused the number). */
static void fdset_remove_and_close(FdSet *s, int fd) {
  pthread_mutex_lock(&s->mu);
  for (int i = 0; i < s->n; i++) {
    if (s->fds[i] == fd) {
      s->fds[i] = s->fds[--s->n];
      close(fd);
      pthread_mutex_unlock(&s->mu);
      return;
    }
  }
  pthread_mutex_unlock(&s->mu);
}

typedef struct {
  VM *parent_vm;
  MuxApp *app;
  int fd;
  int permanent; /* 1 = a base (pool_min floor) worker that must not self-shrink */
} PoolWorkerArgs;

static void *pool_worker_thread_main(void *arg);

/* Spawns one extra (non-permanent) worker if the pool is below `max` --
 * best-effort: any failure (bind, thread create) just leaves the pool at
 * its current size, since the caller's own connection is already being
 * served fine either way. The __atomic reserve-then-check dance avoids
 * needing a lock just to keep `g_pool_count` from ever exceeding max
 * under concurrent growth attempts from several workers at once. */
static void pool_try_grow(void) {
  int reserved = __atomic_add_fetch(&g_pool_count, 1, __ATOMIC_SEQ_CST);
  if (reserved > g_pool_cfg.max) {
    __atomic_fetch_sub(&g_pool_count, 1, __ATOMIC_SEQ_CST);
    return;
  }
  int fd = bind_listener(g_pool_cfg.host, g_pool_cfg.port, 1);
  if (fd < 0) {
    __atomic_fetch_sub(&g_pool_count, 1, __ATOMIC_SEQ_CST);
    return;
  }
  fdset_add(&g_pool_fds, fd);

  PoolWorkerArgs *a = GC_MALLOC(sizeof(PoolWorkerArgs));
  a->parent_vm = g_pool_cfg.parent_vm;
  a->app = g_pool_cfg.app;
  a->fd = fd;
  a->permanent = 0; /* grown workers shrink back when idle */
  pthread_t tid;
  if (pthread_create(&tid, NULL, pool_worker_thread_main, a) != 0) {
    fdset_remove_and_close(&g_pool_fds, fd);
    __atomic_fetch_sub(&g_pool_count, 1, __ATOMIC_SEQ_CST);
    return;
  }
  pthread_detach(tid);
}

/* The main loop for one pool worker (permanent or grown) -- identical
 * accept/read/parse/dispatch shape to the inline loop in bi_mux_listen,
 * plus the grow/shrink bookkeeping described above. A permanent worker
 * never returns (same "lives for the process's lifetime" contract as
 * every other mode's I/O thread); a non-permanent worker returns once it
 * decides to shrink, at which point its caller (pool_worker_thread_main)
 * tears down its GC thread registration and the thread exits for real. */
static void pool_worker_loop(VM *vm, MuxApp *app, int fd, int permanent) {
  SlotSet slots;
  memset(&slots, 0, sizeof(slots));
  slots.reserved_slots = 1;
  slots_add(&slots, fd, POLLIN, NULL); /* slot 0: this worker's own listener */
  int idle_ticks = 0;

  for (;;) {
    int nready = poll(slots.pfds, (nfds_t)slots.n_slots, POOL_POLL_TIMEOUT_MS);
    if (nready < 0) {
      if (errno == EINTR) continue;
      break; /* fd closed by mux-close!, or a real poll() error -- stop this worker */
    }

    if (slots.pfds[0].revents & POLLIN) {
      for (;;) {
        int cfd = accept(fd, NULL, NULL);
        if (cfd < 0) {
          if (errno == EINTR) continue;
          break;
        }
        set_nonblocking(cfd);
        int one = 1;
        setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

        Conn *c = GC_MALLOC(sizeof(Conn));
        c->fd = cfd;
        c->app = app;
        c->buf = sdsempty();
        c->last_len = 0;
        c->phase = CONN_READING_HEADERS;
        c->chunk_body = NULL;
        c->remote_addr[0] = 0;
        struct sockaddr_storage peer;
        socklen_t peer_len = sizeof(peer);
        if (getpeername(cfd, (struct sockaddr *)&peer, &peer_len) == 0) {
          if (peer.ss_family == AF_INET) {
            inet_ntop(AF_INET, &((struct sockaddr_in *)&peer)->sin_addr, c->remote_addr, sizeof(c->remote_addr));
          } else if (peer.ss_family == AF_INET6) {
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *)&peer)->sin6_addr, c->remote_addr, sizeof(c->remote_addr));
          }
        }
        slots_add(&slots, cfd, POLLIN, c);
      }
    }

    for (int i = slots.n_slots - 1; i >= slots.reserved_slots; i--) {
      if (!(slots.pfds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
      Conn *c = slots.pconns[i];
      int drop = 0;
      for (;;) {
        ssize_t r = conn_read_into(c);
        if (r == -2) break;
        if (r == -1) {
          close(c->fd);
          drop = 1;
          break;
        }
        int adv = conn_advance(c);
        if (adv == -1) {
          close(c->fd);
          drop = 1;
          break;
        }
        if (adv == 1) {
          sds out = dispatch_with_recovery(vm, c);
          write_all_sds(c->fd, out);
          sdsfree(out);
          if (c->chunk_body) {
            sdsfree(c->chunk_body);
            c->chunk_body = NULL;
          }
          if (!c->keep_alive) {
            close(c->fd);
            drop = 1;
          } else {
            conn_reset_for_next_request(c);
          }
          break;
        }
      }
      if (drop) slots_remove(&slots, i);
    }

    int own_conns = slots.n_slots - slots.reserved_slots;
    if (own_conns == 0) {
      idle_ticks++;
      if (!permanent && idle_ticks >= POOL_SHRINK_IDLE_TICKS) {
        __atomic_fetch_sub(&g_pool_count, 1, __ATOMIC_SEQ_CST);
        fdset_remove_and_close(&g_pool_fds, fd);
        return;
      }
    } else {
      idle_ticks = 0;
      if (own_conns >= POOL_GROW_HIGH_WATER) pool_try_grow();
    }
  }
  /* Fell out of the serve loop (fd closed by mux-close!, or a poll() error). A
   * grown (non-permanent) worker still holds a g_pool_count reservation and its
   * pool fd -- release both so the count doesn't drift upward and starve future
   * growth. The shrink path above already released and returned, so this can't
   * double-release; permanent workers keep their slot (shutdown-only path). */
  if (!permanent) {
    __atomic_fetch_sub(&g_pool_count, 1, __ATOMIC_SEQ_CST);
    fdset_remove_and_close(&g_pool_fds, fd);
  }
}

static void *pool_worker_thread_main(void *arg) {
  PoolWorkerArgs *a = (PoolWorkerArgs *)arg;

  struct GC_stack_base sb;
  GC_get_stack_base(&sb);
  GC_register_my_thread(&sb);

  VM *vm = creme_new_child_vm(a->parent_vm);
  creme_set_current_vm(vm);
  vm->has_actor_unwind = 1;

  pool_worker_loop(vm, a->app, a->fd, a->permanent);
  GC_unregister_my_thread();
  return NULL;
}

/* ---- listen / close / introspection ---- */

/* Shared by the primary listener bind below and, in pooled mode, every
 * other listener in the pool -- all bound to the SAME host:port via
 * SO_REUSEPORT, which lets the kernel accept the same address multiple
 * times and load-balance incoming connections across all of them. */
static int bind_listener(const char *host, const char *port_str, int reuseport) {
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;
  hints.ai_flags = AI_PASSIVE;
  struct addrinfo *res;
  if (getaddrinfo(host, port_str, &hints, &res) != 0) creme_abort("mux-listen!: could not resolve host '%s'", host);
  int fd = -1;
  for (struct addrinfo *rp = res; rp; rp = rp->ai_next) {
    fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (fd < 0) continue;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (reuseport) setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    if (bind(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0) return -1;
  if (listen(fd, 64) != 0) {
    close(fd);
    return -1;
  }
  set_nonblocking(fd);
  return fd;
}

static Value bi_mux_listen(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "mux-listen!");
  MuxApp *app = as_mux_app(args[0], "mux-listen!");

  char port_buf[32];
  const char *port_str;
  if (args[1].tag == T_INT) {
    snprintf(port_buf, sizeof(port_buf), "%lld", (long long)args[1].as.i);
    port_str = port_buf;
  } else if (args[1].tag == T_STR) {
    size_t len = (size_t)args[1].aux < sizeof(port_buf) - 1 ? (size_t)args[1].aux : sizeof(port_buf) - 1;
    memcpy(port_buf, args[1].as.chars, len);
    port_buf[len] = 0;
    port_str = port_buf;
  } else {
    creme_abort("mux-listen!: expected an integer or string port");
  }

  /* `options`: a string-keyed alist, e.g. '(("host" . "0.0.0.0") ("pool"
   * . 8)) -- same string-keyed-alist convention as the request/response
   * alists this file already builds/reads (build_request/write_response,
   * above), and deliberately NOT positional args, so native mux.cr's own
   * mux-listen! can add support for "host" while simply ignoring "pool"
   * (an icecreme-only concept -- native uses Fiber concurrency, not a
   * worker-VM pool) instead of choking on an unexpected extra argument. */
  Value options = nargs >= 3 ? args[2] : v_nil();

  char host_buf[256] = "127.0.0.1";
  Value host_v = alist_ref(options, "host");
  if (host_v.tag == T_STR) {
    size_t len = (size_t)host_v.aux < sizeof(host_buf) - 1 ? (size_t)host_v.aux : sizeof(host_buf) - 1;
    memcpy(host_buf, host_v.as.chars, len);
    host_buf[len] = 0;
  }

  /* "pool": #f (the default) -- no pool, inline dispatch. #t -- a
   * growable pool, max = mux_auto_pool_max() (visible CPU count x 8).
   * <integer N> -- a growable pool with max = N. Either pool case's
   * MIN is always 8 (POOL_DEFAULT_MIN), or max itself if that's
   * smaller -- see the dispatch section's header comment above for the
   * full grow/shrink design. Absent entirely (alist_ref returns T_NIL)
   * keeps the inline default. */
#define POOL_DEFAULT_MIN 8
  int pool_max = 0; /* 0 means "no pool" (inline) throughout this function */
  Value pool_v = alist_ref(options, "pool");
  if (pool_v.tag == T_BOOL) {
    pool_max = pool_v.as.b ? mux_auto_pool_max() : 0;
  } else if (pool_v.tag == T_INT) {
    pool_max = (int)pool_v.as.i;
    if (pool_max < 1) creme_abort("mux-listen!: \"pool\" must be a positive integer, or #t/#f");
  } else if (pool_v.tag != T_NIL) {
    creme_abort("mux-listen!: expected #t, #f, or a positive integer for \"pool\"");
  }
  int pool_min = pool_max > 0 ? (pool_max < POOL_DEFAULT_MIN ? pool_max : POOL_DEFAULT_MIN) : 0;

  /* bind+listen, mirroring actor.c's start_tcp_node exactly (same
   * getaddrinfo/socket/SO_REUSEADDR/bind/listen/getsockname dance). */
  int fd = bind_listener(host_buf, port_str, pool_max > 0);
  if (fd < 0) creme_abort("mux-listen!: failed to bind %s:%s", host_buf, port_str);

  /* getsockname gives the REAL bound port regardless of whether port_str
   * was a fixed port or "0" (ephemeral: let the OS pick) -- mux-base-url/
   * mux-address hand this back, matching native Crystal's own
   * server.bind_tcp/mux.cr, which returns the real bound address. */
  char real_port_buf[32];
  const char *real_port = port_str;
  struct sockaddr_storage ss;
  socklen_t ss_len = sizeof(ss);
  if (getsockname(fd, (struct sockaddr *)&ss, &ss_len) == 0) {
    unsigned short bound_port =
        ss.ss_family == AF_INET6 ? ntohs(((struct sockaddr_in6 *)&ss)->sin6_port) : ntohs(((struct sockaddr_in *)&ss)->sin_port);
    snprintf(real_port_buf, sizeof(real_port_buf), "%u", bound_port);
    real_port = real_port_buf;
  }

  MuxServer *srv = GC_MALLOC(sizeof(MuxServer));
  srv->app = app;
  srv->fd = fd;
  srv->host = gc_strndup(host_buf, strlen(host_buf));
  srv->port = gc_strndup(real_port, strlen(real_port));
  srv->uses_pool = pool_max > 0;

  if (pool_max > 0) {
    /* `pool_min - 1` MORE listeners get bound to the exact same host:
     * REAL bound port (not port_str, which may have been "0" -- every
     * extra socket must target the SAME port `fd` actually landed on,
     * or SO_REUSEPORT has nothing to share), one permanent worker
     * thread per extra listener, then `fd` itself (bound above) runs
     * its OWN permanent worker loop on the CALLING thread -- matching
     * every other mode's contract that mux-listen! blocks the caller.
     * `pool_min` (not pool_max) is exactly how many permanent workers
     * exist; anything beyond that is grown/shrunk on demand by
     * pool_worker_loop itself. */
    g_pool_cfg.app = app;
    g_pool_cfg.parent_vm = vm;
    g_pool_cfg.max = pool_max;
    memcpy(g_pool_cfg.host, host_buf, sizeof(host_buf));
    memcpy(g_pool_cfg.port, real_port, strlen(real_port) + 1);
    memset(&g_pool_fds, 0, sizeof(g_pool_fds));
    pthread_mutex_init(&g_pool_fds.mu, NULL);
    g_pool_count = pool_min;
    fdset_add(&g_pool_fds, fd);

    for (int i = 0; i < pool_min - 1; i++) {
      int extra_fd = bind_listener(host_buf, real_port, 1);
      if (extra_fd < 0) creme_abort("mux-listen!: failed to bind pool listener %d", i);
      fdset_add(&g_pool_fds, extra_fd);

      PoolWorkerArgs *a = GC_MALLOC(sizeof(PoolWorkerArgs));
      a->parent_vm = vm;
      a->app = app;
      a->fd = extra_fd;
      a->permanent = 1; /* base (pool_min floor) worker -- must not self-shrink */
      pthread_t tid;
      if (pthread_create(&tid, NULL, pool_worker_thread_main, a) != 0) creme_abort("mux-listen!: failed to start a pool worker thread");
      pthread_detach(tid);
    }

    VM *main_vm = creme_new_child_vm(vm);
    creme_set_current_vm(main_vm);
    main_vm->has_actor_unwind = 1;
    pool_worker_loop(main_vm, app, fd, /* permanent */ 1);
    return v_box(srv, BOX_KIND_MUX_SERVER);
  }

  /* pool #f: inline dispatch, one dedicated VM, no extra threads at all --
   * the calling thread's own poll() loop IS the whole server. */
  g_inline_vm = creme_new_child_vm(vm);
  creme_set_current_vm(g_inline_vm);
  g_inline_vm->has_actor_unwind = 1;

  SlotSet slots;
  memset(&slots, 0, sizeof(slots));
  slots.reserved_slots = 1;
  slots_add(&slots, fd, POLLIN, NULL); /* slot 0: listener */

  /* This call blocks the calling thread forever: a real deployed server
   * has no interactive step keeping the process alive the way the
   * REPL's stdin read does, so mux-listen! blocking here directly
   * matches "serve until killed" -- script forms after mux-listen!
   * still run as best-effort cleanup once/if this loop ever actually
   * stops (via mux-close!, which just close()s `fd`, making poll()/
   * accept() below fail and this loop return). */
  for (;;) {
    int nready = poll(slots.pfds, (nfds_t)slots.n_slots, -1);
    if (nready < 0) {
      if (errno == EINTR) continue;
      break; /* a real poll() error -- stop serving, same as the old accept loop's own break */
    }

    /* New connections on the listener -- drain fully (level-triggered
     * poll() only promises AT LEAST one is ready, not exactly one). */
    if (slots.pfds[0].revents & POLLIN) {
      for (;;) {
        int cfd = accept(fd, NULL, NULL);
        if (cfd < 0) {
          if (errno == EINTR) continue;
          break; /* EAGAIN (no more queued connections) or a real error -- either way, done for this wake */
        }
        set_nonblocking(cfd);
        int one = 1;
        setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

        Conn *c = GC_MALLOC(sizeof(Conn));
        c->fd = cfd;
        c->app = app;
        c->buf = sdsempty();
        c->last_len = 0;
        c->phase = CONN_READING_HEADERS;
        c->chunk_body = NULL;
        c->remote_addr[0] = 0;
        struct sockaddr_storage peer;
        socklen_t peer_len = sizeof(peer);
        if (getpeername(cfd, (struct sockaddr *)&peer, &peer_len) == 0) {
          if (peer.ss_family == AF_INET) {
            inet_ntop(AF_INET, &((struct sockaddr_in *)&peer)->sin_addr, c->remote_addr, sizeof(c->remote_addr));
          } else if (peer.ss_family == AF_INET6) {
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *)&peer)->sin6_addr, c->remote_addr, sizeof(c->remote_addr));
          }
        }
        slots_add(&slots, cfd, POLLIN, c);
      }
    }

    /* Existing connections: drain what's readable, advance parse state,
     * and either keep waiting, dispatch, or close. Reverse iteration so
     * slots_remove's swap-with-last never skips or re-processes a slot
     * within this same pass: everything above index i has already been
     * fully handled, so whatever gets swapped INTO position i (the
     * current highest surviving slot) was either already handled too
     * (safe to leave unvisited again this pass) or is i itself (a
     * no-op). */
    for (int i = slots.n_slots - 1; i >= slots.reserved_slots; i--) {
      if (!(slots.pfds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
      Conn *c = slots.pconns[i];
      int drop = 0;
      for (;;) {
        ssize_t r = conn_read_into(c);
        if (r == -2) break; /* no more data available right now */
        if (r == -1) {
          close(c->fd);
          drop = 1;
          break;
        }
        int adv = conn_advance(c);
        if (adv == -1) {
          close(c->fd);
          drop = 1;
          break;
        }
        if (adv == 1) {
          sds out = dispatch_with_recovery(g_inline_vm, c);
          write_all_sds(c->fd, out);
          sdsfree(out);
          if (c->chunk_body) {
            sdsfree(c->chunk_body);
            c->chunk_body = NULL;
          }
          if (!c->keep_alive) {
            close(c->fd);
            drop = 1;
          } else {
            conn_reset_for_next_request(c);
          }
          break;
        }
        /* adv == 0: still incomplete -- loop again in case more is
         * already sitting in the kernel's receive buffer from this same
         * readiness event, otherwise conn_read_into hits EAGAIN and we
         * fall out to wait for the next POLLIN. */
      }
      if (drop) slots_remove(&slots, i); /* handled and closed */
    }
  }

  return v_box(srv, BOX_KIND_MUX_SERVER);
}

static Value bi_mux_base_url(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mux-base-url");
  MuxServer *srv = as_mux_server(args[0], "mux-base-url");
  char buf[300];
  int len = snprintf(buf, sizeof(buf), "http://%s:%s", srv->host, srv->port);
  return v_gcstr(buf, (size_t)len);
}

static Value bi_mux_address(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 1, "mux-address");
  MuxServer *srv = as_mux_server(args[0], "mux-address");
  Value alist = v_nil();
  alist = creme_cons(vm, creme_cons(vm, v_litstr("port"), v_gcstr(srv->port, strlen(srv->port))), alist);
  alist = creme_cons(vm, creme_cons(vm, v_litstr("host"), v_gcstr(srv->host, strlen(srv->host))), alist);
  return alist;
}

static Value bi_mux_close(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "mux-close!");
  MuxServer *srv = as_mux_server(args[0], "mux-close!");
  if (srv->uses_pool) {
    /* Every current pool listener, permanent or grown -- closing each
     * one makes that worker's own poll() error out and return, same
     * mechanism the inline/non-pool modes already rely on for `fd`. */
    pthread_mutex_lock(&g_pool_fds.mu);
    for (int i = 0; i < g_pool_fds.n; i++) close(g_pool_fds.fds[i]);
    g_pool_fds.n = 0; /* drop them so a shrinking worker can't close them again */
    pthread_mutex_unlock(&g_pool_fds.mu);
  } else {
    close(srv->fd);
  }
  return v_nil();
}

void creme_register_mux_builtins(VM *vm) {
  creme_register_builtin(vm, "mux-router", bi_mux_router);
  creme_register_builtin(vm, "mux-router?", bi_mux_router_p);
  creme_register_builtin(vm, "mux-get!", bi_mux_get);
  creme_register_builtin(vm, "mux-head!", bi_mux_head);
  creme_register_builtin(vm, "mux-post!", bi_mux_post);
  creme_register_builtin(vm, "mux-put!", bi_mux_put);
  creme_register_builtin(vm, "mux-delete!", bi_mux_delete);
  creme_register_builtin(vm, "mux-patch!", bi_mux_patch);
  creme_register_builtin(vm, "mux-use!", bi_mux_use);
  creme_register_builtin(vm, "mux-listen!", bi_mux_listen);
  creme_register_builtin(vm, "mux-base-url", bi_mux_base_url);
  creme_register_builtin(vm, "mux-address", bi_mux_address);
  creme_register_builtin(vm, "mux-close!", bi_mux_close);
}

#endif /* CREME_WITH_MUX */
