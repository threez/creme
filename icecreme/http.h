/* (creme http) — a plain HTTP/1.1 client. See http.c's own header
 * comment for scope (http:// only -- no TLS/HTTPS, a deliberate cut). */
#ifndef CREME_HTTP_H
#define CREME_HTTP_H

#include "vm.h"

void creme_register_http_builtins(VM *vm);

#endif
