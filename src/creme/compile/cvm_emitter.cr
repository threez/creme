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
module Creme
  module CVMEmitter
    def self.emit(interp : Interpreter, forms : Array(SchemeValue), env : Env) : Bytes
      target_env = env
      interp.emitting_for_cvm = true
      begin
        app_nodes = forms.map_with_index do |form, i|
          if form.is_a?(Cons) && (head = form.car).is_a?(SchemeSym) && head.name == "import"
            begin
              interp.eval_import(form, target_env)
            rescue ex : SchemeRuntimeError
              raise ex unless ex.message.try(&.starts_with?("import: unknown library"))
              # A library some EARLIER ordinary form generates at runtime
              # (e.g. examples/26-import-generated-library.scm's own
              # file-write of ./modules/greeter.sld) doesn't exist yet --
              # unlike the self-hosted compiler's own compile-import!
              # (compiler.sld), which can just guard/defer to a REAL
              # runtime import! call because it stays resident at runtime,
              # cvm has no resident compiler to defer to at all, so the
              # side effect must actually happen NOW, during emission.
              # Real-run (not just analyze) every earlier form in program
              # order -- the exact analyze-compile-RUN-one-form-at-a-time
              # model BytecodeCompiler.run_program itself uses -- then
              # retry the import once. Each earlier form's bytecode still
              # gets emitted into the final chunk as usual right below, so
              # this doesn't skip anything; it just ALSO runs those forms'
              # side effects one extra time, right here, so this file
              # exists by the time resolve_library goes looking for it.
              # Safe for an idempotent effect like file-write; a
              # non-idempotent one (e.g. a `display` before a
              # runtime-generated import) would print twice -- an accepted,
              # narrow tradeoff for this one failure-only recovery path,
              # not a general double-execution risk (the common case,
              # where imports already succeed immediately, never takes it).
              forms[0...i].each do |earlier|
                node = interp.analyze(earlier, target_env)
                chunk = BytecodeCompiler.compile_program([node])
                VM.new(interp, target_env).run(chunk)
              end
              interp.eval_import(form, target_env)
            end
          end
          interp.analyze(form, target_env)
        end

        library_nodes = [] of Node
        interp.libraries.each do |name, library|
          body_forms = interp.library_body_forms_for_cvm(name)
          next unless body_forms
          # cvm's global table is one flat, name-interned array with no
          # per-library namespacing at all (cvm/vm.c's cvm_global_intern) —
          # two libraries each defining an internal (non-exported) helper of
          # the same name would otherwise silently clobber each other's
          # slot (last DefGlobal wins). Only a library's OWN internal names
          # are safe to qualify — its exports must keep their plain name,
          # since that's the only thing tying an importer's reference to
          # this definition once flattened (imports are a compile-time
          # no-op in cvm, see cvm/README.md). Scoped to a rename map
          # consulted only by Analyzer's cvm_global_name helper, active only
          # for this one library's own analyze pass below (see Interpreter#
          # cvm_rename's own doc comment) — every other library, and the
          # app's own top-level forms, analyze completely unaffected.
          internal_names = top_level_define_names(body_forms) - library.exports.values
          interp.cvm_rename = internal_names.empty? ? nil : internal_names.each_with_object({} of String => String) { |internal_name, rename|
            rename[internal_name] = "#{SchemeLibrary.library_name_string(name)} #{internal_name}"
          }
          begin
            body_forms.each { |form| library_nodes << interp.analyze(form, library.env) }
          ensure
            interp.cvm_rename = nil
          end
        end

        required_families = interp.libraries.keys
          .select { |name| name.size == 3 && name[0] == "creme" && name[1] == "builtin" }
          .map { |name| name[2] }
          .uniq!

        chunk = BytecodeCompiler.compile_program(library_nodes + app_nodes)
        ChunkSerializer.serialize(chunk, required_families: required_families)
      ensure
        interp.emitting_for_cvm = false
      end
    end

    # Every name a library's own body directly `define`s at its top level —
    # the only shape Analyzer's cvm_global_name rename hook actually
    # rewrites (a plain `(define name ...)`/`(define (name args...) ...)`).
    # Deliberately narrower than every name-introducing top-level form: a
    # top-level `define-record-type`/`define-syntax`/`defmacro` binds its
    # name(s) via Op::HelperForm's own raw-form path (bytecode_compiler.cr),
    # not through analyze_define/DefineNode at all, so renaming them here
    # would produce a mismatch (the map would claim a rename that nothing
    # downstream ever applies). Those three stay excluded from the
    # collision-safety this rename map provides — an unexported top-level
    # define-record-type/define-syntax/defmacro name can still collide
    # with another library's same-named one under --emit-cvm.
    private def self.top_level_define_names(body_forms : Array(SchemeValue)) : Array(String)
      names = [] of String
      body_forms.each do |form|
        next unless form.is_a?(Cons) && (head = form.car).is_a?(SchemeSym) && head.name == "define"
        rest = form.cdr
        next unless rest.is_a?(Cons)
        case target = rest.car
        when SchemeSym
          names << target.name
        when Cons
          fname = target.car
          names << fname.name if fname.is_a?(SchemeSym)
        end
      end
      names
    end
  end
end
