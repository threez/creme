# ===========================================================================
# tui module: terminal UI primitives, bound against the tui.cr shard
# (https://github.com/threez/tui.cr), scoped to exactly what a small
# self-hosted "try Lisp" REPL/IDE needs to run inside crisp itself:
#
#   - color/style construction and a raw buffer for custom-drawn content
#   - tui:make-scrollable, a Lisp-defined TUI::Scrollable (used for the
#     lessons+output log pane) driven entirely by Lisp closures via
#     Interpreter#apply
#   - tui:text-edit, wrapping TUI::TextEdit (the input pane)
#   - tui:window / tui:vstack, laying out one or two panes full-screen
#   - tui:run, the blocking render/read-key/dispatch loop
#
# Deliberately NOT built: TUI::ListView/TableView/DetailView, Form::Host,
# Grid, MarkdownView, Popup, Picker/DropdownPicker, SplitWindow/HSplit —
# none of these are needed for a single input+output IDE, so they were
# left out rather than spoken-for with a "later" comment.
#
# This is the first module that calls Lisp closures from Crystal event
# handlers (via the public Interpreter#apply). That's safe here because
# tui.cr's Runtime#read_dispatch_loop is fully synchronous/single-threaded
# — no Fibers/spawn are introduced, so there's no reentrancy hazard with
# the interpreter's own @eval_depth/@step_count state.
# ===========================================================================

require "tui"

module LISP
  # ---- Foreign value wrappers ----------------------------------------------

  class LispTuiColor < LispValue
    getter value : TUI::Color

    def initialize(@value : TUI::Color)
    end

    def to_display(io : IO) : Nil
      io << "#<tui-color>"
    end
  end

  class LispTuiStyle < LispValue
    getter value : TUI::Style

    def initialize(@value : TUI::Style)
    end

    def to_display(io : IO) : Nil
      io << "#<tui-style>"
    end
  end

  class LispTuiScreen < LispValue
    getter value : TUI::Screen

    def initialize(@value : TUI::Screen)
    end

    def to_display(io : IO) : Nil
      io << "#<tui-screen>"
    end
  end

  class LispTuiBuffer < LispValue
    getter value : TUI::Buffer

    def initialize(@value : TUI::Buffer)
    end

    def to_display(io : IO) : Nil
      io << "#<tui-buffer>"
    end
  end

  # Wraps anything implementing TUI::Scrollable — either a native
  # TUI::TextEdit or a LispScrollableAdapter backing a Lisp-defined pane.
  class LispTuiScrollable < LispValue
    getter value : TUI::Scrollable

    def initialize(@value : TUI::Scrollable)
    end

    def to_display(io : IO) : Nil
      io << "#<tui-scrollable>"
    end
  end

  # Wraps any TUI::Widget — a Window or a LispVStack.
  class LispTuiWidget < LispValue
    getter value : TUI::Widget

    def initialize(@value : TUI::Widget)
    end

    def to_display(io : IO) : Nil
      io << "#<tui-widget>"
    end
  end

  # A TUI::Scrollable entirely driven by Lisp closures, via
  # Interpreter#apply — the general adapter that lets Lisp code define a
  # pane's content/behavior (used for the lessons+output log pane).
  # handle_click is intentionally not wired to Lisp: this module is
  # keyboard-driven only, mouse clicks are always left unconsumed.
  class LispScrollableAdapter
    include TUI::Scrollable

    def initialize(@interp : Interpreter, @title_fn : LispValue, @content_size_fn : LispValue,
                   @render_content_fn : LispValue, @handle_key_fn : LispValue, @status_hint_fn : LispValue)
    end

    def title : String
      LISP.tui_lisp_str(@interp.apply(@title_fn, [] of LispValue), "tui:make-scrollable title-fn")
    end

    def content_size : Int32
      v = @interp.apply(@content_size_fn, [] of LispValue)
      v.is_a?(LispInt) ? v.value.to_i32 : 0
    end

    def render_content(buffer : TUI::Buffer, scroll : TUI::ScrollControl) : Nil
      @interp.apply(@render_content_fn, [LispTuiBuffer.new(buffer).as(LispValue)])
      nil
    end

    def handle_key(ev : TUI::KeyEvent, scroll : TUI::ScrollControl) : Bool
      LISP.truthy?(@interp.apply(@handle_key_fn, [LISP.tui_key_event_alist(ev).as(LispValue)]))
    end

    def handle_click(local_row : Int32, local_col : Int32, scroll : TUI::ScrollControl) : Bool
      false
    end

    def status_hint : String
      LISP.tui_lisp_str(@interp.apply(@status_hint_fn, [] of LispValue), "tui:make-scrollable status-hint-fn")
    end
  end

  # A vertical split of two Scrollables, each hosted in its own full-width
  # Window: a `bottom_height`-row pane pinned to the bottom (the input
  # pane) and everything above it (the lessons+log pane). Mirrors
  # TUI::HSplit's own "two Widgets, Tab toggles which is active" shape,
  # just stacked vertically with a fixed bottom height instead of split
  # side by side.
  class LispVStack < TUI::Widget
    def initialize(@screen : TUI::Screen, @top : TUI::Scrollable, @bottom : TUI::Scrollable,
                   @bottom_height : Int32, @bordered : Bool)
      super(1, 1, @screen.cols, @screen.rows - 1)
      @active = :bottom
      @top_window = uninitialized TUI::Window
      @bottom_window = uninitialized TUI::Window
      build_windows
    end

    # Rebuilds the bottom pane around a new Scrollable, keeping current
    # geometry — used to load a lesson's example code into a fresh
    # TUI::TextEdit (TextEdit itself exposes no way to replace its text
    # after construction).
    def replace_bottom(scrollable : TUI::Scrollable) : Nil
      @bottom = scrollable
      build_windows
    end

    def composite(screen : TUI::Screen) : Nil
      layout
      @top.focus_if(@active == :top)
      @bottom.focus_if(@active == :bottom)
      @top_window.composite(screen)
      @bottom_window.composite(screen)
    end

    def render : Nil
    end

    def handle_key(ev : TUI::KeyEvent) : Bool
      if ev.key == TUI::Key::Tab
        @active = @active == :top ? :bottom : :top
        return true
      end
      active_window.handle_key(ev)
    end

    def status_hint : String
      "Tab:switch pane  " + active_window.status_hint
    end

    private def active_window : TUI::Window
      @active == :top ? @top_window : @bottom_window
    end

    private def build_windows : Nil
      top_h = [height - @bottom_height, 0].max
      @top_window = TUI::Window.new(x, y, width, top_h, @top, @bordered)
      @bottom_window = TUI::Window.new(x, y + top_h, width, @bottom_height, @bottom, @bordered)
    end

    private def layout : Nil
      top_h = [height - @bottom_height, 0].max
      @top_window.x = x
      @top_window.y = y
      @top_window.width = width
      @top_window.height = top_h
      @bottom_window.x = x
      @bottom_window.y = y + top_h
      @bottom_window.width = width
      @bottom_window.height = @bottom_height
    end
  end

  # ---- Free-function helpers (used both from install_tui and from the
  # Crystal-side adapters above, which aren't Interpreter methods) ----------

  def self.tui_lisp_str(v : LispValue, who : String) : String
    raise LispRuntimeError.new("#{who}: expected a string return value, got #{v.write_string}") unless v.is_a?(LispStr)
    v.value
  end

  def self.tui_key_event_alist(ev : TUI::KeyEvent) : LispValue
    key_name = ev.key.to_s.underscore
    char : LispValue = ev.key == TUI::Key::Char ? LispChar.new(ev.char) : FALSE
    row : LispValue = (r = ev.row) ? LispInt.new(r.to_i64) : FALSE
    col : LispValue = (c = ev.col) ? LispInt.new(c.to_i64) : FALSE
    text : LispValue = (t = ev.text) ? LispStr.new(t) : FALSE
    LISP.a_to_list([
      Cons.new(LispStr.new("key"), LispStr.new(key_name)).as(LispValue),
      Cons.new(LispStr.new("char"), char).as(LispValue),
      Cons.new(LispStr.new("row"), row).as(LispValue),
      Cons.new(LispStr.new("col"), col).as(LispValue),
      Cons.new(LispStr.new("text"), text).as(LispValue),
    ])
  end

  # Inverse of .tui_key_event_alist — reconstructs a TUI::KeyEvent from the
  # alist a handle-key-fn/on-key-fn closure receives, so app code can
  # forward the same event it was given into a widget's own #handle_key
  # (see tui:handle-key!). Only "key" is required; the rest default to
  # KeyEvent's own defaults (no char/row/col/text) if absent or the wrong
  # shape, since an app rebuilding an event by hand (rather than just
  # forwarding one it received) may not bother setting every field.
  def self.tui_key_event_from_alist(v : LispValue, who : String) : TUI::KeyEvent
    fields = {} of String => LispValue
    LISP.list_to_a(v).each do |pair|
      raise LispRuntimeError.new("#{who}: malformed key event alist") unless pair.is_a?(Cons)
      key = pair.car
      raise LispRuntimeError.new("#{who}: expected string keys in key event alist") unless key.is_a?(LispStr)
      fields[key.value] = pair.cdr
    end
    key_str = fields["key"]?
    raise LispRuntimeError.new("#{who}: key event alist missing \"key\"") unless key_str.is_a?(LispStr)
    key = tui_key_from_name(key_str.value, who)
    char_v = fields["char"]?
    char = char_v.is_a?(LispChar) ? char_v.value : '\0'
    row_v = fields["row"]?
    row = row_v.is_a?(LispInt) ? row_v.value.to_i32 : nil
    col_v = fields["col"]?
    col = col_v.is_a?(LispInt) ? col_v.value.to_i32 : nil
    text_v = fields["text"]?
    text = text_v.is_a?(LispStr) ? text_v.value : nil
    TUI::KeyEvent.new(key, char, row, col, text)
  end

  # Every TUI::Key member's underscore form (e.g. "shift_tab" -> ShiftTab,
  # "ctrl_c" -> CtrlC) round-trips through String#camelcase, so a lookup
  # is just the inverse of the .underscore call .tui_key_event_alist uses
  # to build the name in the first place — no parallel case/table to keep
  # in sync with TUI::Key's member list.
  private def self.tui_key_from_name(name : String, who : String) : TUI::Key
    TUI::Key.parse?(name.camelcase) || raise LispRuntimeError.new("#{who}: unknown key name '#{name}'")
  end

  class Interpreter
    private def install_tui(env : Env) : Nil
      reg = ->(name : String, mn : Int32, mx : Int32, fn : Array(LispValue) -> LispValue) do
        env.define(name, Builtin.new(name, mn, mx, &fn))
      end

      # ---- Colors & styles ----
      reg.call("color-named", 1, 1, ->(args : Array(LispValue)) : LispValue do
        name = tui_sym_arg(args[0], "tui:color-named")
        LispTuiColor.new(TUI.color(name))
      end)

      reg.call("color-index", 1, 1, ->(args : Array(LispValue)) : LispValue do
        idx = int_arg(args[0], "tui:color-index").to_i32
        begin
          LispTuiColor.new(TUI.color(idx))
        rescue ex : ArgumentError
          raise LispRuntimeError.new("tui:color-index: #{ex.message}")
        end
      end)

      reg.call("color-rgb", 3, 3, ->(args : Array(LispValue)) : LispValue do
        r = int_arg(args[0], "tui:color-rgb").to_i32
        g = int_arg(args[1], "tui:color-rgb").to_i32
        b = int_arg(args[2], "tui:color-rgb").to_i32
        begin
          LispTuiColor.new(TUI.color(r, g, b))
        rescue ex : ArgumentError
          raise LispRuntimeError.new("tui:color-rgb: #{ex.message}")
        end
      end)

      reg.call("color-gray", 1, 1, ->(args : Array(LispValue)) : LispValue do
        n = int_arg(args[0], "tui:color-gray").to_i32
        begin
          LispTuiColor.new(TUI.color(gray: n))
        rescue ex : ArgumentError
          raise LispRuntimeError.new("tui:color-gray: #{ex.message}")
        end
      end)

      reg.call("style", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispTuiStyle.new(tui_style_from_alist(args[0]))
      end)

      # ---- Screen & buffer ----
      reg.call("screen", 0, 0, ->(_args : Array(LispValue)) : LispValue do
        LispTuiScreen.new(TUI::Screen.new)
      end)

      reg.call("buffer-set!", 4, 5, ->(args : Array(LispValue)) : LispValue do
        buffer = tui_buffer_arg(args[0], "tui:buffer-set!")
        row = int_arg(args[1], "tui:buffer-set!").to_i32
        col = int_arg(args[2], "tui:buffer-set!").to_i32
        text = tui_str_arg(args[3], "tui:buffer-set!")
        style = args.size > 4 ? tui_style_arg(args[4], "tui:buffer-set!") : nil
        s = style ? TUI::Term.apply(style, text) : text
        buffer.set(row, col, s)
        NIL.as(LispValue)
      end)

      reg.call("buffer-clear!", 1, 1, ->(args : Array(LispValue)) : LispValue do
        tui_buffer_arg(args[0], "tui:buffer-clear!").clear
        NIL.as(LispValue)
      end)

      reg.call("buffer-box!", 5, 6, ->(args : Array(LispValue)) : LispValue do
        buffer = tui_buffer_arg(args[0], "tui:buffer-box!")
        row = int_arg(args[1], "tui:buffer-box!").to_i32
        col = int_arg(args[2], "tui:buffer-box!").to_i32
        height = int_arg(args[3], "tui:buffer-box!").to_i32
        width = int_arg(args[4], "tui:buffer-box!").to_i32
        title = args.size > 5 ? tui_str_arg(args[5], "tui:buffer-box!") : ""
        buffer.box(row, col, height, width, title)
        NIL.as(LispValue)
      end)

      # ---- Panes ----
      reg.call("text-edit", 0, 1, ->(args : Array(LispValue)) : LispValue do
        text = args.size > 0 ? tui_str_arg(args[0], "tui:text-edit") : ""
        LispTuiScrollable.new(TUI::TextEdit.new(text))
      end)

      reg.call("text-edit-value", 1, 1, ->(args : Array(LispValue)) : LispValue do
        LispStr.new(tui_text_edit_arg(args[0], "tui:text-edit-value").value)
      end)

      # Wires a Lisp `fn : line-string -> list of (text . style-or-#f)
      # pairs` into TextEdit's own `highlighter : (String -> Array(Cell))?`
      # hook (src/tui/widgets/text_edit.cr) — called once per logical line
      # per render. Per that hook's contract, the returned cells'
      # concatenated text MUST equal the input line exactly; TextEdit
      # itself silently falls back to plain rendering for any line where
      # that's violated, rather than corrupting cursor/click columns.
      reg.call("text-edit-set-highlighter!", 2, 2, ->(args : Array(LispValue)) : LispValue do
        text_edit = tui_text_edit_arg(args[0], "tui:text-edit-set-highlighter!")
        fn = tui_fn_arg(args[1], "tui:text-edit-set-highlighter!")
        text_edit.highlighter = ->(line : String) do
          tui_cells_from_lisp(apply(fn, [LispStr.new(line).as(LispValue)]), "tui:text-edit-set-highlighter! highlighter-fn")
        end
        NIL.as(LispValue)
      end)

      reg.call("make-scrollable", 5, 5, ->(args : Array(LispValue)) : LispValue do
        title_fn = tui_fn_arg(args[0], "tui:make-scrollable")
        content_size_fn = tui_fn_arg(args[1], "tui:make-scrollable")
        render_content_fn = tui_fn_arg(args[2], "tui:make-scrollable")
        handle_key_fn = tui_fn_arg(args[3], "tui:make-scrollable")
        status_hint_fn = tui_fn_arg(args[4], "tui:make-scrollable")
        LispTuiScrollable.new(LispScrollableAdapter.new(self, title_fn, content_size_fn, render_content_fn, handle_key_fn, status_hint_fn))
      end)

      # ---- Layout ----
      reg.call("window", 2, 3, ->(args : Array(LispValue)) : LispValue do
        screen = tui_screen_arg(args[0], "tui:window")
        content = tui_scrollable_arg(args[1], "tui:window")
        bordered = args.size > 2 ? LISP.truthy?(args[2]) : true
        LispTuiWidget.new(TUI::Window.full_screen(screen, content, bordered))
      end)

      reg.call("vstack", 4, 5, ->(args : Array(LispValue)) : LispValue do
        screen = tui_screen_arg(args[0], "tui:vstack")
        top = tui_scrollable_arg(args[1], "tui:vstack")
        bottom = tui_scrollable_arg(args[2], "tui:vstack")
        bottom_height = int_arg(args[3], "tui:vstack").to_i32
        bordered = args.size > 4 ? LISP.truthy?(args[4]) : true
        LispTuiWidget.new(LispVStack.new(screen, top, bottom, bottom_height, bordered))
      end)

      reg.call("vstack-set-bottom!", 2, 2, ->(args : Array(LispValue)) : LispValue do
        vstack = tui_vstack_arg(args[0], "tui:vstack-set-bottom!")
        bottom = tui_scrollable_arg(args[1], "tui:vstack-set-bottom!")
        vstack.replace_bottom(bottom)
        NIL.as(LispValue)
      end)

      # Forwards a key-event alist (as received by an on-key-fn/
      # handle-key-fn) into a widget's own #handle_key — the piece that
      # lets tui:run's on-key-fn actually drive tui:vstack's Tab-toggle
      # and active-pane dispatch, since Runtime itself never calls
      # #handle_key automatically (see tui:run below).
      reg.call("handle-key!", 2, 2, ->(args : Array(LispValue)) : LispValue do
        widget = tui_widget_arg(args[0], "tui:handle-key!")
        ev = LISP.tui_key_event_from_alist(args[1], "tui:handle-key!")
        LispBool.of(widget.handle_key(ev))
      end)

      # ---- Run loop ----
      reg.call("run", 3, 3, ->(args : Array(LispValue)) : LispValue do
        screen = tui_screen_arg(args[0], "tui:run")
        root = tui_widget_arg(args[1], "tui:run")
        on_key_fn = tui_fn_arg(args[2], "tui:run")
        nav = TUI::NavStack(TUI::Widget).new(root)
        runtime = TUI::Runtime.new(screen, nav, ->(ev : TUI::KeyEvent) do
          apply(on_key_fn, [LISP.tui_key_event_alist(ev)])
          nil
        end)
        runtime.run
        NIL.as(LispValue)
      end)
    end

    # ---- Argument helpers ----

    private def tui_str_arg(v : LispValue, who : String) : String
      raise LispRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(LispStr)
      v.value
    end

    private def tui_sym_arg(v : LispValue, who : String) : Symbol
      raise LispRuntimeError.new("#{who}: expected symbol, got #{v.write_string}") unless v.is_a?(LispSym)
      case v.name
      when "red"     then :red
      when "green"   then :green
      when "yellow"  then :yellow
      when "blue"    then :blue
      when "magenta" then :magenta
      when "cyan"    then :cyan
      when "white"   then :white
      when "gray"    then :gray
      else
        raise LispRuntimeError.new("#{who}: unknown color name '#{v.name}'")
      end
    end

    private def tui_fn_arg(v : LispValue, who : String) : LispValue
      raise LispRuntimeError.new("#{who}: expected a procedure, got #{v.write_string}") unless v.is_a?(Lambda) || v.is_a?(Builtin)
      v
    end

    private def tui_color_arg(v : LispValue, who : String) : TUI::Color
      raise LispRuntimeError.new("#{who}: expected a tui color, got #{v.write_string}") unless v.is_a?(LispTuiColor)
      v.value
    end

    private def tui_style_arg(v : LispValue, who : String) : TUI::Style
      raise LispRuntimeError.new("#{who}: expected a tui style, got #{v.write_string}") unless v.is_a?(LispTuiStyle)
      v.value
    end

    private def tui_screen_arg(v : LispValue, who : String) : TUI::Screen
      raise LispRuntimeError.new("#{who}: expected a tui screen, got #{v.write_string}") unless v.is_a?(LispTuiScreen)
      v.value
    end

    private def tui_buffer_arg(v : LispValue, who : String) : TUI::Buffer
      raise LispRuntimeError.new("#{who}: expected a tui buffer, got #{v.write_string}") unless v.is_a?(LispTuiBuffer)
      v.value
    end

    private def tui_scrollable_arg(v : LispValue, who : String) : TUI::Scrollable
      raise LispRuntimeError.new("#{who}: expected a tui scrollable pane, got #{v.write_string}") unless v.is_a?(LispTuiScrollable)
      v.value
    end

    private def tui_widget_arg(v : LispValue, who : String) : TUI::Widget
      raise LispRuntimeError.new("#{who}: expected a tui widget, got #{v.write_string}") unless v.is_a?(LispTuiWidget)
      v.value
    end

    private def tui_vstack_arg(v : LispValue, who : String) : LispVStack
      widget = tui_widget_arg(v, who)
      raise LispRuntimeError.new("#{who}: expected a tui:vstack widget") unless widget.is_a?(LispVStack)
      widget
    end

    private def tui_text_edit_arg(v : LispValue, who : String) : TUI::TextEdit
      scrollable = tui_scrollable_arg(v, who)
      raise LispRuntimeError.new("#{who}: expected a tui:text-edit pane") unless scrollable.is_a?(TUI::TextEdit)
      scrollable
    end

    # A highlighter-fn's return value: a list of (text . style-or-#f)
    # pairs, matching the alist-of-pairs convention used elsewhere in this
    # module — #f means "no style" (TUI::Style.new's own default).
    private def tui_cells_from_lisp(v : LispValue, who : String) : Array(TUI::Cell)
      LISP.list_to_a(v).map do |pair|
        raise LispRuntimeError.new("#{who}: expected a list of (text . style) pairs") unless pair.is_a?(Cons)
        text = pair.car
        raise LispRuntimeError.new("#{who}: expected string cell text") unless text.is_a?(LispStr)
        style_v = pair.cdr
        style = style_v.is_a?(LispTuiStyle) ? style_v.value : TUI::Style.new
        TUI::Cell.new(text.value, style)
      end
    end

    # Alist of ("bold"|"dim"|"italic"|"underline"|"strikethrough"|"blink"|
    # "reverse" . #t/#f) and ("fg"|"bg" . tui-color) pairs, matching the
    # alist convention this codebase uses for object-shaped data.
    private def tui_style_from_alist(v : LispValue) : TUI::Style
      bold = false
      dim = false
      italic = false
      underline = false
      strikethrough = false
      blink = false
      reverse = false
      fg : TUI::Color? = nil
      bg : TUI::Color? = nil

      LISP.list_to_a(v).each do |pair|
        raise LispRuntimeError.new("tui:style: expected an alist of (key . value) pairs") unless pair.is_a?(Cons)
        key = pair.car
        raise LispRuntimeError.new("tui:style: expected a string key") unless key.is_a?(LispStr)
        value = pair.cdr
        case key.value
        when "bold"          then bold = LISP.truthy?(value)
        when "dim"           then dim = LISP.truthy?(value)
        when "italic"        then italic = LISP.truthy?(value)
        when "underline"     then underline = LISP.truthy?(value)
        when "strikethrough" then strikethrough = LISP.truthy?(value)
        when "blink"         then blink = LISP.truthy?(value)
        when "reverse"       then reverse = LISP.truthy?(value)
        when "fg"            then fg = tui_color_arg(value, "tui:style")
        when "bg"            then bg = tui_color_arg(value, "tui:style")
        else
          raise LispRuntimeError.new("tui:style: unknown style key '#{key.value}'")
        end
      end

      TUI::Style.new(bold: bold, dim: dim, italic: italic, underline: underline,
        strikethrough: strikethrough, blink: blink, reverse: reverse, fg: fg, bg: bg)
    end
  end
end
