# ===========================================================================
# CVMEmitter: compiles a whole script (plus its transitively-imported
# pure-Scheme library bodies) down to a SINGLE Chunk and serializes it via
# the SAME "SCB1" format (ChunkSerializer) the real Crystal VM already
# round-trips through — no separate/narrower cvm-specific format anymore.
# ===========================================================================
#
# Replaces the old CVMSerializer (deleted): that serializer wrote a
# cvm-specific "CVM2" format with its own compacted opcode-id table and
# constant-tag numbering, and compiled each top-level form into its OWN
# Chunk, wrapped in an explicit `source_file` + chunk-count header so
# cvm/main.c could load and run each in sequence sharing one VM/global
# table. SCB1 has no such multi-chunk envelope — ChunkSerializer.serialize
# writes exactly one Chunk — so instead of inventing a new envelope, this
# emitter compiles EVERYTHING (library bodies, then the script's own forms)
# into one combined Chunk via BytecodeCompiler.compile_program, which
# already treats an Array(Node) as one sequential body (same mechanism
# `(begin ...)` itself compiles to). The result is a plain single-chunk
# SCB1 file, identical in shape to what `(creme bootstrap)`'s
# load-chunk-bytes already reads.
#
# Import handling mirrors the old CVMSerializer.emit exactly: each `(import
# ...)` form found among `forms` is run for REAL (via `interp.eval_import`)
# the moment it's analyzed, matching `BytecodeCompiler.run_program`'s own
# incremental analyze-compile-RUN-one-form-at-a-time model for this one
# special form — this is what makes `interp.libraries` populated (and any
# macro a later form needs to expand) by the time subsequent forms are
# analyzed. Once every import in `forms` has been analyzed (and thus
# really run), `interp.libraries` holds every transitively-loaded library,
# in load order; each file-based one's own top-level body forms are
# re-analyzed here too (a second analyze pass purely for cvm's benefit —
# see `Interpreter#library_body_forms_for_cvm`) and their resulting Nodes
# are placed FIRST in the combined program, so the emitted chunk defines
# each library's globals before the script's own top-level forms run. A
# Crystal-native library (e.g. `(creme mux)`, no `.sld` file of its own)
# has nothing to compile — `library_body_forms_for_cvm` returns nil for
# those, and cvm implements their Scheme-visible surface as hand-written
# native builtins instead (see cvm/mux.c et al.), exactly as before.
module Scheme
  module CVMEmitter
    def self.emit(interp : Interpreter, forms : Array(SchemeValue), env : Env) : Bytes
      target_env = env
      app_nodes = forms.map do |form|
        interp.eval_import(form, target_env) if form.is_a?(Cons) && (head = form.car).is_a?(SchemeSym) && head.name == "import"
        interp.analyze(form, target_env)
      end

      library_nodes = [] of Node
      interp.libraries.each do |name, library|
        body_forms = interp.library_body_forms_for_cvm(name)
        next unless body_forms
        body_forms.each { |form| library_nodes << interp.analyze(form, library.env) }
      end

      chunk = BytecodeCompiler.compile_program(library_nodes + app_nodes)
      ChunkSerializer.serialize(chunk)
    end
  end
end
