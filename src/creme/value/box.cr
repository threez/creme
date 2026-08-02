# ===========================================================================
# SchemeBox — a generic wrapper for an opaque foreign host value
# ===========================================================================

module Creme
  # A single SchemeValue union member that stands in for any opaque foreign
  # handle a `(creme ...)` module wraps — a compiled `Regex`, a DB connection,
  # a TUI object, and so on. Instead of every such module adding its own
  # `class SchemeX` and its own entry to the `SchemeValue` alias, it boxes its
  # payload here under a `tag` and recovers it with `get(T)` at the (module-
  # local) use site. Adding a new opaque type then needs no value/alias.cr
  # edit at all.
  #
  # The payload is type-erased through the stdlib `::Box` (a GC-tracked
  # pointer, so the wrapped object stays alive as long as this SchemeBox does)
  # and recovered as its original type by the module that created the tag —
  # which is the only code that knows the concrete type. `get` is an unchecked
  # reinterpret, so callers gate on `tag` first (see each module's `*_arg`
  # helper). `tag` also names the kind in predicates and error messages, and
  # `display` is the precomputed read/display form.
  #
  # NOT for frequently-constructed *values* (e.g. bigdecimals): boxing adds a
  # heap indirection per construction — fine for once-per-session handles, but
  # a per-operation numeric result keeps its own class instead.
  class SchemeBox
    include SchemeBaseValue
    getter tag : String
    @payload : Void*

    def initialize(@tag : String, payload : T, @display : String) forall T
      @payload = ::Box.box(payload)
    end

    # Recover the wrapped value as the type its module boxed it as. Unchecked —
    # the caller must pass the type matching `tag` (guaranteed by gating on
    # `tag` beforehand), since an ::Box unbox is a raw reinterpret.
    def get(_type : T.class) : T forall T
      ::Box(T).unbox(@payload)
    end

    def to_display(io : IO) : Nil
      io << @display
    end
  end
end
