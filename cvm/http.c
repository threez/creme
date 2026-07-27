/* (creme http) — see http.h. A port of src/scheme/modules/creme/http.cr:
 * a plain HTTP/1.1 CLIENT (http-get/-head/-delete/-post/-put/-patch/
 * -request). Crystal's own `require "http/client"` is standard
 * library, not an external shard. Response format matches native
 * exactly: an alist (("status" . code) ("headers" . ((name . value)
 * ...)) ("body" . "...")).
 *
 * TLS/HTTPS is a deliberate scope cut, not an oversight: this project's
 * own spec suite (spec/scheme/modules/creme/http_spec.cr) spins up a
 * real local HTTP::Server and every single case hits plain
 * http://127.0.0.1:<port> -- there is zero HTTPS coverage anywhere to
 * even verify a TLS implementation against, and a real TLS stack is a
 * whole separate undertaking (this project already links OpenSSL for
 * (creme actor)'s HMAC handshake and (creme digest), but never touches
 * OpenSSL's own SSL/TLS layer). http-get/etc. abort with a clear
 * "https is not supported" message on an https:// URL rather than
 * silently doing something wrong.
 *
 * Always sends "Connection: close" and reads the ENTIRE response by
 * draining the socket until the peer closes it, rather than tracking
 * Content-Length precisely while receiving -- simple and correct either
 * way (a real HTTP/1.1 server closes the connection once it's honored a
 * client's own Connection: close, confirmed empirically against this
 * project's own native HTTP::Server), and handles a chunked Transfer-
 * Encoding response too, decoded as a second pass over whatever bytes
 * were already read (see dechunk() below) rather than needing to track
 * chunk boundaries mid-stream. */
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <gc.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "http.h"

/* ---- small growable buffer (this file's own self-contained copy --
 * same shape as actor.c's WBuf/json.c's GBuf, kept separate rather than
 * shared across translation units, matching this project's existing
 * per-file convention). ---- */
typedef struct {
  char *buf;
  int len, cap;
} HBuf;

static void hbuf_init(HBuf *b) {
  b->cap = 256;
  b->buf = GC_MALLOC((size_t)b->cap);
  b->len = 0;
}

static void hbuf_reserve(HBuf *b, int extra) {
  if (b->len + extra <= b->cap) return;
  int newcap = b->cap * 2;
  while (newcap < b->len + extra) newcap *= 2;
  char *nb = GC_MALLOC((size_t)newcap);
  memcpy(nb, b->buf, (size_t)b->len);
  b->buf = nb;
  b->cap = newcap;
}

static void hbuf_puts(HBuf *b, const char *s, int n) {
  hbuf_reserve(b, n);
  memcpy(b->buf + b->len, s, (size_t)n);
  b->len += n;
}

static void hbuf_putstr(HBuf *b, const char *s) { hbuf_puts(b, s, (int)strlen(s)); }

static void hbuf_printf(HBuf *b, const char *fmt, ...) {
  char tmp[256];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  if (n < (int)sizeof(tmp)) {
    hbuf_puts(b, tmp, n);
    return;
  }
  char *big = GC_MALLOC((size_t)n + 1);
  va_start(ap, fmt);
  vsnprintf(big, (size_t)n + 1, fmt, ap);
  va_end(ap);
  hbuf_puts(b, big, n);
}

static char *dupn(const char *s, int len) {
  char *out = GC_MALLOC((size_t)(len > 0 ? len : 1) + 1);
  if (len > 0) memcpy(out, s, (size_t)len);
  out[len > 0 ? len : 0] = '\0';
  return out;
}

/* T_STR is mutable (string-set!) -- a Value pointing directly at a
 * string literal in .rodata would segfault the moment Scheme code
 * mutated it, so every literal handed to Scheme (the alist keys below)
 * needs its own GC-owned copy (mirrors sql.c/mux.c's own v_litstr). */
static Value v_litstr(const char *s) { return v_str(dupn(s, (int)strlen(s)), (int)strlen(s)); }

static int ci_eq(const char *a, const char *b) {
  while (*a && *b) {
    if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return 0;
    a++;
    b++;
  }
  return *a == '\0' && *b == '\0';
}

/* Case-insensitive substring search -- just enough to spot "chunked"
 * inside a Transfer-Encoding header value, not a general utility. */
static int ci_contains(const char *haystack, const char *needle) {
  size_t nlen = strlen(needle);
  for (const char *p = haystack; *p; p++) {
    size_t i = 0;
    while (i < nlen && p[i] && tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i])) i++;
    if (i == nlen) return 1;
  }
  return 0;
}

/* ---- URL parsing: http://host[:port][/path[?query]] ---------------- */

typedef struct {
  char *host;
  int port;
  char *path;
} ParsedUrl;

static void parse_url(const char *url, int len, ParsedUrl *out, const char *who) {
  const char *scheme_end = memchr(url, ':', (size_t)len);
  if (!scheme_end || scheme_end + 2 >= url + len || scheme_end[1] != '/' || scheme_end[2] != '/') {
    cvm_abort("%s: invalid url '%.*s': missing scheme", who, len, url);
  }
  int scheme_len = (int)(scheme_end - url);
  if (scheme_len == 5 && memcmp(url, "https", 5) == 0) {
    cvm_abort("%s: https is not supported by this cvm build (no TLS)", who);
  }
  if (!(scheme_len == 4 && memcmp(url, "http", 4) == 0)) {
    cvm_abort("%s: invalid url '%.*s': unsupported scheme", who, len, url);
  }

  const char *rest = scheme_end + 3;
  int rest_len = len - (int)(rest - url);
  if (rest_len == 0) cvm_abort("%s: invalid url '%.*s': missing host", who, len, url);

  const char *slash = memchr(rest, '/', (size_t)rest_len);
  const char *host_port = rest;
  int host_port_len = slash ? (int)(slash - rest) : rest_len;
  const char *path = slash ? slash : "/";
  int path_len = slash ? (rest_len - host_port_len) : 1;
  if (host_port_len == 0) cvm_abort("%s: invalid url '%.*s': missing host", who, len, url);

  const char *colon = memchr(host_port, ':', (size_t)host_port_len);
  int host_len = colon ? (int)(colon - host_port) : host_port_len;
  int port = 80;
  if (colon) {
    char portbuf[16];
    int plen = host_port_len - host_len - 1;
    if (plen <= 0 || plen >= (int)sizeof(portbuf)) cvm_abort("%s: invalid url '%.*s': bad port", who, len, url);
    memcpy(portbuf, colon + 1, (size_t)plen);
    portbuf[plen] = '\0';
    port = atoi(portbuf);
  }

  out->host = dupn(host_port, host_len);
  out->port = port;
  out->path = dupn(path, path_len);
}

/* ---- request headers (a Scheme (name . value) alist) ---------------- */

typedef struct HeaderLine {
  char *name;
  char *value;
  struct HeaderLine *next;
} HeaderLine;

static HeaderLine *parse_headers_arg(Value v, const char *who) {
  HeaderLine *head = NULL, **tail = &head;
  Value cur = v;
  while (cur.tag == T_PAIR) {
    Value entry = cur.as.pair->car;
    if (entry.tag != T_PAIR || entry.as.pair->car.tag != T_STR || entry.as.pair->cdr.tag != T_STR) {
      cvm_abort("%s: expected (name . value) pair in headers", who);
    }
    HeaderLine *hl = GC_MALLOC(sizeof(HeaderLine));
    hl->name = dupn(entry.as.pair->car.as.str.chars, entry.as.pair->car.as.str.len);
    hl->value = dupn(entry.as.pair->cdr.as.str.chars, entry.as.pair->cdr.as.str.len);
    hl->next = NULL;
    *tail = hl;
    tail = &hl->next;
    cur = cur.as.pair->cdr;
  }
  if (cur.tag != T_NIL) cvm_abort("%s: expected a proper list of (name . value) headers", who);
  return head;
}

/* ---- networking ------------------------------------------------------ */

static int connect_tcp(const char *host, int port) {
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;
  struct addrinfo *res;
  char portbuf[16];
  snprintf(portbuf, sizeof(portbuf), "%d", port);
  if (getaddrinfo(host, portbuf, &hints, &res) != 0) return -1;
  int fd = -1;
  for (struct addrinfo *rp = res; rp; rp = rp->ai_next) {
    fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (fd < 0) continue;
    if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  if (fd >= 0) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  }
  return fd;
}

static int write_all(int fd, const char *buf, size_t n) {
  size_t left = n;
  const char *p = buf;
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

static void read_all_until_eof(int fd, HBuf *out) {
  char chunk[4096];
  for (;;) {
    ssize_t r = read(fd, chunk, sizeof(chunk));
    if (r < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (r == 0) break;
    hbuf_puts(out, chunk, (int)r);
  }
}

/* ---- response parsing -------------------------------------------------- */

/* Finds the end of the line starting at `pos` (the offset of its own
 * "\r"/"\n", i.e. NOT including the terminator) and sets *next_pos to
 * just past the terminator. Returns -1 if there's no more "\n" at all. */
static int find_line_end(const char *buf, int len, int pos, int *next_pos) {
  for (int i = pos; i < len; i++) {
    if (buf[i] == '\n') {
      int end = (i > pos && buf[i - 1] == '\r') ? i - 1 : i;
      if (next_pos) *next_pos = i + 1;
      return end;
    }
  }
  return -1;
}

static int parse_status_line(const char *buf, int line_len, int *status_out) {
  int i = 0;
  while (i < line_len && buf[i] != ' ') i++;
  if (i >= line_len) return -1;
  i++;
  int start = i;
  while (i < line_len && buf[i] >= '0' && buf[i] <= '9') i++;
  if (i == start) return -1;
  char numbuf[8];
  int n = i - start;
  if (n >= (int)sizeof(numbuf)) return -1;
  memcpy(numbuf, buf + start, (size_t)n);
  numbuf[n] = '\0';
  *status_out = atoi(numbuf);
  return 0;
}

/* Decodes a chunked-transfer-encoded body: [hex size]\r\n[data]\r\n...
 * ending in a "0\r\n" terminating chunk. Any chunk extension after ';'
 * on the size line, and any trailer headers after the terminating
 * chunk, are ignored -- not exercised by anything this client talks to. */
static char *dechunk(const char *body, int body_len, int *out_len) {
  HBuf out;
  hbuf_init(&out);
  int pos = 0;
  for (;;) {
    int next;
    int line_end = find_line_end(body, body_len, pos, &next);
    if (line_end < 0) break;
    int slen = line_end - pos;
    int hexlen = 0;
    while (hexlen < slen && isxdigit((unsigned char)body[pos + hexlen])) hexlen++;
    if (hexlen == 0) break;
    char sizebuf[16];
    if (hexlen >= (int)sizeof(sizebuf)) break;
    memcpy(sizebuf, body + pos, (size_t)hexlen);
    sizebuf[hexlen] = '\0';
    long chunk_size = strtol(sizebuf, NULL, 16);
    pos = next;
    if (chunk_size <= 0) break; /* terminating chunk */
    if (pos + (int)chunk_size > body_len) {
      hbuf_puts(&out, body + pos, body_len - pos); /* truncated -- best effort */
      break;
    }
    hbuf_puts(&out, body + pos, (int)chunk_size);
    pos += (int)chunk_size;
    if (pos < body_len && body[pos] == '\r') pos++;
    if (pos < body_len && body[pos] == '\n') pos++;
  }
  *out_len = out.len;
  return out.buf;
}

/* ---- the shared request/response driver behind every http-* builtin --- */

static Value http_do(VM *vm, const char *method, Value url_v, Value headers_v, int has_headers, Value body_v, int has_body, const char *who) {
  if (url_v.tag != T_STR) cvm_abort("%s: expected string, got a non-string value", who);
  ParsedUrl u;
  parse_url(url_v.as.str.chars, url_v.as.str.len, &u, who);

  HeaderLine *user_headers = NULL;
  if (has_headers) {
    if (headers_v.tag != T_PAIR && headers_v.tag != T_NIL) cvm_abort("%s: expected a headers alist", who);
    user_headers = parse_headers_arg(headers_v, who);
  }

  const char *req_body = NULL;
  int req_body_len = 0;
  if (has_body) {
    if (body_v.tag != T_STR) cvm_abort("%s: expected a string body", who);
    req_body = body_v.as.str.chars;
    req_body_len = body_v.as.str.len;
  }

  int fd = connect_tcp(u.host, u.port);
  if (fd < 0) cvm_abort("%s: connection to %s:%d failed", who, u.host, u.port);

  HBuf req;
  hbuf_init(&req);
  hbuf_printf(&req, "%s %s HTTP/1.1\r\n", method, u.path);
  hbuf_printf(&req, "Host: %s:%d\r\n", u.host, u.port);
  hbuf_putstr(&req, "Connection: close\r\n");
  for (HeaderLine *h = user_headers; h; h = h->next) hbuf_printf(&req, "%s: %s\r\n", h->name, h->value);
  if (has_body) hbuf_printf(&req, "Content-Length: %d\r\n", req_body_len);
  hbuf_putstr(&req, "\r\n");
  if (has_body && req_body_len > 0) hbuf_puts(&req, req_body, req_body_len);

  if (write_all(fd, req.buf, (size_t)req.len) != 0) {
    close(fd);
    cvm_abort("%s: connection to %s:%d failed while sending the request", who, u.host, u.port);
  }

  HBuf resp;
  hbuf_init(&resp);
  read_all_until_eof(fd, &resp);
  close(fd);

  int next;
  int status_line_end = find_line_end(resp.buf, resp.len, 0, &next);
  if (status_line_end < 0) cvm_abort("%s: %s:%d closed the connection without sending a response", who, u.host, u.port);
  int status;
  if (parse_status_line(resp.buf, status_line_end, &status) != 0) cvm_abort("%s: malformed status line from %s:%d", who, u.host, u.port);

  int pos = next;
  int chunked = 0;
  HeaderLine *resp_headers = NULL, **rt = &resp_headers;
  int n_headers = 0;
  for (;;) {
    int line_end = find_line_end(resp.buf, resp.len, pos, &next);
    if (line_end < 0) break; /* malformed -- treat whatever's left as body */
    if (line_end == pos) {
      pos = next;
      break; /* blank line: end of headers */
    }
    const char *colon = memchr(resp.buf + pos, ':', (size_t)(line_end - pos));
    if (colon) {
      int name_len = (int)(colon - (resp.buf + pos));
      const char *value_start = colon + 1;
      const char *line_endp = resp.buf + line_end;
      while (value_start < line_endp && *value_start == ' ') value_start++;
      int value_len = (int)(line_endp - value_start);
      HeaderLine *hl = GC_MALLOC(sizeof(HeaderLine));
      hl->name = dupn(resp.buf + pos, name_len);
      hl->value = dupn(value_start, value_len);
      hl->next = NULL;
      *rt = hl;
      rt = &hl->next;
      n_headers++;
      if (ci_eq(hl->name, "Transfer-Encoding") && ci_contains(hl->value, "chunked")) chunked = 1;
    }
    pos = next;
  }

  const char *raw_body = resp.buf + pos;
  int raw_body_len = resp.len - pos;
  char *final_body;
  int final_len;
  if (chunked) {
    final_body = dechunk(raw_body, raw_body_len, &final_len);
  } else {
    final_body = dupn(raw_body, raw_body_len);
    final_len = raw_body_len;
  }

  HeaderLine **arr = GC_MALLOC(sizeof(HeaderLine *) * (size_t)(n_headers > 0 ? n_headers : 1));
  int idx = 0;
  for (HeaderLine *h = resp_headers; h; h = h->next) arr[idx++] = h;
  Value header_list = v_nil();
  for (int i = n_headers - 1; i >= 0; i--) {
    Value pair = cvm_cons(vm, v_litstr(arr[i]->name), v_litstr(arr[i]->value));
    header_list = cvm_cons(vm, pair, header_list);
  }

  Value status_pair = cvm_cons(vm, v_litstr("status"), v_int(status));
  Value headers_pair = cvm_cons(vm, v_litstr("headers"), header_list);
  Value body_pair = cvm_cons(vm, v_litstr("body"), v_str(final_body, final_len));
  return cvm_cons(vm, status_pair, cvm_cons(vm, headers_pair, cvm_cons(vm, body_pair, v_nil())));
}

static Value bi_http_get(VM *vm, Value *args, int nargs) {
  if (nargs < 1) cvm_abort("http-get: expected a url");
  return http_do(vm, "GET", args[0], nargs >= 2 ? args[1] : v_nil(), nargs >= 2, v_nil(), 0, "http-get");
}

static Value bi_http_head(VM *vm, Value *args, int nargs) {
  if (nargs < 1) cvm_abort("http-head: expected a url");
  return http_do(vm, "HEAD", args[0], nargs >= 2 ? args[1] : v_nil(), nargs >= 2, v_nil(), 0, "http-head");
}

static Value bi_http_delete(VM *vm, Value *args, int nargs) {
  if (nargs < 1) cvm_abort("http-delete: expected a url");
  return http_do(vm, "DELETE", args[0], nargs >= 2 ? args[1] : v_nil(), nargs >= 2, v_nil(), 0, "http-delete");
}

static Value bi_http_post(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("http-post: expected (url body [headers])");
  return http_do(vm, "POST", args[0], nargs >= 3 ? args[2] : v_nil(), nargs >= 3, args[1], 1, "http-post");
}

static Value bi_http_put(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("http-put: expected (url body [headers])");
  return http_do(vm, "PUT", args[0], nargs >= 3 ? args[2] : v_nil(), nargs >= 3, args[1], 1, "http-put");
}

static Value bi_http_patch(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("http-patch: expected (url body [headers])");
  return http_do(vm, "PATCH", args[0], nargs >= 3 ? args[2] : v_nil(), nargs >= 3, args[1], 1, "http-patch");
}

static Value bi_http_request(VM *vm, Value *args, int nargs) {
  if (nargs < 2 || args[0].tag != T_STR) cvm_abort("http-request: expected (method url [headers [body]])");
  char *method = dupn(args[0].as.str.chars, args[0].as.str.len);
  return http_do(vm, method, args[1], nargs >= 3 ? args[2] : v_nil(), nargs >= 3, nargs >= 4 ? args[3] : v_nil(), nargs >= 4, "http-request");
}

void cvm_register_http_builtins(VM *vm) {
  cvm_register_builtin(vm, "http-get", bi_http_get);
  cvm_register_builtin(vm, "http-head", bi_http_head);
  cvm_register_builtin(vm, "http-delete", bi_http_delete);
  cvm_register_builtin(vm, "http-post", bi_http_post);
  cvm_register_builtin(vm, "http-put", bi_http_put);
  cvm_register_builtin(vm, "http-patch", bi_http_patch);
  cvm_register_builtin(vm, "http-request", bi_http_request);
}
