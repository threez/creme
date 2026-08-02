/* (creme regex) — a narrow slice (just `regexp`/`regexp-matches?`) of the
 * real Crystal-side (creme regex) library, backed by PCRE2 (the same
 * regex flavor the real Crystal `Regex` class itself uses). Exists
 * specifically so the self-hosted reader (modules/creme/compiler/
 * reader.sld) can run under icecreme -- see regex.c's own header comment. */
#ifndef CREME_REGEX_H
#define CREME_REGEX_H

#include "vm.h"

void creme_register_regex_builtins(VM *vm);

#endif
