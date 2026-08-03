/* Public umbrella header for embedding icecreme via libcreme.a — one
 * #include instead of hunting through every per-family header. See
 * icecreme/README.md's "Embedding" section for the full minimal call
 * sequence and examples/libcream/ for a complete worked example.
 *
 * A libcreme.a consumer also needs, at their own link stage (static
 * archives don't carry transitive link flags): -lm -lpthread -lsqlite3 -ldl
 * plus whatever `pkg-config --libs` reports for bdw-gc(-threaded),
 * libpcre2-8, gmp, libcrypto, libssl, libffi, and yaml-0.1 (falling back to
 * -lgc/-lpcre2-8/-lgmp/-lcrypto/-lssl/-lffi/-lyaml respectively if
 * pkg-config can't find one) — exactly the LDLIBS set icecreme/Makefile
 * itself resolves for the CLI binary; see that Makefile for the canonical,
 * always-up-to-date list. */
#ifndef CREME_H
#define CREME_H

#include "value.h"
#include "vm.h"

#include "builtin_families.h"
#include "embed.h"

#include "actor.h"
#include "bigdecimal.h"
#include "bootstrap.h"
#include "cipher.h"
#include "creme_ffi.h"
#include "csv.h"
#include "digest.h"
#include "hashtable.h"
#include "http.h"
#include "json.h"
#include "mux.h"
#include "pkey.h"
#include "process.h"
#include "regex.h"
#include "secure_random.h"
#include "sql.h"
#include "strings.h"
#include "term.h"
#include "treelist.h"
#include "x509.h"
#include "yaml.h"

#endif
