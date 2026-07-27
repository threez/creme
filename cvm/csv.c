/* (creme csv) — see csv.h's own header comment.
 *
 * Unlike native's Scheme::Csv (a line-for-line derivation of Crystal
 * stdlib's own CSV, chunked-IO-optimized for multi-million-row imports —
 * see csv.cr's own header comment), this is a much smaller, single
 * generic row-parser (csv_parse_row below) driven through an abstract
 * CharSrc (next/peek function pointers over either a plain in-memory
 * buffer for the bulk csv-read/csv-write functions, or cvm_port_read_char/
 * cvm_port_peek_char for the streaming csv-reader/csv-writer) — no
 * chunked-refill/UTF-8-boundary-carry complexity, since cvm's own
 * strings/chars are already byte-wide throughout (see string-ref's own
 * "byte-wise" comment) and this prototype has no multi-million-row CSV
 * import to optimize for. Quoting/escaping (RFC4180: doubled quote_char
 * inside a quoted cell) and the "none/rfc/all" writer quoting modes
 * mirror native's Builder::Row exactly.
 */
#include <gc.h>
#include <stdlib.h>
#include <string.h>

#include "csv.h"

typedef struct {
  int (*next)(void *ctx);
  int (*peek)(void *ctx);
  void *ctx;
} CharSrc;

typedef struct {
  const char *buf;
  int len, pos;
} BufSrc;

static int buf_next(void *ctx) {
  BufSrc *s = ctx;
  return s->pos < s->len ? (unsigned char)s->buf[s->pos++] : -1;
}
static int buf_peek(void *ctx) {
  BufSrc *s = ctx;
  return s->pos < s->len ? (unsigned char)s->buf[s->pos] : -1;
}
static int port_next(void *ctx) { return cvm_port_read_char((Port *)ctx); }
static int port_peek(void *ctx) { return cvm_port_peek_char((Port *)ctx); }

/* Parses one row of cells from src. Returns 0 if there is nothing left
 * to parse (true EOF, no row at all) -- 1 otherwise, even for a blank
 * line (out_n = 0, mirroring native's own Lexer: a bare newline token
 * right at the start of a row produces a zero-cell row, distinct from a
 * trailing empty cell after a separator, which DOES produce an empty
 * T_STR cell -- see the `after` check below). */
static int csv_parse_row(CharSrc *src, char sep, char quote, Value **out_cells, int *out_n) {
  int c = src->peek(src->ctx);
  if (c < 0) return 0;
  if (c == '\n' || c == '\r') {
    src->next(src->ctx);
    if (c == '\r' && src->peek(src->ctx) == '\n') src->next(src->ctx);
    *out_cells = NULL;
    *out_n = 0;
    return 1;
  }

  int cap = 4, n = 0;
  Value *cells = GC_MALLOC(sizeof(Value) * (size_t)cap);
  for (;;) {
    int cellcap = 64, celllen = 0;
    char *cellbuf = GC_MALLOC((size_t)cellcap);
    int cc = src->peek(src->ctx);
    if (cc == (unsigned char)quote) {
      src->next(src->ctx); /* consume opening quote */
      for (;;) {
        int ch = src->next(src->ctx);
        if (ch < 0) break; /* unclosed quote at EOF -- lenient, stop here */
        if (ch == (unsigned char)quote) {
          if (src->peek(src->ctx) == (unsigned char)quote) {
            src->next(src->ctx);
            if (celllen >= cellcap) { cellcap *= 2; cellbuf = GC_REALLOC(cellbuf, (size_t)cellcap); }
            cellbuf[celllen++] = quote;
            continue;
          }
          break; /* closing quote */
        }
        if (celllen >= cellcap) { cellcap *= 2; cellbuf = GC_REALLOC(cellbuf, (size_t)cellcap); }
        cellbuf[celllen++] = (char)ch;
      }
    } else {
      for (;;) {
        int pk = src->peek(src->ctx);
        if (pk < 0 || pk == (unsigned char)sep || pk == '\r' || pk == '\n') break;
        src->next(src->ctx);
        if (celllen >= cellcap) { cellcap *= 2; cellbuf = GC_REALLOC(cellbuf, (size_t)cellcap); }
        cellbuf[celllen++] = (char)pk;
      }
    }
    if (n >= cap) { cap *= 2; cells = GC_REALLOC(cells, sizeof(Value) * (size_t)cap); }
    cells[n++] = v_str(cellbuf, celllen);

    int term = src->peek(src->ctx);
    if (term == (unsigned char)sep) {
      src->next(src->ctx);
      int after = src->peek(src->ctx);
      if (after < 0 || after == '\r' || after == '\n') {
        /* trailing separator right before the row ends -- one more,
         * empty, trailing cell (matches native's check_last_empty_column). */
        if (n >= cap) { cap *= 2; cells = GC_REALLOC(cells, sizeof(Value) * (size_t)cap); }
        cells[n++] = v_str(GC_MALLOC(1), 0);
        if (after == '\r') {
          src->next(src->ctx);
          if (src->peek(src->ctx) == '\n') src->next(src->ctx);
        } else if (after == '\n') {
          src->next(src->ctx);
        }
        break;
      }
      continue;
    } else if (term == '\r' || term == '\n') {
      src->next(src->ctx);
      if (term == '\r' && src->peek(src->ctx) == '\n') src->next(src->ctx);
      break;
    } else {
      break; /* EOF right after the last cell, no trailing newline */
    }
  }
  *out_cells = cells;
  *out_n = n;
  return 1;
}

/* ---- writer side: cell formatting/quoting + a small growable buffer ---- */

typedef struct {
  char *buf;
  int len, cap;
} DynBuf;

static void dynbuf_append(DynBuf *b, const char *bytes, int len) {
  if (b->len + len > b->cap) {
    b->cap = b->cap ? b->cap * 2 : 64;
    while (b->cap < b->len + len) b->cap *= 2;
    b->buf = GC_REALLOC(b->buf, (size_t)b->cap);
  }
  memcpy(b->buf + b->len, bytes, (size_t)len);
  b->len += len;
}
static void dynbuf_append_char(DynBuf *b, char c) { dynbuf_append(b, &c, 1); }

/* Renders one Scheme cell value's bytes (mirrors native's csv_cell_value
 * exactly: string/char/bool/int/float, everything else aborts). Chars
 * and non-string types get a fresh small buffer; T_STR is returned as-is
 * (no copy needed, this function's own caller never mutates it). */
static void csv_cell_bytes(Value v, char **out_buf, int *out_len) {
  char tmp[64];
  int n;
  switch (v.tag) {
  case T_STR:
    *out_buf = (char *)v.as.str.chars;
    *out_len = v.as.str.len;
    return;
  case T_CHAR:
    *out_buf = GC_MALLOC(1);
    (*out_buf)[0] = (char)v.as.i;
    *out_len = 1;
    return;
  case T_BOOL:
    n = v.as.b ? 4 : 5;
    *out_buf = GC_MALLOC((size_t)n);
    memcpy(*out_buf, v.as.b ? "true" : "false", (size_t)n);
    *out_len = n;
    return;
  case T_INT:
    n = snprintf(tmp, sizeof(tmp), "%lld", (long long)v.as.i);
    *out_buf = GC_MALLOC((size_t)n);
    memcpy(*out_buf, tmp, (size_t)n);
    *out_len = n;
    return;
  case T_FLOAT:
    n = snprintf(tmp, sizeof(tmp), "%.17g", v.as.f);
    *out_buf = GC_MALLOC((size_t)n);
    memcpy(*out_buf, tmp, (size_t)n);
    *out_len = n;
    return;
  default:
    cvm_abort("csv: cannot write cell");
  }
}

static int csv_bytes_need_rfc_quote(const char *bytes, int len, char sep, char quote) {
  for (int j = 0; j < len; j++)
    if (bytes[j] == sep || bytes[j] == quote || bytes[j] == '\n') return 1;
  return 0;
}

/* quoting_mode: 0=none, 1=rfc (quote only a STRING cell that contains
 * sep/quote/newline), 2=all (quote every cell, string or not). */
static void csv_write_row(DynBuf *out, Value *cells, int n, char sep, char quote, int quoting_mode) {
  for (int i = 0; i < n; i++) {
    if (i) dynbuf_append_char(out, sep);
    char *bytes;
    int len;
    csv_cell_bytes(cells[i], &bytes, &len);
    int is_str = cells[i].tag == T_STR || cells[i].tag == T_CHAR;
    int needs_quote = quoting_mode == 2 || (is_str && quoting_mode == 1 && csv_bytes_need_rfc_quote(bytes, len, sep, quote));
    if (needs_quote) {
      dynbuf_append_char(out, quote);
      for (int j = 0; j < len; j++) {
        if (bytes[j] == quote) dynbuf_append_char(out, quote);
        dynbuf_append_char(out, bytes[j]);
      }
      dynbuf_append_char(out, quote);
    } else {
      dynbuf_append(out, bytes, len);
    }
  }
  dynbuf_append_char(out, '\n');
}

/* ---- argument helpers ---- */

static char csv_char_arg(Value *args, int nargs, int idx, char default_char) {
  if (nargs <= idx) return default_char;
  if (args[idx].tag != T_CHAR) cvm_abort("csv: expected a character");
  return (char)args[idx].as.i;
}

static int csv_quoting_arg(Value *args, int nargs, int idx) {
  if (nargs <= idx) return 1; /* rfc */
  if (args[idx].tag != T_SYM) cvm_abort("csv: expected a quoting symbol");
  if (args[idx].as.str.len == 4 && memcmp(args[idx].as.str.chars, "none", 4) == 0) return 0;
  if (args[idx].as.str.len == 3 && memcmp(args[idx].as.str.chars, "rfc", 3) == 0) return 1;
  if (args[idx].as.str.len == 3 && memcmp(args[idx].as.str.chars, "all", 3) == 0) return 2;
  cvm_abort("csv: unknown quoting mode (expected none, rfc, or all)");
}

/* Accepts a row (or the top-level list of rows) as either a proper list
 * or a vector, matching native's own csv_row_cells. */
static void csv_seq_to_array(Value v, Value **out, int *out_n) {
  if (v.tag == T_VECTOR) {
    *out = v.as.vec->items;
    *out_n = v.as.vec->len;
    return;
  }
  int n = 0;
  Value cur = v;
  while (cur.tag == T_PAIR) { n++; cur = cur.as.pair->cdr; }
  Value *arr = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  cur = v;
  int i = 0;
  while (cur.tag == T_PAIR) { arr[i++] = cur.as.pair->car; cur = cur.as.pair->cdr; }
  *out = arr;
  *out_n = n;
}

/* ---- bulk: csv-read / csv-read-headers / csv-write / csv-write-headers ---- */

static Value bi_csv_read(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("csv-read: expected a string");
  char sep = csv_char_arg(args, nargs, 1, ',');
  char quote = csv_char_arg(args, nargs, 2, '"');
  BufSrc bs = {args[0].as.str.chars, args[0].as.str.len, 0};
  CharSrc src = {buf_next, buf_peek, &bs};

  int rows_cap = 8, rows_n = 0;
  Value *rows = GC_MALLOC(sizeof(Value) * (size_t)rows_cap);
  Value *cells;
  int n;
  while (csv_parse_row(&src, sep, quote, &cells, &n)) {
    if (rows_n >= rows_cap) { rows_cap *= 2; rows = GC_REALLOC(rows, sizeof(Value) * (size_t)rows_cap); }
    Vector *row_vec = GC_MALLOC(sizeof(Vector));
    row_vec->items = cells;
    row_vec->len = n;
    rows[rows_n++] = v_vector(row_vec);
  }
  Vector *result = GC_MALLOC(sizeof(Vector));
  result->items = rows;
  result->len = rows_n;
  return v_vector(result);
}

static Value bi_csv_read_headers(VM *vm, Value *args, int nargs) {
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("csv-read-headers: expected a string");
  char sep = csv_char_arg(args, nargs, 1, ',');
  char quote = csv_char_arg(args, nargs, 2, '"');
  BufSrc bs = {args[0].as.str.chars, args[0].as.str.len, 0};
  CharSrc src = {buf_next, buf_peek, &bs};

  Value *headers;
  int n_headers;
  if (!csv_parse_row(&src, sep, quote, &headers, &n_headers)) {
    headers = NULL;
    n_headers = 0;
  }

  int rows_cap = 8, rows_n = 0;
  Value *rows = GC_MALLOC(sizeof(Value) * (size_t)rows_cap);
  Value *cells;
  int n;
  while (csv_parse_row(&src, sep, quote, &cells, &n)) {
    if (rows_n >= rows_cap) { rows_cap *= 2; rows = GC_REALLOC(rows, sizeof(Value) * (size_t)rows_cap); }
    Value alist = v_nil();
    for (int i = n_headers - 1; i >= 0; i--) {
      Value cell = i < n ? cells[i] : v_str(GC_MALLOC(1), 0);
      alist = cvm_cons(vm, cvm_cons(vm, headers[i], cell), alist);
    }
    rows[rows_n++] = alist;
  }
  Vector *result = GC_MALLOC(sizeof(Vector));
  result->items = rows;
  result->len = rows_n;
  return v_vector(result);
}

static Value bi_csv_write(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("csv-write: expected a sequence of rows");
  char sep = csv_char_arg(args, nargs, 1, ',');
  int quoting = csv_quoting_arg(args, nargs, 2);
  Value *rows;
  int n_rows;
  csv_seq_to_array(args[0], &rows, &n_rows);
  DynBuf out = {NULL, 0, 0};
  for (int i = 0; i < n_rows; i++) {
    Value *cells;
    int n_cells;
    csv_seq_to_array(rows[i], &cells, &n_cells);
    csv_write_row(&out, cells, n_cells, sep, '"', quoting);
  }
  return v_str(out.buf ? out.buf : GC_MALLOC(1), out.len);
}

static Value bi_csv_write_headers(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("csv-write-headers: expected (headers rows)");
  char sep = csv_char_arg(args, nargs, 2, ',');
  int quoting = csv_quoting_arg(args, nargs, 3);
  Value *headers;
  int n_headers;
  csv_seq_to_array(args[0], &headers, &n_headers);
  Value *rows;
  int n_rows;
  csv_seq_to_array(args[1], &rows, &n_rows);
  DynBuf out = {NULL, 0, 0};
  csv_write_row(&out, headers, n_headers, sep, '"', quoting);
  for (int i = 0; i < n_rows; i++) {
    Value *cells;
    int n_cells;
    csv_seq_to_array(rows[i], &cells, &n_cells);
    csv_write_row(&out, cells, n_cells, sep, '"', quoting);
  }
  return v_str(out.buf ? out.buf : GC_MALLOC(1), out.len);
}

/* ---- streaming: csv-reader-open/-read!/-? and csv-writer-open/-row!/-? ---- */

typedef struct {
  Port *port;
  char sep, quote;
} CvmCsvReader;

typedef struct {
  Port *port;
  char sep, quote;
  int quoting;
} CvmCsvWriter;

static Value bi_csv_reader_open(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_PORT) cvm_abort("csv-reader-open: expected an input port");
  CvmCsvReader *r = GC_MALLOC(sizeof(CvmCsvReader));
  r->port = args[0].as.port;
  r->sep = csv_char_arg(args, nargs, 1, ',');
  r->quote = csv_char_arg(args, nargs, 2, '"');
  /* args[3] (chunk-size) is accepted for native-signature compatibility
   * but unused -- this reader has no chunked-refill strategy to size (see
   * this file's own header comment: cvm_port_read_char already reads one
   * byte at a time through the Port abstraction regardless). */
  return v_box(r, BOX_KIND_CSV_READER);
}

static Value bi_csv_reader_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("csv-reader?: expected an argument");
  return v_bool(args[0].tag == T_BOX && args[0].as.box.kind == BOX_KIND_CSV_READER);
}

static Value bi_csv_reader_read_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_BOX || args[0].as.box.kind != BOX_KIND_CSV_READER)
    cvm_abort("csv-reader-read!: expected a csv reader");
  CvmCsvReader *r = args[0].as.box.ptr;
  CharSrc src = {port_next, port_peek, r->port};
  Value *cells;
  int n;
  if (!csv_parse_row(&src, r->sep, r->quote, &cells, &n)) return v_box(NULL, BOX_KIND_EOF);
  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->items = cells;
  vec->len = n;
  return v_vector(vec);
}

static Value bi_csv_writer_open(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_PORT) cvm_abort("csv-writer-open: expected an output port");
  CvmCsvWriter *w = GC_MALLOC(sizeof(CvmCsvWriter));
  w->port = args[0].as.port;
  w->sep = csv_char_arg(args, nargs, 1, ',');
  w->quoting = csv_quoting_arg(args, nargs, 2);
  w->quote = '"';
  return v_box(w, BOX_KIND_CSV_WRITER);
}

static Value bi_csv_writer_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("csv-writer?: expected an argument");
  return v_bool(args[0].tag == T_BOX && args[0].as.box.kind == BOX_KIND_CSV_WRITER);
}

static Value bi_csv_writer_row_bang(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_BOX || args[0].as.box.kind != BOX_KIND_CSV_WRITER)
    cvm_abort("csv-writer-row!: expected a csv writer");
  CvmCsvWriter *w = args[0].as.box.ptr;
  DynBuf out = {NULL, 0, 0};
  csv_write_row(&out, args + 1, nargs - 1, w->sep, w->quote, w->quoting);
  cvm_port_write_bytes(w->port, out.buf ? out.buf : "", out.len);
  return v_nil();
}

void cvm_register_csv_builtins(VM *vm) {
  cvm_register_builtin(vm, "csv-read", bi_csv_read);
  cvm_register_builtin(vm, "csv-read-headers", bi_csv_read_headers);
  cvm_register_builtin(vm, "csv-write", bi_csv_write);
  cvm_register_builtin(vm, "csv-write-headers", bi_csv_write_headers);
  cvm_register_builtin(vm, "csv-reader-open", bi_csv_reader_open);
  cvm_register_builtin(vm, "csv-reader-read!", bi_csv_reader_read_bang);
  cvm_register_builtin(vm, "csv-reader?", bi_csv_reader_p);
  cvm_register_builtin(vm, "csv-writer-open", bi_csv_writer_open);
  cvm_register_builtin(vm, "csv-writer-row!", bi_csv_writer_row_bang);
  cvm_register_builtin(vm, "csv-writer?", bi_csv_writer_p);
}
