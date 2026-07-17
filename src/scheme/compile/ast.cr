# ===========================================================================
# AST: the analyzed form of a program
# ===========================================================================
#
# The Reader emits s-expressions (SchemeValue trees). The Analyzer
# (analyzer.cr) translates those, once, into this typed Node AST, which
# BytecodeCompiler (bytecode_compiler.cr) then compiles into a Chunk for the
# VM to run — instead of re-parsing the raw s-expression on every visit. This
# is the seam where s-expression optimizations (constant folding, dead-branch
# removal, …) are applied before a form is ever compiled. Every form the
# Analyzer sees becomes a typed Node (a malformed form becomes a ThrowNode).

module Scheme
  abstract class Node
    # Source position of the form this node came from, for backtraces/errors —
    # carried from the originating Cons (values.cr's Cons#pos).
    getter pos : SourcePos?

    def initialize(@pos : SourcePos? = nil)
    end
  end

  # A malformed form the analyzer detected at analyze time but whose error must
  # surface only when actually reached at runtime — a malformed form in an
  # untaken branch or an unreached lambda body must not error until reached.
  # Compiles to Op::Throw, which raises `SchemeRuntimeError.new(message)`.
  class ThrowNode < Node
    getter message : String

    def initialize(@message : String, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # A self-evaluating datum, or the result of `quote` — value known at analysis
  # time, returned as-is.
  class LiteralNode < Node
    getter value : SchemeValue

    def initialize(@value : SchemeValue, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # A variable reference resolved by name at eval time (`env.get(name)`). Used
  # for identifiers the analyzer can't give a fixed lexical address — e.g. a
  # body-internal `define` whose slot only appears once the define runs.
  class VarRefNode < Node
    getter name : String

    def initialize(@name : String, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # A lexically-addressed local: the binding lives `depth` env frames up, at
  # value slot `index`. Read directly (no name compare / hash).
  # `name` is kept as a fallback for the rare case the target frame has promoted
  # to a Hash. Only emitted for param/rest slots (fixed, always-valid indices).
  class LocalRefNode < Node
    getter depth : Int32
    getter index : Int32
    getter name : String

    def initialize(@depth : Int32, @index : Int32, @name : String, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # A free variable — proven by the analyzer to resolve in the (root) global
  # env, since a lambda only compiles when fallback-free and thus never closes
  # over a `let`-bound name. Inline-caches the resolved value keyed on the root
  # env's version, so a hot loop with no top-level (re)definition skips the
  # global hash lookup entirely.
  class GlobalRefNode < Node
    getter name : String
    property cache_value : SchemeValue?
    property cache_version : Int32 = -1

    def initialize(@name : String, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (if test conseq [alt]). `conseq`/`alt` are in tail position.
  class IfNode < Node
    getter test : Node
    getter conseq : Node
    getter alt : Node?

    def initialize(@test : Node, @conseq : Node, @alt : Node?, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (begin body...). Last element is in tail position; earlier ones run for
  # effect. An empty begin evaluates to NIL.
  class BeginNode < Node
    getter body : Array(Node)

    def initialize(@body : Array(Node), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (define name value) / (define (name . formals) body...). Defines in the
  # current env; evaluates to the symbol name (matching eval_define).
  class DefineNode < Node
    getter name : String
    getter value : Node

    def initialize(@name : String, @value : Node, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (lambda formals body...). Evaluating this produces a closure (a
  # BytecodeClosure, via the register VM's compile_lambda) whose body_nodes
  # are these already-analyzed nodes; `raw_body` (the original
  # s-expressions) rides along for the closure's `write`/introspection form.
  # `name` is filled in by a surrounding `define`.
  class LambdaNode < Node
    getter params : Array(String)
    getter rest : String?
    getter body_nodes : Array(Node)
    getter raw_body : Array(SchemeValue)
    property name : String

    def initialize(@params : Array(String), @rest : String?, @body_nodes : Array(Node),
                   @raw_body : Array(SchemeValue), @name : String = "lambda", pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (let ((name init)...) body...). Inits are evaluated in the OUTER env; the
  # body runs in a fresh frame binding `names` to the init values, so the body
  # is analyzed with the lexical scope extended by `names` (addressable at fixed
  # slots 0..n-1). Last body element is in tail position.
  class LetNode < Node
    getter names : Array(String)
    getter inits : Array(Node)
    getter body : Array(Node)

    def initialize(@names : Array(String), @inits : Array(Node), @body : Array(Node), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (let loop ((p init)...) body...). Binds `loop_name` to a procedure of
  # `params` in its own frame, then calls it with the inits — recursive calls
  # to `loop_name` in the body flow through the ordinary compiled-closure
  # tail-call path (constant space). `raw_body` backs the closure's `body`
  # field; `body` is the analyzed version the register VM compiles/runs.
  class NamedLetNode < Node
    getter loop_name : String
    getter params : Array(String)
    getter inits : Array(Node)
    getter body : Array(Node)
    getter raw_body : Array(SchemeValue)

    def initialize(@loop_name : String, @params : Array(String), @inits : Array(Node),
                   @body : Array(Node), @raw_body : Array(SchemeValue), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (set! name value). Resolved by name at eval time (env.set!), which bumps the
  # target frame's version — invalidating any global inline cache of `name`.
  class SetBangNode < Node
    getter name : String
    getter value : Node

    def initialize(@name : String, @value : Node, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (when test body...) / (unless test body...). `negate` flips the sense. Body's
  # last element is in tail position; a false (resp. true) test yields NIL.
  class WhenNode < Node
    getter test : Node
    getter body : Array(Node)
    getter? negate : Bool

    def initialize(@test : Node, @body : Array(Node), @negate : Bool, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (and e...) / (or e...). Short-circuit; the last expr is in tail position.
  class AndNode < Node
    getter exprs : Array(Node)

    def initialize(@exprs : Array(Node), pos : SourcePos? = nil)
      super(pos)
    end
  end

  class OrNode < Node
    getter exprs : Array(Node)

    def initialize(@exprs : Array(Node), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (let* ((name init)...) body...). One frame; names are defined one at a time,
  # so init_i sees names[0..i-1] (but not itself or later). Body sees all.
  class LetStarNode < Node
    getter names : Array(String)
    getter inits : Array(Node)
    getter body : Array(Node)

    def initialize(@names : Array(String), @inits : Array(Node), @body : Array(Node), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (letrec ((name init)...) body...) / letrec*. All names are bound in one
  # fresh frame (initially unspecified) before the inits run, so an init may
  # reference any name (mutual recursion); inits are assigned in order. Names
  # sit at fixed slots 0..n-1, so inits and body address them directly.
  class LetrecNode < Node
    getter names : Array(String)
    getter inits : Array(Node)
    getter body : Array(Node)

    def initialize(@names : Array(String), @inits : Array(Node), @body : Array(Node), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # One (test body...) / (test => proc) / (else body...) clause of a cond.
  class CondClause
    getter test : Node?
    getter body : Array(Node)
    getter arrow : Node?
    getter? els : Bool
    # A malformed clause detected at analyze time: when cond/guard evaluation
    # REACHES this clause it raises this message. The error is deferred to when
    # the clause is actually reached so a malformed clause after an earlier
    # matching clause is never seen.
    getter throw_msg : String?

    def initialize(@test : Node?, @body : Array(Node), @arrow : Node?, @els : Bool, @throw_msg : String? = nil)
    end
  end

  # (cond clause...). First clause whose test is true (or else) supplies the
  # result: its body's last form in tail position, or `=> proc` applied to the
  # test value, or the bare test value when there's no body.
  class CondNode < Node
    getter clauses : Array(CondClause)

    def initialize(@clauses : Array(CondClause), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # One clause of a case: `datums` (nil for else) matched by eqv? against the key.
  class CaseClause
    getter datums : Array(SchemeValue)?
    getter body : Array(Node)
    getter arrow : Node?
    getter? els : Bool
    # See CondClause#throw_msg — a malformed case clause that raises when reached.
    getter throw_msg : String?

    def initialize(@datums : Array(SchemeValue)?, @body : Array(Node), @arrow : Node?, @els : Bool, @throw_msg : String? = nil)
    end
  end

  # (case key clause...).
  class CaseNode < Node
    getter key : Node
    getter clauses : Array(CaseClause)

    def initialize(@key : Node, @clauses : Array(CaseClause), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # A fixed-arity primitive whose head statically resolves to a known builtin.
  # Compiles to a fused prim op — evaluating the arg nodes and performing
  # the op directly — skipping the generic apply path (args-array alloc,
  # arity check, backtrace-frame push, closure indirection). Guarded at runtime:
  # if the name has been redefined/shadowed away from `prim`, it deopts to
  # resolving the new binding and applying it to the evaluated args.
  #
  # Historically excluded any builtin whose failure mode is tested/expected
  # to show up as its OWN backtrace frame — fusion pushes no Frame, so a
  # naive fusion would lose it. The whole (scheme cxr) accessor family
  # (`car`/`cdr`/`caar`/…/`cddddr`, whose "expected pair" error must appear as
  # its own frame — see spec/scheme/eval/backtrace_spec.cr) is the exception
  # that proves the rule: it fuses into PrimOp::Cxr, but the VM handler fast-
  # paths only the all-pairs case and *deopts to the real builtin* (via
  # @interp.apply, which pushes the frame) on the first non-pair, so the error
  # message/frame/position stay byte-identical. Any other error-framed builtin
  # added here must do the same, or it does not belong.
  enum PrimOp
    Add
    Sub
    Mul
    NumLt
    NumLe
    NumGt
    NumGe
    NumEq
    VectorRef
    VectorSet
    VectorLength
    StringRef
    StringSet
    BytevectorU8Ref
    BytevectorU8Set
    Cons
    Not
    IsNull
    IsPair
    # The whole (scheme cxr) accessor family (car/cdr/caar/.../cddddr) fuses
    # into this single op; the specific car/cdr chain rides in the emitted
    # instruction's operand (see bytecode_compiler.cr's cxr_code). Recognized
    # in the analyzer by name pattern (cxr_name?), not via PRIM_OPS.
    Cxr
    # Unary numeric prims: abs, and the compare-against-zero predicates
    # zero?/positive?/negative? (all three emit Op::CmpZero, distinguished by
    # operand c). Each fast-paths int/float inline and deopts to its builtin.
    Abs
    IsZero
    IsPositive
    IsNegative
  end

  # Builtin names the analyzer specializes into a PrimCallNode, the op each
  # maps to, and the exact call arity that must match for the specialization
  # to apply (a call with a different argument count is left as a plain
  # AppNode, so the builtin's own arity check reports the error normally).
  PRIM_OPS = {
    "+"                  => {PrimOp::Add, 2},
    "-"                  => {PrimOp::Sub, 2},
    "*"                  => {PrimOp::Mul, 2},
    "<"                  => {PrimOp::NumLt, 2},
    "<="                 => {PrimOp::NumLe, 2},
    ">"                  => {PrimOp::NumGt, 2},
    ">="                 => {PrimOp::NumGe, 2},
    "="                  => {PrimOp::NumEq, 2},
    "vector-ref"         => {PrimOp::VectorRef, 2},
    "vector-set!"        => {PrimOp::VectorSet, 3},
    "vector-length"      => {PrimOp::VectorLength, 1},
    "string-ref"         => {PrimOp::StringRef, 2},
    "string-set!"        => {PrimOp::StringSet, 3},
    "bytevector-u8-ref"  => {PrimOp::BytevectorU8Ref, 2},
    "bytevector-u8-set!" => {PrimOp::BytevectorU8Set, 3},
    "cons"               => {PrimOp::Cons, 2},
    "not"                => {PrimOp::Not, 1},
    "null?"              => {PrimOp::IsNull, 1},
    "pair?"              => {PrimOp::IsPair, 1},
    "abs"                => {PrimOp::Abs, 1},
    "zero?"              => {PrimOp::IsZero, 1},
    "positive?"          => {PrimOp::IsPositive, 1},
    "negative?"          => {PrimOp::IsNegative, 1},
    # car/cdr/caar/.../cddddr are recognized by name pattern in the analyzer
    # (cxr_name?) → PrimOp::Cxr, not listed here.
  }

  class PrimCallNode < Node
    getter op : PrimOp
    getter name : String
    getter args : Array(Node)
    getter prim : Builtin
    getter src : Cons
    # Global-env version at which we last confirmed `name` is still `prim`;
    # lets the hot path skip the identity re-check while no top-level
    # define/set! has happened.
    property ok_version : Int32 = -1

    def initialize(@op : PrimOp, @name : String, @args : Array(Node), @prim : Builtin, @src : Cons, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (case-lambda (formals body...) ...). Produces a CaseLambda of compiled
  # Lambda clauses (a malformed clause becomes a ThrowNode at analyze time).
  class CaseLambdaNode < Node
    getter clauses : Array(LambdaNode)

    def initialize(@clauses : Array(LambdaNode), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (define-values (a b . rest) producer). Binds the producer's multiple values
  # into the current env.
  class DefineValuesNode < Node
    getter params : Array(String)
    getter rest : String?
    getter producer : Node

    def initialize(@params : Array(String), @rest : String?, @producer : Node, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # One (formals producer) clause of a let-values / let*-values.
  struct LetValuesBinder
    getter params : Array(String)
    getter rest : String?
    getter producer : Node

    def initialize(@params : Array(String), @rest : String?, @producer : Node)
    end
  end

  # (let-values ((formals producer)...) body...) and let*-values (sequential).
  # Each producer's values are destructured into a shared fresh frame; the body
  # sees all bound names. Non-sequential producers run in the outer env;
  # sequential ones see the bindings from earlier clauses.
  class LetValuesNode < Node
    getter binders : Array(LetValuesBinder)
    getter body : Array(Node)
    getter? sequential : Bool

    def initialize(@binders : Array(LetValuesBinder), @body : Array(Node), @sequential : Bool, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # Compiled quasiquote template — mirrors expand_qq's structure with unquote
  # holes pre-analyzed into Nodes, so eval rebuilds the datum without re-parsing.
  abstract class QQTemplate
  end

  # A literal fragment kept verbatim.
  class QQConst < QQTemplate
    getter value : SchemeValue

    def initialize(@value : SchemeValue)
    end
  end

  # ,expr at depth 1 — eval the node, insert its value.
  class QQHole < QQTemplate
    getter node : Node

    def initialize(@node : Node)
    end
  end

  # ,@expr at depth 1 (only meaningful as a list/vector element) — eval the node
  # (a list) and splice its elements in place.
  class QQSpliceItem < QQTemplate
    getter node : Node

    def initialize(@node : Node)
    end
  end

  # A (possibly dotted) list template: items rebuilt in order (a QQSpliceItem
  # splices), then `tail`.
  class QQList < QQTemplate
    getter items : Array(QQTemplate)
    getter tail : QQTemplate

    def initialize(@items : Array(QQTemplate), @tail : QQTemplate)
    end
  end

  class QQVector < QQTemplate
    getter items : Array(QQTemplate)

    def initialize(@items : Array(QQTemplate))
    end
  end

  # (quasiquote template).
  class QuasiquoteNode < Node
    getter template : QQTemplate

    def initialize(@template : QQTemplate, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (delay expr) / (delay-force expr). Evaluates to a SchemePromise carrying the
  # analyzed thunk; `force` runs it (delay-force chaining handled by force).
  class DelayNode < Node
    getter thunk : Node

    def initialize(@thunk : Node, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (guard (var clause...) body...). Body runs protected by a Crystal rescue;
  # on a SchemeError the condition binds to `var` (in a fresh handler frame) and
  # the cond-style clauses run; no match re-raises. Not tail (the rescue must
  # stay in effect), so its value is returned directly.
  class GuardNode < Node
    getter var : String
    getter clauses : Array(CondClause)
    getter body : Array(Node)

    def initialize(@var : String, @clauses : Array(CondClause), @body : Array(Node), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (parameterize ((param val)...) body...). Saves each parameter's value, sets
  # the new (converter-applied) value, runs the body, and restores in an ensure.
  struct ParamBinding
    getter param : Node
    getter value : Node

    def initialize(@param : Node, @value : Node)
    end
  end

  class ParameterizeNode < Node
    getter bindings : Array(ParamBinding)
    getter body : Array(Node)

    def initialize(@bindings : Array(ParamBinding), @body : Array(Node), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # Imperative/library forms that are one-shot and evaluate via a dedicated
  # helper (import/define-library/define-record-type/define-syntax/defmacro).
  # The node just carries the original form and calls the helper at eval time.
  # These are never in tail position and never hot.
  enum HelperForm
    Import
    DefineLibrary
    DefineRecordType
    DefineSyntax
    Defmacro
  end

  class HelperFormNode < Node
    getter kind : HelperForm
    getter form : Cons

    def initialize(@kind : HelperForm, @form : Cons, pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (do ((var init [step])...) (test result...) command...). Vars bound in a
  # fresh frame each iteration; a nil step leaves the var unchanged. When test
  # is true the result body runs (last in tail position); otherwise commands run
  # for effect, steps are computed, and a new iteration frame is bound.
  class DoNode < Node
    getter names : Array(String)
    getter inits : Array(Node)
    getter steps : Array(Node?)
    getter test : Node
    getter results : Array(Node)
    getter commands : Array(Node)

    def initialize(@names : Array(String), @inits : Array(Node), @steps : Array(Node?),
                   @test : Node, @results : Array(Node), @commands : Array(Node), pos : SourcePos? = nil)
      super(pos)
    end
  end

  # (proc arg...). `callee`/`args` are analyzed nodes; `src` is the original
  # form, retained so that a head resolving to a Macro/syntax-rules only at
  # runtime can be expanded and re-analyzed on the spot, and for the source
  # position.
  class AppNode < Node
    getter callee : Node
    getter args : Array(Node)
    getter src : Cons

    def initialize(@callee : Node, @args : Array(Node), @src : Cons, pos : SourcePos? = nil)
      super(pos)
    end
  end
end
