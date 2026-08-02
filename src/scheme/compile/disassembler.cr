# ===========================================================================
# Disassembler: human-readable dump of a compiled Chunk, for `creme
# --dump-bytecode`/`-S` (see main.cr) and ad-hoc debugging.
# ===========================================================================

module Scheme
  module Disassembler
    # Ops whose b operand is a signed relative jump offset (see opcode.cr) —
    # printed as an absolute target index instead of the raw offset.
    JUMP_OPS = {
      Op::Jmp, Op::TestFalse, Op::TestLt, Op::TestLe, Op::TestGt, Op::TestGe, Op::TestEq, Op::TestIsEq,
      Op::TestLtImm, Op::TestLeImm, Op::TestGtImm, Op::TestGeImm, Op::TestEqImm, Op::TestIsEqImm,
      Op::TestLtUp, Op::TestLeUp, Op::TestGtUp, Op::TestGeUp, Op::TestEqUp, Op::TestIsEqUp,
      Op::PushHandler, Op::ForPrep, Op::ForLoop,
      Op::ForLoopGuardedInc, Op::ForLoopGuardedDec, Op::TestGlobalIdentity,
    }

    # Which operand field (:a/:b/:c/:d) is a const-pool index, per op.
    CONST_OPS = {
      Op::LoadK => :b, Op::GetGlobal => :b, Op::HelperForm => :b, Op::HelperFormLocal => :b,
      Op::DefGlobal => :a, Op::SetGlobal => :a, Op::ReturnGlobal => :a, Op::Throw => :a,
      Op::CaseMatch => :c,
      Op::CallGlobal => :d, Op::TailCallGlobal => :d,
      Op::ForLoopGuardedInc => :d, Op::ForLoopGuardedDec => :d, Op::TestGlobalIdentity => :a,
    }

    def self.disassemble(chunk : Chunk, name : String = chunk.name, io : IO = STDOUT) : Nil
      io << "== " << name << " (regs=" << chunk.num_registers << ", params=" << chunk.param_count
      io << (chunk.has_rest? ? "+rest" : "") << ") ==\n"
      chunk.instructions.each_with_index do |instr, i|
        io << i.to_s.rjust(4) << "  " << instr.op.to_s.ljust(16)
        io << " a=" << instr.a
        if JUMP_OPS.includes?(instr.op)
          io << " -> " << (i + 1 + instr.b)
        else
          io << " b=" << instr.b
        end
        io << " c=" << instr.c if instr.c != 0 || instr.op.in?({Op::Call, Op::TailCall, Op::MakeCaseClosure, Op::Destructure, Op::ParamPush})
        io << " d=" << instr.d if instr.d != 0
        annotate(io, chunk, instr)
        io << '\n'
      end
      chunk.protos.each_with_index do |proto, i|
        io << '\n'
        disassemble(proto, "#{name} > proto #{i} (#{proto.name})", io)
      end
    end

    # Trailing "; ..." comment for an instruction whose operand references
    # something worth resolving and printing (a const-pool entry, a nested
    # proto, or a case-dispatch table) — split out from `disassemble` itself
    # to keep that method's own branching (jump-offset vs. plain operand
    # printing) simple.
    private def self.annotate(io : IO, chunk : Chunk, instr : Instruction) : Nil
      if field = CONST_OPS[instr.op]?
        idx = operand(instr, field)
        io << "   ; " << chunk.consts[idx].write_string if idx < chunk.consts.size
      elsif instr.op == Op::Closure && instr.b < chunk.protos.size
        io << "   ; proto " << instr.b << " (" << chunk.protos[instr.b].name << ")"
      elsif instr.op == Op::CaseDispatch && instr.b < chunk.case_dispatch_tables.size
        table = chunk.case_dispatch_tables[instr.b]
        io << "   ; table " << instr.b << ", " << table.targets.size << " keys, default -> " << table.default
      end
    end

    private def self.operand(instr : Instruction, field : Symbol) : Int32
      case field
      when :a then instr.a
      when :b then instr.b
      when :c then instr.c
      else         instr.d
      end
    end
  end
end
