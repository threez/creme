/* (creme mux) — see mux.h.
 *
 * Request alist: (("method" . STR) ("path" . STR) ("path-params" . ALIST)
 * ("headers" . ALIST) ("remote-addr" . STR) ("body" . STR)) — exactly
 * mux.cr's own `request_to_scheme` contract. Response alist read back:
 * (("status" . N) ("headers" . ALIST) ("body" . STR)) — mux.cr's
 * `write_response`, minus its streaming-callable-body case (never used by
 * the demo-todo app this targets).
 *
 * facil.io has no router of its own (no radix tree, no path-param
 * matching) — routes are a small linear-scanned table (":name" segments,
 * matching (creme mux)'s own path-param syntax that surf.sld already
 * assumes), which is plenty for an app with a handful of routes.
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
#include <gc.h>
#include <http.h>
#include <string.h>

#include "mux.h"

typedef struct {
  char *method;   /* "GET", "POST", ... (uppercase, matches h->method) */
  char *pattern;  /* e.g. "/todos/:id/complete" */
  Value handler;  /* (lambda (request) response-alist) */
} MuxRoute;

typedef struct {
  MuxRoute *routes;
  int n_routes, cap_routes;
  Value *middlewares; /* each (lambda (request next) ...) */
  int n_middlewares, cap_middlewares;
} MuxApp;

typedef struct {
  MuxApp *app;
  intptr_t uuid;
  char *host;
  char *port;
} MuxServer;

static VM *g_vm; /* set once at registration -- on_request has no way to
                  * receive extra context beyond http_s itself. */

static MuxApp *as_mux_app(Value v, const char *who) {
  if (v.tag != T_BOX || v.as.box.kind != BOX_KIND_MUX_ROUTER) cvm_abort("%s: expected a mux router", who);
  return (MuxApp *)v.as.box.ptr;
}

static MuxServer *as_mux_server(Value v, const char *who) {
  if (v.tag != T_BOX || v.as.box.kind != BOX_KIND_MUX_SERVER) cvm_abort("%s: expected a mux server", who);
  return (MuxServer *)v.as.box.ptr;
}

static char *gc_strndup(const char *s, size_t len) {
  char *copy = GC_MALLOC(len ? len : 1);
  memcpy(copy, s, len);
  return copy;
}

static Value v_gcstr(const char *s, size_t len) {
  return v_str(gc_strndup(s, len), (int)len);
}

/* ---- registration ---- */

static Value bi_mux_router(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  MuxApp *app = GC_MALLOC(sizeof(MuxApp));
  return v_box(app, BOX_KIND_MUX_ROUTER);
}

static Value bi_mux_router_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("mux-router?: expected an argument");
  return v_bool(args[0].tag == T_BOX && args[0].as.box.kind == BOX_KIND_MUX_ROUTER);
}

static void register_route(VM *vm, Value *args, int nargs, const char *method) {
  (void)vm;
  if (nargs < 3 || args[1].tag != T_STR) cvm_abort("mux-%s!: expected (router path handler)", method);
  MuxApp *app = as_mux_app(args[0], "mux-route!");
  if (app->n_routes >= app->cap_routes) {
    app->cap_routes = app->cap_routes ? app->cap_routes * 2 : 8;
    app->routes = GC_REALLOC(app->routes, sizeof(MuxRoute) * (size_t)app->cap_routes);
  }
  MuxRoute *r = &app->routes[app->n_routes++];
  r->method = (char *)method;
  r->pattern = gc_strndup(args[1].as.str.chars, (size_t)args[1].as.str.len);
  r->handler = args[2];
}

static Value bi_mux_get(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "GET"); return v_nil(); }
static Value bi_mux_head(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "HEAD"); return v_nil(); }
static Value bi_mux_post(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "POST"); return v_nil(); }
static Value bi_mux_put(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "PUT"); return v_nil(); }
static Value bi_mux_delete(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "DELETE"); return v_nil(); }
static Value bi_mux_patch(VM *vm, Value *args, int nargs) { register_route(vm, args, nargs, "PATCH"); return v_nil(); }

static Value bi_mux_use(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("mux-use!: expected (router middleware)");
  MuxApp *app = as_mux_app(args[0], "mux-use!");
  if (app->n_middlewares >= app->cap_middlewares) {
    app->cap_middlewares = app->cap_middlewares ? app->cap_middlewares * 2 : 4;
    app->middlewares = GC_REALLOC(app->middlewares, sizeof(Value) * (size_t)app->cap_middlewares);
  }
  app->middlewares[app->n_middlewares++] = args[1];
  return v_nil();
}

/* ---- path matching: ":name" segments, mirroring surf.sld's own
 * surf-segment-literal comment ("matching (creme mux)'s own radix
 * path-param syntax"). Small fixed-size segment buffers -- routes in any
 * app this targets are short, fixed shapes (never user-controlled). ---- */

#define MUX_MAX_SEGS 8
#define MUX_SEG_LEN 64

static int split_segments(const char *s, char segs[][MUX_SEG_LEN]) {
  int n = 0;
  const char *p = s;
  if (*p == '/') p++;
  while (*p && n < MUX_MAX_SEGS) {
    const char *end = strchr(p, '/');
    size_t len = end ? (size_t)(end - p) : strlen(p);
    if (len >= MUX_SEG_LEN) len = MUX_SEG_LEN - 1;
    memcpy(segs[n], p, len);
    segs[n][len] = 0;
    n++;
    if (!end) break;
    p = end + 1;
  }
  return n;
}

static int match_route(VM *vm, const MuxRoute *route, const char *path, Value *out_params) {
  char psegs[MUX_MAX_SEGS][MUX_SEG_LEN], rsegs[MUX_MAX_SEGS][MUX_SEG_LEN];
  int np = split_segments(route->pattern, psegs);
  int nr = split_segments(path, rsegs);
  if (np != nr) return 0;
  Value params = v_nil();
  for (int i = 0; i < np; i++) {
    if (psegs[i][0] == ':') {
      params = cvm_cons(vm, cvm_cons(vm, v_gcstr(psegs[i] + 1, strlen(psegs[i] + 1)), v_gcstr(rsegs[i], strlen(rsegs[i]))), params);
    } else if (strcmp(psegs[i], rsegs[i]) != 0) {
      return 0;
    }
  }
  *out_params = params;
  return 1;
}

/* ---- alist helpers ---- */

static Value alist_ref(Value alist, const char *key) {
  size_t klen = strlen(key);
  Value cur = alist;
  while (cur.tag == T_PAIR) {
    Value pair = cur.as.pair->car;
    if (pair.tag == T_PAIR && pair.as.pair->car.tag == T_STR &&
        (size_t)pair.as.pair->car.as.str.len == klen &&
        memcmp(pair.as.pair->car.as.str.chars, key, klen) == 0) {
      return pair.as.pair->cdr;
    }
    cur = cur.as.pair->cdr;
  }
  return v_nil();
}

/* ---- request building ---- */

/* facil.io normalizes header names to lowercase internally (see
 * http_internal.c's http_lib_init: `fiobj_str_new("accept", 6)` etc.) --
 * the real mux.cr exposes Crystal's own HTTP::Headers, which normalizes to
 * Title-Case ("Accept", "Content-Type") instead, and surf.sld's
 * surf-header does an exact-string `assoc` lookup assuming that casing.
 * Converting here keeps the header alist contract identical regardless of
 * which server built it. */
static char *title_case_header_name(const char *lower, size_t len) {
  char *buf = GC_MALLOC(len ? len : 1);
  int cap_next = 1;
  for (size_t i = 0; i < len; i++) {
    char c = lower[i];
    if (cap_next && c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    buf[i] = c;
    cap_next = (c == '-');
  }
  return buf;
}

typedef struct {
  VM *vm;
  Value alist;
} HeaderIterCtx;

static int header_iter_cb(FIOBJ obj, void *arg) {
  HeaderIterCtx *ctx = (HeaderIterCtx *)arg;
  FIOBJ key = fiobj_hash_key_in_loop();
  fio_str_info_s k = fiobj_obj2cstr(key);
  /* A repeated header (e.g. multiple Cookie lines) is stored as a FIOBJ
   * Array; take the first value only -- this app never sends/reads a
   * repeated request header. */
  FIOBJ val = obj;
  if (FIOBJ_TYPE_IS(val, FIOBJ_T_ARRAY) && fiobj_ary_count(val) > 0) val = fiobj_ary_index(val, 0);
  fio_str_info_s v = fiobj_obj2cstr(val);
  Value name = v_str(title_case_header_name(k.data, k.len), (int)k.len);
  Value value = v_gcstr(v.data, v.len);
  ctx->alist = cvm_cons(ctx->vm, cvm_cons(ctx->vm, name, value), ctx->alist);
  return 0;
}

static Value build_request(VM *vm, http_s *h, Value path_params) {
  fio_str_info_s method = fiobj_obj2cstr(h->method);
  fio_str_info_s path = fiobj_obj2cstr(h->path);
  fio_str_info_s remote = http_peer_addr(h);

  HeaderIterCtx ctx = {vm, v_nil()};
  if (h->headers) fiobj_each1(h->headers, 0, header_iter_cb, &ctx);

  Value body;
  if (h->body) {
    fio_str_info_s b = fiobj_data_read(h->body, 0);
    body = v_gcstr(b.data, b.len);
  } else {
    body = v_str("", 0);
  }

  Value request = v_nil();
  request = cvm_cons(vm, cvm_cons(vm, v_str("body", 4), body), request);
  request = cvm_cons(vm, cvm_cons(vm, v_str("remote-addr", 11), v_gcstr(remote.data, remote.len)), request);
  request = cvm_cons(vm, cvm_cons(vm, v_str("headers", 7), ctx.alist), request);
  request = cvm_cons(vm, cvm_cons(vm, v_str("path-params", 11), path_params), request);
  request = cvm_cons(vm, cvm_cons(vm, v_str("path", 4), v_gcstr(path.data, path.len)), request);
  request = cvm_cons(vm, cvm_cons(vm, v_str("method", 6), v_gcstr(method.data, method.len)), request);
  return request;
}

/* ---- response writing ---- */

static void write_response(VM *vm, http_s *h, Value response) {
  Value status_v = alist_ref(response, "status");
  h->status = (status_v.tag == T_INT) ? (int)status_v.as.i : 200;

  Value cur = alist_ref(response, "headers");
  while (cur.tag == T_PAIR) {
    Value pair = cur.as.pair->car;
    if (pair.tag == T_PAIR && pair.as.pair->car.tag == T_STR && pair.as.pair->cdr.tag == T_STR) {
      Value k = pair.as.pair->car, v = pair.as.pair->cdr;
      http_set_header2(h, (fio_str_info_s){.data = (char *)k.as.str.chars, .len = (size_t)k.as.str.len},
                       (fio_str_info_s){.data = (char *)v.as.str.chars, .len = (size_t)v.as.str.len});
    }
    cur = cur.as.pair->cdr;
  }

  Value body = alist_ref(response, "body");
  if (body.tag == T_STR) {
    http_send_body(h, (void *)body.as.str.chars, (uintptr_t)body.as.str.len);
  } else if (body.tag == T_CLOSURE || body.tag == T_BUILTIN) {
    /* mux.cr's own "streaming callable body" case: the handler passed a
     * (lambda (port) ...) instead of a pre-built string (surf-html/
     * surf-json pass write-page!/write-todos-json! straight through
     * unconverted -- see surf.sld's own `(if (or (string? body)
     * (procedure? body)) body ...)`). This prototype has no true
     * incremental streaming port (Port is a plain in-memory buffer, same
     * one open-output-string already uses) -- buffer the whole body, then
     * send it in one shot, which is behaviorally equivalent for any
     * caller that isn't relying on partial flushes. */
    Port *port = GC_MALLOC(sizeof(Port));
    Value port_val = v_port(port);
    cvm_apply(vm, body, &port_val, 1);
    http_send_body(h, port->buf, (uintptr_t)port->len);
  } else {
    http_finish(h);
  }
}

/* ---- middleware "next" thunk ----
 * See this file's own header comment: middleware here can only observe the
 * final status, not rewrite the response. Single global slot, safe only
 * because facil.io is run single-threaded (.threads = 1, .workers = 1) --
 * matches every other twin's own single-core reasoning. */
static Value g_next_status;

static Value bi_next_thunk(VM *vm, Value *args, int nargs) {
  (void)vm;
  (void)args;
  (void)nargs;
  return g_next_status;
}

/* ---- dispatch ---- */

static void on_request(http_s *h) {
  MuxApp *app = (MuxApp *)http_settings(h)->udata;
  fio_str_info_s method = fiobj_obj2cstr(h->method);
  fio_str_info_s path = fiobj_obj2cstr(h->path);

  const MuxRoute *matched = NULL;
  Value path_params = v_nil();
  for (int i = 0; i < app->n_routes; i++) {
    if (method.len != strlen(app->routes[i].method) || memcmp(method.data, app->routes[i].method, method.len) != 0) continue;
    char path_buf[256];
    size_t plen = path.len < sizeof(path_buf) - 1 ? path.len : sizeof(path_buf) - 1;
    memcpy(path_buf, path.data, plen);
    path_buf[plen] = 0;
    if (match_route(g_vm, &app->routes[i], path_buf, &path_params)) {
      matched = &app->routes[i];
      break;
    }
  }
  if (!matched) {
    http_send_error(h, 404);
    return;
  }

  Value request = build_request(g_vm, h, path_params);
  Value response = cvm_apply(g_vm, matched->handler, &request, 1);

  Value status_v = alist_ref(response, "status");
  g_next_status = (status_v.tag == T_INT) ? status_v : v_int(200);
  Value next = v_builtin(bi_next_thunk);
  for (int i = 0; i < app->n_middlewares; i++) {
    Value margs[2] = {request, next};
    cvm_apply(g_vm, app->middlewares[i], margs, 2);
  }

  write_response(g_vm, h, response);
}

/* ---- listen / close / introspection ---- */

static Value bi_mux_listen(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("mux-listen!: expected (router port [host])");
  MuxApp *app = as_mux_app(args[0], "mux-listen!");

  char port_buf[32];
  const char *port_str;
  if (args[1].tag == T_INT) {
    snprintf(port_buf, sizeof(port_buf), "%lld", (long long)args[1].as.i);
    port_str = port_buf;
  } else if (args[1].tag == T_STR) {
    size_t len = (size_t)args[1].as.str.len < sizeof(port_buf) - 1 ? (size_t)args[1].as.str.len : sizeof(port_buf) - 1;
    memcpy(port_buf, args[1].as.str.chars, len);
    port_buf[len] = 0;
    port_str = port_buf;
  } else {
    cvm_abort("mux-listen!: expected an integer or string port");
  }

  char host_buf[256] = "127.0.0.1";
  if (nargs >= 3 && args[2].tag == T_STR) {
    size_t len = (size_t)args[2].as.str.len < sizeof(host_buf) - 1 ? (size_t)args[2].as.str.len : sizeof(host_buf) - 1;
    memcpy(host_buf, args[2].as.str.chars, len);
    host_buf[len] = 0;
  }

  g_vm = vm;
  intptr_t uuid = http_listen(port_str, host_buf, .on_request = on_request, .log = 0, .udata = app);
  if (uuid == -1) cvm_abort("mux-listen!: failed to listen on %s:%s", host_buf, port_str);

  MuxServer *srv = GC_MALLOC(sizeof(MuxServer));
  srv->app = app;
  srv->uuid = uuid;
  srv->host = gc_strndup(host_buf, strlen(host_buf));
  srv->port = gc_strndup(port_str, strlen(port_str));

  /* http_listen only binds -- facil.io's reactor (accept/read/write on
   * registered sockets) doesn't run at all until fio_start() is called, and
   * fio_start() blocks the calling thread until the reactor stops (SIGINT/
   * SIGTERM, or fio_stop()). Starting it right here -- rather than letting
   * main.c run the rest of the script first and call it once at the very
   * end -- sidesteps a real design conflict: app.scm's own tail end
   * ((read-line) waiting for Enter, then mux-close!/sql-close as manual
   * cleanup) was written for the original single-process interactive
   * interpreter, where blocking on stdin is exactly what keeps the process
   * alive; a real deployed server has no such interactive step and should
   * just serve until killed. Blocking inside mux-listen! itself matches
   * that real-server behavior directly: this call simply doesn't return
   * until the reactor stops, at which point the script's own remaining
   * forms (read-line/mux-close!/sql-close) still run as ordinary best-
   * effort cleanup, matching Ctrl-C-then-graceful-exit. */
  fio_start(.threads = 1, .workers = 1);

  return v_box(srv, BOX_KIND_MUX_SERVER);
}

static Value bi_mux_base_url(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("mux-base-url: expected a server");
  MuxServer *srv = as_mux_server(args[0], "mux-base-url");
  char buf[300];
  int len = snprintf(buf, sizeof(buf), "http://%s:%s", srv->host, srv->port);
  return v_gcstr(buf, (size_t)len);
}

static Value bi_mux_address(VM *vm, Value *args, int nargs) {
  if (nargs < 1) cvm_abort("mux-address: expected a server");
  MuxServer *srv = as_mux_server(args[0], "mux-address");
  Value alist = v_nil();
  alist = cvm_cons(vm, cvm_cons(vm, v_str("port", 4), v_gcstr(srv->port, strlen(srv->port))), alist);
  alist = cvm_cons(vm, cvm_cons(vm, v_str("host", 4), v_gcstr(srv->host, strlen(srv->host))), alist);
  return alist;
}

static Value bi_mux_close(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("mux-close!: expected a server");
  MuxServer *srv = as_mux_server(args[0], "mux-close!");
  fio_close(srv->uuid);
  return v_nil();
}

void cvm_register_mux_builtins(VM *vm) {
  cvm_register_builtin(vm, "mux-router", bi_mux_router);
  cvm_register_builtin(vm, "mux-router?", bi_mux_router_p);
  cvm_register_builtin(vm, "mux-get!", bi_mux_get);
  cvm_register_builtin(vm, "mux-head!", bi_mux_head);
  cvm_register_builtin(vm, "mux-post!", bi_mux_post);
  cvm_register_builtin(vm, "mux-put!", bi_mux_put);
  cvm_register_builtin(vm, "mux-delete!", bi_mux_delete);
  cvm_register_builtin(vm, "mux-patch!", bi_mux_patch);
  cvm_register_builtin(vm, "mux-use!", bi_mux_use);
  cvm_register_builtin(vm, "mux-listen!", bi_mux_listen);
  cvm_register_builtin(vm, "mux-base-url", bi_mux_base_url);
  cvm_register_builtin(vm, "mux-address", bi_mux_address);
  cvm_register_builtin(vm, "mux-close!", bi_mux_close);
}
