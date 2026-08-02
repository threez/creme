/* (creme sql) — sql-open/sql-close/sql-connection?/sql-execute/sql-query/
 * sql-scalar, via the sqlite3 C API directly. See sql.c's own header comment for scope
 * (single connection, matching icecreme's single-threaded design — no reader/
 * writer WAL split like the real sql.cr needs for concurrent real-file
 * access). */
#ifndef CVM_SQL_H
#define CVM_SQL_H

#include "vm.h"

void cvm_register_sql_builtins(VM *vm);

#endif
