/* C/facil.io+mustache+SQLite3 equivalent of ../../ruby/demo-todo/app.rb,
 * ../../crystal/demo-todo/src/app.cr, ../../racket/demo-todo/app.rkt,
 * ../../go/demo-todo/main.go, and ../../node/demo-todo/app.js, built for a
 * head-to-head benchmark. Same storage (in-memory SQLite), same routes, same
 * JSON content-negotiation behavior, same per-row HTML memoization strategy
 * -- written directly against facil.io's HTTP server + fiobj_mustache module
 * and the sqlite3 C API. The `Todo` type below (plus todo_all/todo_create/
 * todo_toggle/todo_delete/todo_remaining_count) plays the role the other
 * twins give their ORM model (Go's `Todo` struct + GORM, Racket's `struct
 * todo`, Crystal's Granite model, Ruby's Sequel model) -- callers work with
 * `Todo` values, never raw sqlite3_stmt column access.
 */
#include "fiobj_json.h"
#include "fiobj_mustache.h"
#include "http.h"
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- Todo model --------------------------------------------------------- */

typedef struct {
  int64_t id;
  char *title; /* owned heap copy */
  int done;
} Todo;

static void todo_destroy(Todo *t) {
  free(t->title);
  t->title = NULL;
}

static sqlite3 *db;

static void db_exec(const char *sql) {
  char *err = NULL;
  if (sqlite3_exec(db, sql, NULL, NULL, &err) != SQLITE_OK) {
    fprintf(stderr, "sqlite error: %s\n", err);
    sqlite3_free(err);
    exit(1);
  }
}

static void todo_create(const char *title, size_t title_len) {
  sqlite3_stmt *stmt;
  sqlite3_prepare_v2(db, "INSERT INTO todos (title, done) VALUES (?, 0)", -1,
                     &stmt, NULL);
  sqlite3_bind_text(stmt, 1, title, (int)title_len, SQLITE_TRANSIENT);
  sqlite3_step(stmt);
  sqlite3_finalize(stmt);
}

static void todo_toggle(int64_t id) {
  sqlite3_stmt *stmt;
  sqlite3_prepare_v2(
      db, "UPDATE todos SET done = 1 - done WHERE id = ?", -1, &stmt, NULL);
  sqlite3_bind_int64(stmt, 1, id);
  sqlite3_step(stmt);
  sqlite3_finalize(stmt);
}

static void todo_delete(int64_t id) {
  sqlite3_stmt *stmt;
  sqlite3_prepare_v2(db, "DELETE FROM todos WHERE id = ?", -1, &stmt, NULL);
  sqlite3_bind_int64(stmt, 1, id);
  sqlite3_step(stmt);
  sqlite3_finalize(stmt);
}

static int64_t todo_remaining_count(void) {
  sqlite3_stmt *stmt;
  sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM todos WHERE done = 0", -1,
                     &stmt, NULL);
  sqlite3_step(stmt);
  int64_t n = sqlite3_column_int64(stmt, 0);
  sqlite3_finalize(stmt);
  return n;
}

/* Loads every row into a heap array of `Todo`, ordered by id. The caller
 * owns the result: todo_destroy() each entry, then free() the array. */
static size_t todo_all(Todo **out) {
  sqlite3_stmt *stmt;
  sqlite3_prepare_v2(db, "SELECT id, title, done FROM todos ORDER BY id", -1,
                     &stmt, NULL);
  size_t cap = 8, count = 0;
  Todo *todos = malloc(cap * sizeof(*todos));
  while (sqlite3_step(stmt) == SQLITE_ROW) {
    if (count == cap) {
      cap *= 2;
      todos = realloc(todos, cap * sizeof(*todos));
    }
    const char *title = (const char *)sqlite3_column_text(stmt, 1);
    size_t title_len = (size_t)sqlite3_column_bytes(stmt, 1);
    todos[count].id = sqlite3_column_int64(stmt, 0);
    todos[count].title = malloc(title_len + 1);
    memcpy(todos[count].title, title, title_len);
    todos[count].title[title_len] = 0;
    todos[count].done = sqlite3_column_int(stmt, 2);
    ++count;
  }
  sqlite3_finalize(stmt);
  *out = todos;
  return count;
}

/* --- templates ---------------------------------------------------------- */

static mustache_s *page_tpl;
static mustache_s *row_tpl;

static mustache_s *load_template(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    fprintf(stderr, "couldn't open template: %s\n", path);
    exit(1);
  }
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = malloc((size_t)len);
  if (fread(buf, 1, (size_t)len, f) != (size_t)len) {
    fprintf(stderr, "couldn't read template: %s\n", path);
    exit(1);
  }
  fclose(f);
  mustache_s *tpl = fiobj_mustache_new(.data = buf, .data_len = (size_t)len);
  free(buf);
  if (!tpl) {
    fprintf(stderr, "couldn't parse template: %s\n", path);
    exit(1);
  }
  return tpl;
}

/* --- row-level memoization ----------------------------------------------
 * Mirrors the other twins' row cache: rendered <li> markup is cached keyed
 * on (id, done, title), so re-rendering the list only recomputes rows whose
 * fields actually changed. Indexed directly by id (small, sequential in
 * this benchmark) instead of a general hash table.
 */

typedef struct {
  int valid;
  int done;
  char *title;
  char *html;
  size_t html_len;
} row_cache_entry_s;

static row_cache_entry_s *row_cache;
static size_t row_cache_cap;

static void row_cache_ensure(int64_t id) {
  if ((size_t)id < row_cache_cap)
    return;
  size_t new_cap = row_cache_cap ? row_cache_cap * 2 : 16;
  while (new_cap <= (size_t)id)
    new_cap *= 2;
  row_cache = realloc(row_cache, new_cap * sizeof(*row_cache));
  memset(row_cache + row_cache_cap, 0,
         (new_cap - row_cache_cap) * sizeof(*row_cache));
  row_cache_cap = new_cap;
}

static fio_str_info_s render_row(const Todo *t) {
  size_t title_len = strlen(t->title);
  row_cache_ensure(t->id);
  row_cache_entry_s *e = &row_cache[t->id];
  if (e->valid && e->done == t->done && e->title &&
      strlen(e->title) == title_len && !memcmp(e->title, t->title, title_len))
    return (fio_str_info_s){.data = e->html, .len = e->html_len};

  FIOBJ data = fiobj_hash_new2(4);
  fiobj_hash_set(data, fiobj_str_new("id", 2), fiobj_num_new(t->id));
  fiobj_hash_set(data, fiobj_str_new("title", 5),
                fiobj_str_new(t->title, title_len));
  fiobj_hash_set(data, fiobj_str_new("done", 4),
                t->done ? fiobj_true() : fiobj_false());
  FIOBJ rendered = fiobj_mustache_build(row_tpl, data);
  fio_str_info_s r = fiobj_obj2cstr(rendered);

  free(e->title);
  free(e->html);
  e->title = malloc(title_len + 1);
  memcpy(e->title, t->title, title_len);
  e->title[title_len] = 0;
  e->html = malloc(r.len);
  memcpy(e->html, r.data, r.len);
  e->html_len = r.len;
  e->done = t->done;
  e->valid = 1;

  fiobj_free(rendered);
  fiobj_free(data);
  return (fio_str_info_s){.data = e->html, .len = e->html_len};
}

/* --- content negotiation -------------------------------------------------
 * Reproduces the twins' exact contract: split Accept on ",", strip ";..."
 * params, trim whitespace, and return the FIRST entry that is exactly
 * "text/html" or "application/json" (no wildcard matching, client-order-
 * first). NULL means neither was offered -> 406.
 */

static const char *negotiate(fio_str_info_s accept, size_t *out_len) {
  const char *p = accept.data;
  const char *end = accept.data + accept.len;
  while (p < end) {
    const char *comma = memchr(p, ',', (size_t)(end - p));
    const char *part_end = comma ? comma : end;
    const char *semi = memchr(p, ';', (size_t)(part_end - p));
    const char *val_end = semi ? semi : part_end;
    const char *s = p;
    while (s < val_end && (*s == ' ' || *s == '\t'))
      ++s;
    const char *e = val_end;
    while (e > s && (e[-1] == ' ' || e[-1] == '\t'))
      --e;
    size_t len = (size_t)(e - s);
    if (len == 9 && !memcmp(s, "text/html", 9)) {
      *out_len = len;
      return s;
    }
    if (len == 16 && !memcmp(s, "application/json", 16)) {
      *out_len = len;
      return s;
    }
    p = comma ? comma + 1 : end;
  }
  return NULL;
}

/* --- routes --------------------------------------------------------------- */

static void redirect_home(http_s *h) {
  h->status = 302;
  http_set_header2(
      h, (fio_str_info_s){.data = (char *)"Location", .len = 8},
      (fio_str_info_s){.data = (char *)"/", .len = 1});
  http_finish(h);
}

static void send_not_acceptable(http_s *h) {
  h->status = 406;
  http_set_header(h, HTTP_HEADER_CONTENT_TYPE,
                 fiobj_str_new("text/plain; charset=utf-8",
                              sizeof("text/plain; charset=utf-8") - 1));
  static const char body[] =
      "Not Acceptable: this route serves text/html or application/json";
  http_send_body(h, (void *)body, sizeof(body) - 1);
}

static void handle_index(http_s *h) {
  FIOBJ accept_obj = fiobj_hash_get(h->headers, HTTP_HEADER_ACCEPT);
  fio_str_info_s accept =
      accept_obj ? fiobj_obj2cstr(accept_obj) : (fio_str_info_s){0};
  size_t match_len = 0;
  const char *match = negotiate(accept, &match_len);
  if (!match) {
    send_not_acceptable(h);
    return;
  }

  Todo *todos;
  size_t n = todo_all(&todos);

  if (match_len == 9) { /* text/html */
    FIOBJ rows = fiobj_str_new(NULL, 0);
    for (size_t i = 0; i < n; ++i) {
      fio_str_info_s row = render_row(&todos[i]);
      fiobj_str_write(rows, row.data, row.len);
    }

    FIOBJ data = fiobj_hash_new2(2);
    fiobj_hash_set(data, fiobj_str_new("rows", 4), rows);
    char remaining_buf[32];
    int remaining_len =
        snprintf(remaining_buf, sizeof(remaining_buf), "%lld",
                 (long long)todo_remaining_count());
    fiobj_hash_set(data, fiobj_str_new("remaining", 9),
                  fiobj_str_new(remaining_buf, (size_t)remaining_len));

    FIOBJ page = fiobj_mustache_build(page_tpl, data);
    fio_str_info_s p = fiobj_obj2cstr(page);
    http_set_header(h, HTTP_HEADER_CONTENT_TYPE,
                   fiobj_str_new("text/html; charset=utf-8",
                                sizeof("text/html; charset=utf-8") - 1));
    http_send_body(h, p.data, p.len);
    fiobj_free(page);
    fiobj_free(data);
  } else { /* application/json */
    FIOBJ ary = fiobj_ary_new();
    for (size_t i = 0; i < n; ++i) {
      FIOBJ row = fiobj_hash_new2(3);
      fiobj_hash_set(row, fiobj_str_new("id", 2), fiobj_num_new(todos[i].id));
      fiobj_hash_set(row, fiobj_str_new("title", 5),
                    fiobj_str_new(todos[i].title, strlen(todos[i].title)));
      fiobj_hash_set(row, fiobj_str_new("done", 4),
                    todos[i].done ? fiobj_true() : fiobj_false());
      fiobj_ary_push(ary, row);
    }

    FIOBJ json = fiobj_obj2json(ary, 0);
    fio_str_info_s j = fiobj_obj2cstr(json);
    http_set_header(h, HTTP_HEADER_CONTENT_TYPE,
                   fiobj_str_new("application/json; charset=utf-8",
                                sizeof("application/json; charset=utf-8") - 1));
    http_send_body(h, j.data, j.len);
    fiobj_free(json);
    fiobj_free(ary);
  }

  for (size_t i = 0; i < n; ++i)
    todo_destroy(&todos[i]);
  free(todos);
}

static void handle_create(http_s *h) {
  http_parse_body(h);
  FIOBJ title = h->params ? fiobj_hash_get(h->params, fiobj_str_new("title", 5))
                          : FIOBJ_INVALID;
  fio_str_info_s t = title ? fiobj_obj2cstr(title) : (fio_str_info_s){0};
  todo_create(t.data ? t.data : "", t.len);
  redirect_home(h);
}

/* Parses "/todos/<id>/complete" or "/todos/<id>/delete", returning the id
 * and whether it matched `suffix`, or -1 if the path doesn't match at all. */
static int64_t parse_todo_id(fio_str_info_s path, const char *suffix) {
  static const char prefix[] = "/todos/";
  size_t prefix_len = sizeof(prefix) - 1;
  size_t suffix_len = strlen(suffix);
  if (path.len <= prefix_len + suffix_len ||
      memcmp(path.data, prefix, prefix_len))
    return -1;
  const char *num = path.data + prefix_len;
  const char *num_end = path.data + path.len - suffix_len;
  if (memcmp(num_end, suffix, suffix_len))
    return -1;
  int64_t id = 0;
  for (const char *c = num; c < num_end; ++c) {
    if (*c < '0' || *c > '9')
      return -1;
    id = id * 10 + (*c - '0');
  }
  return id;
}

static void on_request(http_s *h) {
  fio_str_info_s method = fiobj_obj2cstr(h->method);
  fio_str_info_s path = fiobj_obj2cstr(h->path);

  if (method.len == 3 && !memcmp(method.data, "GET", 3) && path.len == 1 &&
      path.data[0] == '/') {
    handle_index(h);
    return;
  }
  if (method.len == 4 && !memcmp(method.data, "POST", 4)) {
    if (path.len == 6 && !memcmp(path.data, "/todos", 6)) {
      handle_create(h);
      return;
    }
    int64_t id = parse_todo_id(path, "/complete");
    if (id >= 0) {
      todo_toggle(id);
      redirect_home(h);
      return;
    }
    id = parse_todo_id(path, "/delete");
    if (id >= 0) {
      todo_delete(id);
      redirect_home(h);
      return;
    }
  }
  http_send_error(h, 404);
}

int main(void) {
  if (sqlite3_open(":memory:", &db) != SQLITE_OK) {
    fprintf(stderr, "couldn't open in-memory sqlite db\n");
    return 1;
  }
  db_exec("CREATE TABLE todos ("
          "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
          "  title TEXT NOT NULL,"
          "  done INTEGER NOT NULL DEFAULT 0"
          ")");
  todo_create("Write report", strlen("Write report"));
  todo_create("Review PR", strlen("Review PR"));
  todo_create("Ship release", strlen("Ship release"));
  todo_toggle(2);

  page_tpl = load_template("templates/page.mustache");
  row_tpl = load_template("templates/row.mustache");

  const char *port_env = getenv("PORT");
  const char *port = port_env && *port_env ? port_env : "4567";

  printf("Serving the todo list at http://127.0.0.1:%s\n", port);
  fflush(stdout);

  if (http_listen(port, "127.0.0.1", .on_request = on_request, .log = 0) ==
      -1) {
    fprintf(stderr, "couldn't listen on port %s\n", port);
    return 1;
  }
  fio_start(.threads = 1, .workers = 1);

  fiobj_mustache_free(page_tpl);
  fiobj_mustache_free(row_tpl);
  sqlite3_close(db);
  return 0;
}
