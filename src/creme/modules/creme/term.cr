# ===========================================================================
# term module: small, standalone raw-terminal primitives for a plain REPL
# loop with live syntax highlighting -- deliberately NOT built on the `tui`
# shard's TUI::Runtime/Screen/Widget framework (lib/tui/), which assumes a
# full-screen alt-screen app with its own diffing model. A REPL just needs:
# flip stdin into cbreak mode, read one key event at a time, and do small
# relative cursor moves/writes on the current line -- so this reuses the
# exact same proven `stty` shell-outs and escape-sequence disambiguation
# logic as lib/tui/src/tui/core/term.cr and lib/tui/src/tui/core/keys.cr
# (byte-by-byte read with a short ESC_TIMEOUT lookahead to tell a bare Esc
# apart from the start of a CSI/SS3 sequence), just exposed as flat
# procedures operating directly on STDIN/STDOUT instead of through any
# Runtime/Widget class.
#
# term-read-key's alist shape is `((kind . "char") (char . #\x) ...)` for a
# character keypress, and `((kind . "<name>"))` (no other keys) for every
# other kind -- see the per-kind list in each `when` branch below. Unlike
# tui.cr's own tui_key_event_alist (which always includes every field with
# #f defaults, string keys, and a Crystal-enum-derived name), this uses
# symbol keys (matching the `runtime` alist convention in introspection.cr)
# and only ever has a `char` entry for the "char" kind -- there's no
# row/col/text payload any of these kinds need.
# ===========================================================================

module Creme::Builtins::Term
  extend self
  include Creme::BuiltinHelpers

  # How long #read_byte_timeout waits for a follow-up byte after a bare
  # `\e`, to tell a real Esc keypress apart from the start of a longer
  # escape sequence (arrow keys, Home/End, Delete) -- same value and same
  # purpose as TUI::Keys::ESC_TIMEOUT.
  ESC_TIMEOUT = 50.milliseconds

  @[Creme::SchemeFn("term-raw-mode-enter!", min: 0, max: 0)]
  def term_raw_mode_enter(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system("stty -echo -icanon -isig min 1 time 0 2>/dev/null")
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("term-raw-mode-exit!", min: 0, max: 0)]
  def term_raw_mode_exit(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system("stty echo icanon isig 2>/dev/null")
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("term-read-key", min: 0, max: 0)]
  def term_read_key(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    read_key_event
  end

  # Relative cursor movement: positive `rows` moves down, negative up;
  # positive `cols` moves right, negative left; 0 on either axis means no
  # movement on that axis. Uses the ANSI relative-movement sequences
  # ("\e[{n}A/B/C/D") rather than Term.move's absolute "\e[{row};{col}H" --
  # a REPL only ever needs to nudge the cursor around its current input
  # line, never to reposition to an absolute screen coordinate.
  @[Creme::SchemeFn("term-move-cursor!", min: 2, max: 2)]
  def term_move_cursor(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    rows = int_arg(args[0], "term-move-cursor!").to_i32
    cols = int_arg(args[1], "term-move-cursor!").to_i32
    STDOUT << "\e[#{rows.abs}#{rows > 0 ? "B" : "A"}" unless rows == 0
    STDOUT << "\e[#{cols.abs}#{cols > 0 ? "C" : "D"}" unless cols == 0
    STDOUT.flush
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("term-clear-to-eol!", min: 0, max: 0)]
  def term_clear_to_eol(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    STDOUT << "\e[K"
    STDOUT.flush
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("term-write!", min: 1, max: 1)]
  def term_write(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    s = string_arg(args[0], "term-write!")
    STDOUT << s
    STDOUT.flush
    NIL.as(SchemeValue)
  end

  # Whether STDOUT is attached to an actual terminal (as opposed to a pipe
  # or a redirected file) -- so a script (e.g. (creme spec)'s runner) can
  # decide whether ANSI color codes would help or would just corrupt piped/
  # redirected output with escape sequences. No args: always asks about
  # this process's own STDOUT specifically, not an arbitrary port -- there's
  # no general notion of "the underlying fd" for a Scheme string/output
  # port here, so this deliberately isn't `port-tty?` taking a port arg.
  @[Creme::SchemeFn("stdout-tty?", min: 0, max: 0)]
  def stdout_tty_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(STDOUT.tty?)
  end

  # Whether STDIN is attached to an actual terminal -- the input-side
  # sibling of stdout-tty? above, for the same reason (e.g. a raw-mode
  # REPL deciding whether it's safe to flip stdin into cbreak mode at all,
  # as opposed to reading from a pipe/redirected file where `stty` would
  # be a no-op or outright wrong to attempt).
  @[Creme::SchemeFn("stdin-tty?", min: 0, max: 0)]
  def stdin_tty_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(STDIN.tty?)
  end

  # ---- Key reading (adapted from lib/tui/src/tui/core/keys.cr, trimmed to
  # only the kinds a plain REPL needs -- no mouse/paste/PageUp-Down; word-nav
  # (Ctrl-A/Ctrl-E/word-left/word-right) WAS trimmed too but is back, ported
  # from the same source, since (creme repl) now wants it) ----
  #
  # `io` defaults to STDIN (the only thing term-read-key itself ever passes)
  # but is threaded through every method here, mirroring TUI::Keys.read(io),
  # so a spec can drive this with a real IO::FileDescriptor (an IO.pipe, per
  # #read_byte_timeout's own comment) instead of the real terminal.

  # ameba:disable Metrics/CyclomaticComplexity
  def read_key_event(io : IO = STDIN) : SchemeValue
    byte = io.read_byte
    return kind_alist("eof") if byte.nil?

    ch = byte.chr
    case ch
    when '\r', '\n'     then kind_alist("enter")
    when 0x7f.chr, '\b' then kind_alist("backspace")
    when 0x09.chr       then kind_alist("tab")
    when 0x01.chr       then kind_alist("ctrl-a")
    when 0x03.chr       then kind_alist("ctrl-c")
    when 0x04.chr       then kind_alist("ctrl-d")
    when 0x05.chr       then kind_alist("ctrl-e")
    when '\e'           then parse_escape(io)
    else
      if byte >= 32
        char_alist(ch)
      else
        kind_alist("unknown")
      end
    end
  end

  # Only an IO::FileDescriptor (the real terminal, or a real IO.pipe in
  # specs) supports #read_timeout= -- a plain IO::Memory would raise, so
  # this degrades to "no follow-up byte available" for one instead, exactly
  # like TUI::Keys.read_byte_timeout's own io.as?(IO::FileDescriptor) guard.
  private def read_byte_timeout(io : IO) : UInt8?
    return io.read_byte unless io.is_a?(IO::FileDescriptor)
    old = io.read_timeout
    io.read_timeout = ESC_TIMEOUT
    begin
      io.read_byte
    rescue IO::TimeoutError
      nil
    ensure
      io.read_timeout = old
    end
  end

  # Alt-Left/Alt-Right: some terminal configs ("use Option as Meta key") send
  # a bare-ESC + letter form ('b'/'f' below) instead of the CSI form #csi_key
  # handles -- readline's own Alt-B/Alt-F bindings use the same letters for
  # the same word-nav meaning.
  private def parse_escape(io : IO) : SchemeValue
    next_byte = read_byte_timeout(io)
    return kind_alist("escape") if next_byte.nil?

    case next_byte.chr
    when '[' then parse_csi(io)
    when 'O' then parse_ss3(io)
    when 'b' then kind_alist("word-left")
    when 'f' then kind_alist("word-right")
    else          kind_alist("escape")
    end
  end

  private def parse_ss3(io : IO) : SchemeValue
    next_byte = read_byte_timeout(io)
    return kind_alist("escape") if next_byte.nil?

    case next_byte.chr
    when 'A' then kind_alist("up")
    when 'B' then kind_alist("down")
    when 'C' then kind_alist("right")
    when 'D' then kind_alist("left")
    when 'H' then kind_alist("home")
    when 'F' then kind_alist("end")
    else          kind_alist("unknown")
    end
  end

  private def parse_csi(io : IO) : SchemeValue
    first = read_byte_timeout(io)
    return kind_alist("unknown") if first.nil?

    seq = read_csi_seq(io, first.chr)
    csi_key(seq)
  end

  # See TUI::Keys#read_csi_seq's own comment: a single-letter CSI sequence
  # (arrows, Home/End) is already complete after `first` -- reading further
  # would swallow the next keypress's bytes hunting for a terminator that
  # already arrived.
  private def read_csi_seq(io : IO, first : Char) : String
    seq = String::Builder.new
    seq << first
    return seq.to_s if first >= '@' && first <= '~'
    7.times do
      b = read_byte_timeout(io)
      break if b.nil?
      c = b.chr
      seq << c
      break if c >= '@' && c <= '~'
    end
    seq.to_s
  end

  private def csi_key(seq : String) : SchemeValue
    case seq
    when "A"            then kind_alist("up")
    when "B"            then kind_alist("down")
    when "C"            then kind_alist("right")
    when "D"            then kind_alist("left")
    when "H"            then kind_alist("home")
    when "F"            then kind_alist("end")
    when "3~"           then kind_alist("delete")
    when "1;3C", "1;5C" then kind_alist("word-right") # Alt/Ctrl+Right
    when "1;3D", "1;5D" then kind_alist("word-left")  # Alt/Ctrl+Left
    else                     kind_alist("unknown")
    end
  end

  private def kind_alist(kind : String) : SchemeValue
    Creme.a_to_list([
      Cons.new(SchemeSym.of("kind"), SchemeStr.new(kind)).as(SchemeValue),
    ])
  end

  private def char_alist(ch : Char) : SchemeValue
    Creme.a_to_list([
      Cons.new(SchemeSym.of("kind"), SchemeStr.new("char")).as(SchemeValue),
      Cons.new(SchemeSym.of("char"), SchemeChar.new(ch)).as(SchemeValue),
    ])
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "term"], Creme::Builtins::Term
  end
end
