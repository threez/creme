/* (creme sql) — see sql.h. Single connection only (icecreme is single-threaded,
 * matching the competition/c/demo-todo C11 twin's own reasoning) — unlike
 * the real sql.cr, no separate reader/writer WAL split (that's only needed
 * for concurrent real-file access, not a single in-process VM). */
#include "builtin_config.h"

#if CREME_WITH_SQL

#include <gc.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

#include "embed.h"
#include "sql.h"

static sqlite3 *as_sql(Value v, const char *who) {
  return creme_arg_box(&v, 1, 0, BOX_KIND_SQL, who);
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
    creme_abort("sql: unsupported parameter value type");
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
    return creme_bytes_value((const char *)text, len);
  }
  case SQLITE_NULL:
  default:
    return v_nil();
  }
}

static sqlite3_stmt *prepare_and_bind(sqlite3 *db, Value sql_val, Value *params, int n_params) {
  if (sql_val.tag != T_STR) creme_abort("sql: expected a SQL string");
  sqlite3_stmt *stmt;
  if (sqlite3_prepare_v2(db, sql_val.as.chars, sql_val.aux, &stmt, NULL) != SQLITE_OK) {
    creme_abort("sql: prepare failed: %s", sqlite3_errmsg(db));
  }
  for (int i = 0; i < n_params; i++) bind_param(stmt, i + 1, params[i]);
  return stmt;
}

static Value bi_sql_open(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) creme_abort("sql-open: expected a path string");
  char *path = malloc((size_t)args[0].aux + 1);
  memcpy(path, args[0].as.chars, (size_t)args[0].aux);
  path[args[0].aux] = 0;
  sqlite3 *db;
  int rc = sqlite3_open(path, &db);
  free(path);
  if (rc != SQLITE_OK) creme_abort("sql-open: %s", sqlite3_errmsg(db));
  return v_box(db, BOX_KIND_SQL);
}

static Value bi_sql_close(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "sql-close");
  sqlite3_close(as_sql(args[0], "sql-close"));
  return v_nil();
}

static Value bi_sql_connection_p(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 1, "sql-connection?");
  return v_bool(args[0].tag == T_BOX && args[0].aux == BOX_KIND_SQL);
}

static Value bi_sql_execute(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "sql-execute");
  sqlite3 *db = as_sql(args[0], "sql-execute");
  sqlite3_stmt *stmt = prepare_and_bind(db, args[1], args + 2, nargs - 2);
  int rc = sqlite3_step(stmt);
  if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
    const char *msg = sqlite3_errmsg(db);
    sqlite3_finalize(stmt);
    creme_abort("sql-execute: %s", msg);
  }
  sqlite3_finalize(stmt);
  int64_t rows_affected = sqlite3_changes(db);
  int64_t last_id = sqlite3_last_insert_rowid(db);
  Value alist = v_nil();
  alist = creme_cons(vm, creme_cons(vm, creme_cstr_value("last-insert-id"), v_int(last_id)), alist);
  alist = creme_cons(vm, creme_cons(vm, creme_cstr_value("rows-affected"), v_int(rows_affected)), alist);
  return alist;
}

static Value bi_sql_query(VM *vm, Value *args, int nargs) {
  creme_check_min_args(nargs, 2, "sql-query");
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
    colnames[i] = creme_cstr_value(name);
  }

  Value *rows = NULL;
  int n_rows = 0, cap_rows = 0;
  int rc;
  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    Value row = v_nil();
    for (int i = ncols - 1; i >= 0; i--) {
      row = creme_cons(vm, creme_cons(vm, colnames[i], column_to_value(stmt, i)), row);
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
    creme_abort("sql-query: %s", msg);
  }
  sqlite3_finalize(stmt);

  Vector *vec = GC_MALLOC(sizeof(Vector));
  vec->items = rows;
  vec->len = n_rows;
  return v_vector(vec);
}

static Value bi_sql_scalar(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_min_args(nargs, 2, "sql-scalar");
  sqlite3 *db = as_sql(args[0], "sql-scalar");
  sqlite3_stmt *stmt = prepare_and_bind(db, args[1], args + 2, nargs - 2);
  Value result = v_nil();
  if (sqlite3_step(stmt) == SQLITE_ROW) result = column_to_value(stmt, 0);
  sqlite3_finalize(stmt);
  return result;
}

void creme_register_sql_builtins(VM *vm) {
  creme_register_builtin(vm, "sql-open", bi_sql_open);
  creme_register_builtin(vm, "sql-close", bi_sql_close);
  creme_register_builtin(vm, "sql-connection?", bi_sql_connection_p);
  creme_register_builtin(vm, "sql-execute", bi_sql_execute);
  creme_register_builtin(vm, "sql-query", bi_sql_query);
  creme_register_builtin(vm, "sql-scalar", bi_sql_scalar);
}

#endif /* CREME_WITH_SQL */
