/* (creme sql) — see sql.h. Single connection only (cvm is single-threaded,
 * matching the competition/c/demo-todo C11 twin's own reasoning) — unlike
 * the real sql.cr, no separate reader/writer WAL split (that's only needed
 * for concurrent real-file access, not a single in-process VM). */
#include <gc.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

#include "sql.h"

static sqlite3 *as_sql(Value v, const char *who) {
  if (v.tag != T_BOX || v.aux != BOX_KIND_SQL) cvm_abort("%s: expected a sql connection", who);
  return (sqlite3 *)v.as.ptr;
}

/* For a C string literal (e.g. the alist keys below) — T_STR is mutable
 * (string-set!) as of Group C, so a Value pointing directly at a literal
 * in .rodata would segfault the moment Scheme code mutated it; every
 * literal handed to Scheme needs its own GC-owned copy (mirrors mux.c's
 * own v_litstr). */
static Value v_litstr(const char *s) {
  size_t len = strlen(s);
  char *copy = GC_MALLOC(len ? len : 1);
  memcpy(copy, s, len);
  return v_str(copy, (int)len);
}

static void bind_param(sqlite3_stmt *stmt, int idx, Value v) {
  switch (v.tag) {
  case T_INT:
    sqlite3_bind_int64(stmt, idx, v.as.i);
    break;
  case T_FLOAT:
    sqlite3_bind_double(stmt, idx, v.as.f);
    break;
  case T_CHAR:
    sqlite3_bind_int64(stmt, idx, v.as.i);
    break;
  case T_STR:
  case T_SYM:
    sqlite3_bind_text(stmt, idx, v.as.chars, v.aux, SQLITE_TRANSIENT);
    break;
  case T_BOOL:
    sqlite3_bind_int(stmt, idx, v.as.b ? 1 : 0);
    break;
  case T_NIL:
    sqlite3_bind_null(stmt, idx);
    break;
  default:
    cvm_abort("sql: unsupported parameter value type");
  }
}

static Value column_to_value(sqlite3_stmt *stmt, int col) {
  switch (sqlite3_column_type(stmt, col)) {
  case SQLITE_INTEGER:
    return v_int(sqlite3_column_int64(stmt, col));
  case SQLITE_FLOAT:
    return v_float(sqlite3_column_double(stmt, col));
  case SQLITE_TEXT: {
    const unsigned char *text = sqlite3_column_text(stmt, col);
    int len = sqlite3_column_bytes(stmt, col);
    char *copy = GC_MALLOC((size_t)(len ? len : 1));
    memcpy(copy, text, (size_t)len);
    return v_str(copy, len);
  }
  case SQLITE_NULL:
  default:
    return v_nil();
  }
}

static sqlite3_stmt *prepare_and_bind(sqlite3 *db, Value sql_val, Value *params, int n_params) {
  if (sql_val.tag != T_STR) cvm_abort("sql: expected a SQL string");
  sqlite3_stmt *stmt;
  if (sqlite3_prepare_v2(db, sql_val.as.chars, sql_val.aux, &stmt, NULL) != SQLITE_OK) {
    cvm_abort("sql: prepare failed: %s", sqlite3_errmsg(db));
  }
  for (int i = 0; i < n_params; i++) bind_param(stmt, i + 1, params[i]);
  return stmt;
}

static Value bi_sql_open(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("sql-open: expected a path string");
  char *path = malloc((size_t)args[0].aux + 1);
  memcpy(path, args[0].as.chars, (size_t)args[0].aux);
  path[args[0].aux] = 0;
  sqlite3 *db;
  int rc = sqlite3_open(path, &db);
  free(path);
  if (rc != SQLITE_OK) cvm_abort("sql-open: %s", sqlite3_errmsg(db));
  return v_box(db, BOX_KIND_SQL);
}

static Value bi_sql_close(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("sql-close: expected a connection");
  sqlite3_close(as_sql(args[0], "sql-close"));
  return v_nil();
}

static Value bi_sql_connection_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1) cvm_abort("sql-connection?: expected an argument");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_SQL);
}

static Value bi_sql_execute(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("sql-execute: expected (conn sql . params)");
  sqlite3 *db = as_sql(args[0], "sql-execute");
  sqlite3_stmt *stmt = prepare_and_bind(db, args[1], args + 2, nargs - 2);
  int rc = sqlite3_step(stmt);
  if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
    const char *msg = sqlite3_errmsg(db);
    sqlite3_finalize(stmt);
    cvm_abort("sql-execute: %s", msg);
  }
  sqlite3_finalize(stmt);
  int64_t rows_affected = sqlite3_changes(db);
  int64_t last_id = sqlite3_last_insert_rowid(db);
  Value alist = v_nil();
  alist = cvm_cons(vm, cvm_cons(vm, v_litstr("last-insert-id"), v_int(last_id)), alist);
  alist = cvm_cons(vm, cvm_cons(vm, v_litstr("rows-affected"), v_int(rows_affected)), alist);
  return alist;
}

static Value bi_sql_query(VM *vm, Value *args, int nargs) {
  if (nargs < 2) cvm_abort("sql-query: expected (conn sql . params)");
  sqlite3 *db = as_sql(args[0], "sql-query");
  sqlite3_stmt *stmt = prepare_and_bind(db, args[1], args + 2, nargs - 2);
  int ncols = sqlite3_column_count(stmt);

  /* Column names, fetched once and shared across every row (matches
   * sql.cr's own comment about doing exactly that) -- GC_MALLOC'd (not
   * plain malloc) since these Values stay alive across the whole row loop
   * below, where further GC_MALLOC/GC_REALLOC calls (building each row's
   * cons chain) could otherwise trigger a collection before the last row
   * references them. */
  Value *colnames = GC_MALLOC(sizeof(Value) * (size_t)(ncols ? ncols : 1));
  for (int i = 0; i < ncols; i++) {
    const char *name = sqlite3_column_name(stmt, i);
    int len = (int)strlen(name);
    char *copy = GC_MALLOC((size_t)(len ? len : 1));
    memcpy(copy, name, (size_t)len);
    colnames[i] = v_str(copy, len);
  }

  Value *rows = NULL;
  int n_rows = 0, cap_rows = 0;
  int rc;
  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    Value row = v_nil();
    for (int i = ncols - 1; i >= 0; i--) {
      row = cvm_cons(vm, cvm_cons(vm, colnames[i], column_to_value(stmt, i)), row);
    }
    if (n_rows >= cap_rows) {
      cap_rows = cap_rows ? cap_rows * 2 : 8;
      rows = GC_REALLOC(rows, sizeof(Value) * (size_t)cap_rows);
    }
    rows[n_rows++] = row;
  }
  if (rc != SQLITE_DONE) {
    const char *msg = sqlite3_errmsg(db);
    sqlite3_finalize(stmt);
    cvm_abort("sql-query: %s", msg);
  }
  sqlite3_finalize(stmt);

  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->items = rows;
  vec->len = n_rows;
  return v_vector(vec);
}

static Value bi_sql_scalar(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2) cvm_abort("sql-scalar: expected (conn sql . params)");
  sqlite3 *db = as_sql(args[0], "sql-scalar");
  sqlite3_stmt *stmt = prepare_and_bind(db, args[1], args + 2, nargs - 2);
  Value result = v_nil();
  if (sqlite3_step(stmt) == SQLITE_ROW) result = column_to_value(stmt, 0);
  sqlite3_finalize(stmt);
  return result;
}

void cvm_register_sql_builtins(VM *vm) {
  cvm_register_builtin(vm, "sql-open", bi_sql_open);
  cvm_register_builtin(vm, "sql-close", bi_sql_close);
  cvm_register_builtin(vm, "sql-connection?", bi_sql_connection_p);
  cvm_register_builtin(vm, "sql-execute", bi_sql_execute);
  cvm_register_builtin(vm, "sql-query", bi_sql_query);
  cvm_register_builtin(vm, "sql-scalar", bi_sql_scalar);
}
