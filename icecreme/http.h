/* (creme http) — a plain HTTP/1.1 client. See http.c's own header
 * comment for scope (http:// only -- no TLS/HTTPS, a deliberate cut). */
#ifndef CVM_HTTP_H
#define CVM_HTTP_H

#include "vm.h"

void cvm_register_http_builtins(VM *vm);

#endif
