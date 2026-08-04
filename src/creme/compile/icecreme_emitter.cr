# ===========================================================================
# IcecremeEmitter: compiles a whole script (plus its transitively-imported
# pure-Scheme library bodies) down to a SINGLE Chunk and serializes it via
# the SAME "ICE" format (ChunkSerializer) the real Crystal VM already
# round-trips through — no separate/narrower icecreme-specific format anymore.
# ===========================================================================
#
# Replaces the old CVMSerializer (deleted): that serializer wrote a
# icecreme-specific "CVM2" format with its own compacted opcode-id table and
# constant-tag numbering, and compiled each top-level form into its OWN
# Chunk, wrapped in an explicit `source_file` + chunk-count header so
# icecreme/main.c could load and run each in sequence sharing one VM/global
# table. ICE has no such multi-chunk envelope — ChunkSerializer.serialize
# writes exactly one Chunk — so instead of inventing a new envelope, this
# emitter compiles EVERYTHING (library bodies, then the script's own forms)
# into one combined Chunk via BytecodeCompiler.compile_program, which
# already treats an Array(Node) as one sequential body (same mechanism
# `(begin ...)` itself compiles to). The result is a plain single-chunk
# ICE file, identical in shape to what `(creme bootstrap)`'s
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
# re-analyzed here too (a second analyze pass purely for icecreme's benefit —
# see `Interpreter#library_body_forms_for_icecreme`) and their resulting Nodes
# are placed FIRST in the combined program, so the emitted chunk defines
# each library's globals before the script's own top-level forms run. A
# Crystal-native library (e.g. `(creme mux)`, no `.sld` file of its own)
# has nothing to compile — `library_body_forms_for_icecreme` returns nil for
# those, and icecreme implements their Scheme-visible surface as hand-written
# native builtins instead (see icecreme/mux.c et al.), exactly as before.
module Creme
  module IcecremeEmitter
    # Serializes a whole program to ICE bytes -- the `--emit-icecreme` path.
    # `strip: true` drops never-called inlined-library globals (see build).
    def self.emit(interp : Interpreter, forms : Array(SchemeValue), env : Env, strip : Bool = false) : Bytes
      chunk, required_families = build(interp, forms, env, strip)
      ChunkSerializer.serialize(chunk, required_families: required_families)
    end

    # Compiles a whole program (transitively-imported pure-Scheme library
    # bodies inlined first, then the script's own forms) into the SINGLE
    # combined Chunk `emit` above serializes -- returned here without
    # serializing so callers that only want to inspect it (e.g. `creme -S
    # --static`, which disassembles this exact chunk in memory rather than
    # writing an .ice and reading it back) can skip the wire round-trip.
    # Also returns the required native-builtin family names (see `emit`).
    def self.build(interp : Interpreter, forms : Array(SchemeValue), env : Env, strip : Bool = false) : {Chunk, Array(String)}
      target_env = env
      interp.emitting_for_icecreme = true
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
              # icecreme has no resident compiler to defer to at all, so the
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
          body_forms = interp.library_body_forms_for_icecreme(name)
          next unless body_forms
          # icecreme's global table is one flat, name-interned array with no
          # per-library namespacing at all (icecreme/vm.c's creme_global_intern) —
          # two libraries each defining an internal (non-exported) helper of
          # the same name would otherwise silently clobber each other's
          # slot (last DefGlobal wins). Only a library's OWN internal names
          # are safe to qualify — its exports must keep their plain name,
          # since that's the only thing tying an importer's reference to
          # this definition once flattened (imports are a compile-time
          # no-op in icecreme, see icecreme/README.md). Scoped to a rename map
          # consulted only by Analyzer's icecreme_global_name helper, active only
          # for this one library's own analyze pass below (see Interpreter#
          # icecreme_rename's own doc comment) — every other library, and the
          # app's own top-level forms, analyze completely unaffected.
          internal_names = top_level_define_names(body_forms) - library.exports.values
          interp.icecreme_rename = internal_names.empty? ? nil : internal_names.each_with_object({} of String => String) { |internal_name, rename|
            rename[internal_name] = "#{SchemeLibrary.library_name_string(name)} #{internal_name}"
          }
          begin
            body_forms.each { |form| library_nodes << interp.analyze(form, library.env) }
          ensure
            interp.icecreme_rename = nil
          end
        end

        required_families = interp.libraries.keys
          .select { |name| name.size == 3 && name[0] == "creme" && name[1] == "builtin" }
          .map { |name| name[2] }
          .uniq!

        kept_library_nodes = strip ? strip_dead_globals(library_nodes, app_nodes) : library_nodes
        chunk = BytecodeCompiler.compile_program(kept_library_nodes + app_nodes)
        {chunk, required_families}
      ensure
        interp.emitting_for_icecreme = false
      end
    end

    # Dead-global elimination (opt-in `--strip`): drops every inlined-library
    # top-level `(define name <lambda/value>)` whose global `name` is never
    # reachable from the app's own forms. Conservative and SOUND because it runs
    # on ANALYZED nodes (macros already expanded, so a global used only inside a
    # macro expansion is a real GlobalRefNode here), and because:
    #   * only plain DefineNodes are candidates -- define-syntax/defmacro/
    #     define-record-type are HelperFormNodes, always kept, and every symbol
    #     in their raw form is treated as a live reference;
    #   * the app's forms (and any non-define library form) are always kept and
    #     seed the live set;
    #   * over-approximation only ever KEEPS more (VarRefNode/SetBangNode/
    #     PrimCallNode names are all counted as references).
    # Assumes a closed world: a global reached only via eval/`environment`/a
    # computed `(string->symbol ...)` lookup would be wrongly dropped -- hence
    # opt-in. Any internal failure falls back to no stripping (never unsound).
    private def self.strip_dead_globals(library_nodes : Array(Node), app_nodes : Array(Node)) : Array(Node)
      # Candidate globals: plain top-level library defines, name -> the globals
      # its body references.
      refs_by_name = {} of String => Set(String)
      library_nodes.each do |node|
        next unless node.is_a?(DefineNode)
        refs = refs_by_name[node.name] ||= Set(String).new
        collect_global_refs(node.value, refs)
      end

      # Roots: everything the app code references, plus everything referenced by
      # any non-candidate library form (macros/record-types/side-effecting forms).
      live = Set(String).new
      app_nodes.each { |node| collect_global_refs(node, live) }
      library_nodes.each do |node|
        collect_global_refs(node, live) unless node.is_a?(DefineNode)
      end

      # Transitive closure over candidate references.
      worklist = live.to_a
      until worklist.empty?
        name = worklist.pop
        refs = refs_by_name[name]?
        next unless refs
        refs.each do |ref|
          worklist << ref if live.add?(ref)
        end
      end

      library_nodes.select { |node| !node.is_a?(DefineNode) || live.includes?(node.name) }
    rescue ex
      STDERR.puts "creme --strip: internal error (#{ex.message}); emitting without stripping"
      library_nodes
    end

    # Collects every global NAME `node`'s subtree could reference, into `into`.
    # Totally enumerates the AST (see ast.cr) -- an unhandled node type raises,
    # caught by strip_dead_globals's fallback, so a future node kind can never
    # silently hide a live reference and produce an unsound strip. Local refs and
    # binder names are deliberately skipped; global-ish name-carrying nodes
    # (GlobalRef/VarRef/SetBang/PrimCall) are collected conservatively.
    # ameba:disable Metrics/CyclomaticComplexity
    private def self.collect_global_refs(node : Node, into : Set(String)) : Nil
      case node
      when GlobalRefNode then into << node.name
      when VarRefNode    then into << node.name
      when LocalRefNode, LiteralNode, ThrowNode
        # leaves that reference no global
      when SetBangNode
        into << node.name
        collect_global_refs(node.value, into)
      when PrimCallNode
        into << node.name
        node.args.each { |a| collect_global_refs(a, into) }
      when DefineNode
        # a nested define binds a LOCAL -- skip the binder name, walk the value
        collect_global_refs(node.value, into)
      when IfNode
        collect_global_refs(node.test, into)
        collect_global_refs(node.conseq, into)
        node.alt.try { |a| collect_global_refs(a, into) }
      when BeginNode  then node.body.each { |n| collect_global_refs(n, into) }
      when LambdaNode then node.body_nodes.each { |n| collect_global_refs(n, into) }
      when CaseLambdaNode
        node.clauses.each { |c| c.body_nodes.each { |n| collect_global_refs(n, into) } }
      when LetNode, LetStarNode, LetrecNode
        node.inits.each { |n| collect_global_refs(n, into) }
        node.body.each { |n| collect_global_refs(n, into) }
      when NamedLetNode
        node.inits.each { |n| collect_global_refs(n, into) }
        node.body.each { |n| collect_global_refs(n, into) }
      when WhenNode
        collect_global_refs(node.test, into)
        node.body.each { |n| collect_global_refs(n, into) }
      when AndNode then node.exprs.each { |n| collect_global_refs(n, into) }
      when OrNode  then node.exprs.each { |n| collect_global_refs(n, into) }
      when CondNode
        node.clauses.each do |cl|
          cl.test.try { |t| collect_global_refs(t, into) }
          cl.arrow.try { |a| collect_global_refs(a, into) }
          cl.body.each { |n| collect_global_refs(n, into) }
        end
      when CaseNode
        collect_global_refs(node.key, into)
        node.clauses.each do |cl|
          cl.arrow.try { |a| collect_global_refs(a, into) }
          cl.body.each { |n| collect_global_refs(n, into) }
        end
      when DoNode
        node.inits.each { |n| collect_global_refs(n, into) }
        node.steps.each { |n| n.try { |s| collect_global_refs(s, into) } }
        collect_global_refs(node.test, into)
        node.results.each { |n| collect_global_refs(n, into) }
        node.commands.each { |n| collect_global_refs(n, into) }
      when DefineValuesNode then collect_global_refs(node.producer, into)
      when LetValuesNode
        node.binders.each { |b| collect_global_refs(b.producer, into) }
        node.body.each { |n| collect_global_refs(n, into) }
      when QuasiquoteNode then collect_qq_global_refs(node.template, into)
      when DelayNode      then collect_global_refs(node.thunk, into)
      when GuardNode
        node.clauses.each do |cl|
          cl.test.try { |t| collect_global_refs(t, into) }
          cl.arrow.try { |a| collect_global_refs(a, into) }
          cl.body.each { |n| collect_global_refs(n, into) }
        end
        node.body.each { |n| collect_global_refs(n, into) }
      when ParameterizeNode
        node.bindings.each do |b|
          collect_global_refs(b.param, into)
          collect_global_refs(b.value, into)
        end
        node.body.each { |n| collect_global_refs(n, into) }
      when AppNode
        collect_global_refs(node.callee, into)
        node.args.each { |a| collect_global_refs(a, into) }
      when HelperFormNode
        # define-syntax/defmacro/define-record-type/import: raw, un-analyzed
        # s-exprs. Their expansion's references aren't visible as nodes, so
        # conservatively treat every symbol appearing in the form as live.
        collect_symbols(node.form, into)
      else
        raise "collect_global_refs: unhandled node #{node.class}"
      end
    end

    private def self.collect_qq_global_refs(t : QQTemplate, into : Set(String)) : Nil
      case t
      when QQHole       then collect_global_refs(t.node, into)
      when QQSpliceItem then collect_global_refs(t.node, into)
      when QQList
        t.items.each { |i| collect_qq_global_refs(i, into) }
        collect_qq_global_refs(t.tail, into)
      when QQVector then t.items.each { |i| collect_qq_global_refs(i, into) }
      when QQConst
        # a literal fragment (SchemeValue) -- symbols in it are quoted data,
        # not references, so nothing to collect.
      end
    end

    private def self.collect_symbols(v : SchemeValue, into : Set(String)) : Nil
      case v
      when SchemeSym then into << v.name
      when Cons
        collect_symbols(v.car, into)
        collect_symbols(v.cdr, into)
      when SchemeVector
        v.value.each { |item| collect_symbols(item, into) }
      end
    end

    # Every name a library's own body directly `define`s at its top level —
    # the only shape Analyzer's icecreme_global_name rename hook actually
    # rewrites (a plain `(define name ...)`/`(define (name args...) ...)`).
    # Deliberately narrower than every name-introducing top-level form: a
    # top-level `define-record-type`/`define-syntax`/`defmacro` binds its
    # name(s) via Op::HelperForm's own raw-form path (bytecode_compiler.cr),
    # not through analyze_define/DefineNode at all, so renaming them here
    # would produce a mismatch (the map would claim a rename that nothing
    # downstream ever applies). Those three stay excluded from the
    # collision-safety this rename map provides — an unexported top-level
    # define-record-type/define-syntax/defmacro name can still collide
    # with another library's same-named one under --emit-icecreme.
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
