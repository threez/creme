/* (creme yaml) -- yaml-read/yaml-write, backed by libyaml. See yaml.c's own
 * header comment for the parser/writer design and how it compares to
 * native's own (creme yaml) implementation (src/creme/modules/creme/
 * yaml.cr, which uses Crystal's stdlib `YAML` -- itself a libyaml wrapper
 * too). */
#ifndef CREME_YAML_H
#define CREME_YAML_H

#include "vm.h"

void creme_register_yaml_builtins(VM *vm);

#endif
