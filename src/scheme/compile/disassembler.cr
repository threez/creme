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
      Op::PushHandler,
    }

    # Ops whose b operand is a const-pool index.
    CONST_B_OPS = {Op::LoadK, Op::GetGlobal, Op::HelperForm, Op::HelperFormLocal}
    # Ops whose a operand is a const-pool index.
    CONST_A_OPS = {Op::DefGlobal, Op::SetGlobal, Op::ReturnGlobal, Op::Throw}
    # Ops whose c operand is a const-pool index.
    CONST_C_OPS = {Op::CaseMatch}
    # Ops whose d operand is a const-pool index (the callee's global name).
    CONST_D_OPS = {Op::CallGlobal, Op::TailCallGlobal}

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

        if CONST_B_OPS.includes?(instr.op) && instr.b < chunk.consts.size
          io << "   ; " << chunk.consts[instr.b].write_string
        elsif CONST_A_OPS.includes?(instr.op) && instr.a < chunk.consts.size
          io << "   ; " << chunk.consts[instr.a].write_string
        elsif CONST_C_OPS.includes?(instr.op) && instr.c < chunk.consts.size
          io << "   ; " << chunk.consts[instr.c].write_string
        elsif CONST_D_OPS.includes?(instr.op) && instr.d < chunk.consts.size
          io << "   ; " << chunk.consts[instr.d].write_string
        elsif instr.op == Op::Closure && instr.b < chunk.protos.size
          io << "   ; proto " << instr.b << " (" << chunk.protos[instr.b].name << ")"
        end
        io << '\n'
      end
      chunk.protos.each_with_index do |proto, i|
        io << '\n'
        disassemble(proto, "#{name} > proto #{i} (#{proto.name})", io)
      end
    end
  end
end
