# ===========================================================================
# SchemeValue — the union of every concrete value type
# ===========================================================================
#
# `SchemeValue` is a union alias, not a base class, so that immutable scalar
# types can be value-type `struct`s (living inline in their container instead
# of heap-boxed) while identity/mutable types stay `class`es — Crystal cannot
# mix `struct` and `class` in one inheritance hierarchy, so the shared behavior
# lives in the `SchemeBaseValue` module (see values.cr) and the common type is
# this union.
#
# To add a new value type: define it, `include SchemeBaseValue`, and append it
# here.
#
# The alias is resolved in Crystal's late semantic phase, so the recursive
# references (e.g. `Cons#car : SchemeValue`, where the union includes `Cons`)
# and the fact that this file is required after the type definitions are both
# fine — top-level type/alias declarations are order-independent.

module Scheme
  # The last member, SchemeBox, covers every opaque foreign module handle
  # (regex, sql connection, tui objects, ...) — new ones box themselves under
  # a tag and need no entry here (see value/box.cr).
  alias SchemeValue = SchemeInt |
                      SchemeFloat |
                      SchemeStr |
                      SchemeSym |
                      SchemeBool |
                      SchemeNil |
                      SchemeChar |
                      Cons |
                      SchemeSpecialForm |
                      Macro |
                      Builtin |
                      SchemeVector |
                      SchemeBlob |
                      SchemeEof |
                      SchemePort |
                      SchemePromise |
                      SchemeParameter |
                      SchemeEnvironment |
                      SchemeValues |
                      SchemeContinuation |
                      SchemeRational |
                      SchemeComplex |
                      SchemeRecordType |
                      SchemeRecord |
                      SchemeSyntaxRules |
                      SchemeLibrary |
                      SchemeHashTable |
                      SchemeTreelist |
                      SchemeMutableTreelist |
                      SchemeBigDecimal |
                      SchemeBox |
                      BytecodeClosure |
                      BytecodeCaseClosure
end
