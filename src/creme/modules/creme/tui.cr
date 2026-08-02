# ===========================================================================
# tui module: terminal UI primitives, bound against the tui.cr shard
# (https://github.com/threez/tui.cr), scoped to exactly what a small
# self-hosted "try Scheme" REPL/IDE needs to run inside creme itself:
#
#   - color/style construction and a raw buffer for custom-drawn content
#   - tui-make-scrollable, a Scheme-defined TUI::Scrollable (used for the
#     lessons+output log pane) driven entirely by Scheme closures via
#     Interpreter#apply
#   - tui-text-edit, wrapping TUI::TextEdit (the input pane)
#   - tui-window / tui-vstack, laying out one or two panes full-screen
#   - tui-run, the blocking render/read-key/dispatch loop
#
# Deliberately NOT built: TUI::ListView/TableView/DetailView, Form::Host,
# Grid, MarkdownView, Popup, Picker/DropdownPicker, SplitWindow/HSplit —
# none of these are needed for a single input+output IDE, so they were
# left out rather than spoken-for with a "later" comment.
#
# This is the first module that calls Scheme closures from Crystal event
# handlers (via the public Interpreter#apply). That's safe here because
# tui.cr's Runtime#read_dispatch_loop is fully synchronous/single-threaded
# — no Fibers/spawn are introduced, so there's no reentrancy hazard with
# the interpreter's own @eval_depth/@step_count state.
# ===========================================================================

require "tui"

module Creme
  # ---- Foreign value wrappers ----------------------------------------------
  # TUI handles (color/style/screen/buffer/scrollable/widget) are opaque
  # foreign values, wrapped in the shared SchemeBox under a "tui-<kind>" tag
  # rather than each getting its own SchemeValue class — see value/box.cr and
  # the tui_*_arg helpers below that unbox them.

  # A TUI::Scrollable entirely driven by Scheme closures, via
  # Interpreter#apply — the general adapter that lets Scheme code define a
  # pane's content/behavior (used for the lessons+output log pane).
  # handle_click is intentionally not wired to Scheme: this module is
  # keyboard-driven only, mouse clicks are always left unconsumed.
  class SchemeScrollableAdapter
    include TUI::Scrollable

    def initialize(@interp : Interpreter, @title_fn : SchemeValue, @content_size_fn : SchemeValue,
                   @render_content_fn : SchemeValue, @handle_key_fn : SchemeValue, @status_hint_fn : SchemeValue)
    end

    def title : String
      Creme.tui_lisp_str(@interp.apply(@title_fn, [] of SchemeValue), "tui-make-scrollable title-fn")
    end

    def content_size : Int32
      v = @interp.apply(@content_size_fn, [] of SchemeValue)
      v.is_a?(SchemeInt) ? v.value.to_i32 : 0
    end

    def render_content(buffer : TUI::Buffer, scroll : TUI::ScrollControl) : Nil
      @interp.apply(@render_content_fn, [SchemeBox.new("tui-buffer", buffer, "#<tui-buffer>").as(SchemeValue)])
      nil
    end

    def handle_key(ev : TUI::KeyEvent, scroll : TUI::ScrollControl) : Bool
      Creme.truthy?(@interp.apply(@handle_key_fn, [Creme.tui_key_event_alist(ev).as(SchemeValue)]))
    end

    def handle_click(local_row : Int32, local_col : Int32, scroll : TUI::ScrollControl) : Bool
      false
    end

    def status_hint : String
      Creme.tui_lisp_str(@interp.apply(@status_hint_fn, [] of SchemeValue), "tui-make-scrollable status-hint-fn")
    end
  end

  # A vertical split of two Scrollables, each hosted in its own full-width
  # Window: a `bottom_height`-row pane pinned to the bottom (the input
  # pane) and everything above it (the lessons+log pane). Mirrors
  # TUI::HSplit's own "two Widgets, Tab toggles which is active" shape,
  # just stacked vertically with a fixed bottom height instead of split
  # side by side.
  class SchemeVStack < TUI::Widget
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

  # ---- Free-function helpers (used both from Creme::Builtins::Tui and
  # from the Crystal-side adapters above, which aren't Interpreter methods)

  def self.tui_lisp_str(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected a string return value, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end

  def self.tui_key_event_alist(ev : TUI::KeyEvent) : SchemeValue
    key_name = ev.key.to_s.underscore
    char : SchemeValue = ev.key == TUI::Key::Char ? SchemeChar.new(ev.char) : FALSE
    row : SchemeValue = (r = ev.row) ? SchemeInt.new(r.to_i64) : FALSE
    col : SchemeValue = (c = ev.col) ? SchemeInt.new(c.to_i64) : FALSE
    text : SchemeValue = (t = ev.text) ? SchemeStr.new(t) : FALSE
    Creme.a_to_list([
      Cons.new(SchemeStr.new("key"), SchemeStr.new(key_name)).as(SchemeValue),
      Cons.new(SchemeStr.new("char"), char).as(SchemeValue),
      Cons.new(SchemeStr.new("row"), row).as(SchemeValue),
      Cons.new(SchemeStr.new("col"), col).as(SchemeValue),
      Cons.new(SchemeStr.new("text"), text).as(SchemeValue),
    ])
  end

  # Inverse of .tui_key_event_alist — reconstructs a TUI::KeyEvent from the
  # alist a handle-key-fn/on-key-fn closure receives, so app code can
  # forward the same event it was given into a widget's own #handle_key
  # (see tui-handle-key!). Only "key" is required; the rest default to
  # KeyEvent's own defaults (no char/row/col/text) if absent or the wrong
  # shape, since an app rebuilding an event by hand (rather than just
  # forwarding one it received) may not bother setting every field.
  def self.tui_key_event_from_alist(v : SchemeValue, who : String) : TUI::KeyEvent
    fields = {} of String => SchemeValue
    Creme.list_to_a(v).each do |pair|
      raise SchemeRuntimeError.new("#{who}: malformed key event alist") unless pair.is_a?(Cons)
      key = pair.car
      raise SchemeRuntimeError.new("#{who}: expected string keys in key event alist") unless key.is_a?(SchemeStr)
      fields[key.value] = pair.cdr
    end
    key_str = fields["key"]?
    raise SchemeRuntimeError.new("#{who}: key event alist missing \"key\"") unless key_str.is_a?(SchemeStr)
    key = tui_key_from_name(key_str.value, who)
    char_v = fields["char"]?
    char = char_v.is_a?(SchemeChar) ? char_v.value : '\0'
    row_v = fields["row"]?
    row = row_v.is_a?(SchemeInt) ? row_v.value.to_i32 : nil
    col_v = fields["col"]?
    col = col_v.is_a?(SchemeInt) ? col_v.value.to_i32 : nil
    text_v = fields["text"]?
    text = text_v.is_a?(SchemeStr) ? text_v.value : nil
    TUI::KeyEvent.new(key, char, row, col, text)
  end

  # Every TUI::Key member's underscore form (e.g. "shift_tab" -> ShiftTab,
  # "ctrl_c" -> CtrlC) round-trips through String#camelcase, so a lookup
  # is just the inverse of the .underscore call .tui_key_event_alist uses
  # to build the name in the first place — no parallel case/table to keep
  # in sync with TUI::Key's member list.
  private def self.tui_key_from_name(name : String, who : String) : TUI::Key
    TUI::Key.parse?(name.camelcase) || raise SchemeRuntimeError.new("#{who}: unknown key name '#{name}'")
  end
end

module Creme::Builtins::Tui
  extend self
  include Creme::BuiltinHelpers

  # ---- Colors & styles ----
  @[Creme::SchemeFn("tui-color-named", min: 1, max: 1)]
  def tui_color_named(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    name = tui_sym_arg(args[0], "tui-color-named")
    SchemeBox.new("tui-color", TUI.color(name), "#<tui-color>")
  end

  @[Creme::SchemeFn("tui-color-index", min: 1, max: 1)]
  def tui_color_index(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    idx = int_arg(args[0], "tui-color-index").to_i32
    SchemeBox.new("tui-color", TUI.color(idx), "#<tui-color>")
  rescue ex : ArgumentError
    raise SchemeRuntimeError.new("tui-color-index: #{ex.message}")
  end

  @[Creme::SchemeFn("tui-color-rgb", min: 3, max: 3)]
  def tui_color_rgb(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    r = int_arg(args[0], "tui-color-rgb").to_i32
    g = int_arg(args[1], "tui-color-rgb").to_i32
    b = int_arg(args[2], "tui-color-rgb").to_i32
    SchemeBox.new("tui-color", TUI.color(r, g, b), "#<tui-color>")
  rescue ex : ArgumentError
    raise SchemeRuntimeError.new("tui-color-rgb: #{ex.message}")
  end

  @[Creme::SchemeFn("tui-color-gray", min: 1, max: 1)]
  def tui_color_gray(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = int_arg(args[0], "tui-color-gray").to_i32
    SchemeBox.new("tui-color", TUI.color(gray: n), "#<tui-color>")
  rescue ex : ArgumentError
    raise SchemeRuntimeError.new("tui-color-gray: #{ex.message}")
  end

  @[Creme::SchemeFn("tui-style", min: 1, max: 1)]
  def tui_style(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBox.new("tui-style", tui_style_from_alist(args[0]), "#<tui-style>")
  end

  # ---- Screen & buffer ----
  @[Creme::SchemeFn("tui-screen", min: 0, max: 0)]
  def tui_screen(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBox.new("tui-screen", TUI::Screen.new, "#<tui-screen>")
  end

  @[Creme::SchemeFn("tui-buffer-set!", min: 4, max: 5)]
  def tui_buffer_set(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    buffer = tui_buffer_arg(args[0], "tui-buffer-set!")
    row = int_arg(args[1], "tui-buffer-set!").to_i32
    col = int_arg(args[2], "tui-buffer-set!").to_i32
    text = tui_str_arg(args[3], "tui-buffer-set!")
    style = args.size > 4 ? tui_style_arg(args[4], "tui-buffer-set!") : nil
    s = style ? TUI::Term.apply(style, text) : text
    buffer.set(row, col, s)
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("tui-buffer-clear!", min: 1, max: 1)]
  def tui_buffer_clear(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    tui_buffer_arg(args[0], "tui-buffer-clear!").clear
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("tui-buffer-box!", min: 5, max: 6)]
  def tui_buffer_box(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    buffer = tui_buffer_arg(args[0], "tui-buffer-box!")
    row = int_arg(args[1], "tui-buffer-box!").to_i32
    col = int_arg(args[2], "tui-buffer-box!").to_i32
    height = int_arg(args[3], "tui-buffer-box!").to_i32
    width = int_arg(args[4], "tui-buffer-box!").to_i32
    title = args.size > 5 ? tui_str_arg(args[5], "tui-buffer-box!") : ""
    buffer.box(row, col, height, width, title)
    NIL.as(SchemeValue)
  end

  # ---- Panes ----
  @[Creme::SchemeFn("tui-text-edit", min: 0, max: 1)]
  def tui_text_edit(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    text = args.size > 0 ? tui_str_arg(args[0], "tui-text-edit") : ""
    SchemeBox.new("tui-scrollable", (TUI::TextEdit.new(text)).as(TUI::Scrollable), "#<tui-scrollable>")
  end

  @[Creme::SchemeFn("tui-text-edit-value", min: 1, max: 1)]
  def tui_text_edit_value(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(tui_text_edit_arg(args[0], "tui-text-edit-value").value)
  end

  # Wires a Scheme `fn : line-string -> list of (text . style-or-#f)
  # pairs` into TextEdit's own `highlighter : (String -> Array(Cell))?`
  # hook (src/tui/widgets/text_edit.cr) — called once per logical line
  # per render. Per that hook's contract, the returned cells'
  # concatenated text MUST equal the input line exactly; TextEdit
  # itself silently falls back to plain rendering for any line where
  # that's violated, rather than corrupting cursor/click columns.
  @[Creme::SchemeFn("tui-text-edit-set-highlighter!", min: 2, max: 2)]
  def tui_text_edit_set_highlighter(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    text_edit = tui_text_edit_arg(args[0], "tui-text-edit-set-highlighter!")
    fn = tui_fn_arg(args[1], "tui-text-edit-set-highlighter!")
    text_edit.highlighter = ->(line : String) do
      tui_cells_from_scheme(interp.apply(fn, [SchemeStr.new(line).as(SchemeValue)]), "tui-text-edit-set-highlighter! highlighter-fn")
    end
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("tui-make-scrollable", min: 5, max: 5)]
  def tui_make_scrollable(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    title_fn = tui_fn_arg(args[0], "tui-make-scrollable")
    content_size_fn = tui_fn_arg(args[1], "tui-make-scrollable")
    render_content_fn = tui_fn_arg(args[2], "tui-make-scrollable")
    handle_key_fn = tui_fn_arg(args[3], "tui-make-scrollable")
    status_hint_fn = tui_fn_arg(args[4], "tui-make-scrollable")
    SchemeBox.new("tui-scrollable", (SchemeScrollableAdapter.new(interp, title_fn, content_size_fn, render_content_fn, handle_key_fn, status_hint_fn)).as(TUI::Scrollable), "#<tui-scrollable>")
  end

  # ---- Layout ----
  @[Creme::SchemeFn("tui-window", min: 2, max: 3)]
  def tui_window(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    screen = tui_screen_arg(args[0], "tui-window")
    content = tui_scrollable_arg(args[1], "tui-window")
    bordered = args.size > 2 ? Creme.truthy?(args[2]) : true
    SchemeBox.new("tui-widget", (TUI::Window.full_screen(screen, content, bordered)).as(TUI::Widget), "#<tui-widget>")
  end

  @[Creme::SchemeFn("tui-vstack", min: 4, max: 5)]
  def tui_vstack(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    screen = tui_screen_arg(args[0], "tui-vstack")
    top = tui_scrollable_arg(args[1], "tui-vstack")
    bottom = tui_scrollable_arg(args[2], "tui-vstack")
    bottom_height = int_arg(args[3], "tui-vstack").to_i32
    bordered = args.size > 4 ? Creme.truthy?(args[4]) : true
    SchemeBox.new("tui-widget", (SchemeVStack.new(screen, top, bottom, bottom_height, bordered)).as(TUI::Widget), "#<tui-widget>")
  end

  @[Creme::SchemeFn("tui-vstack-set-bottom!", min: 2, max: 2)]
  def tui_vstack_set_bottom(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    vstack = tui_vstack_arg(args[0], "tui-vstack-set-bottom!")
    bottom = tui_scrollable_arg(args[1], "tui-vstack-set-bottom!")
    vstack.replace_bottom(bottom)
    NIL.as(SchemeValue)
  end

  # Forwards a key-event alist (as received by an on-key-fn/
  # handle-key-fn) into a widget's own #handle_key — the piece that
  # lets tui-run's on-key-fn actually drive tui-vstack's Tab-toggle
  # and active-pane dispatch, since Runtime itself never calls
  # #handle_key automatically (see tui-run below).
  @[Creme::SchemeFn("tui-handle-key!", min: 2, max: 2)]
  def tui_handle_key(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    widget = tui_widget_arg(args[0], "tui-handle-key!")
    ev = Creme.tui_key_event_from_alist(args[1], "tui-handle-key!")
    SchemeBool.of(widget.handle_key(ev))
  end

  # ---- Run loop ----
  @[Creme::SchemeFn("tui-run", min: 3, max: 3)]
  def tui_run(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    screen = tui_screen_arg(args[0], "tui-run")
    root = tui_widget_arg(args[1], "tui-run")
    on_key_fn = tui_fn_arg(args[2], "tui-run")
    nav = TUI::NavStack(TUI::Widget).new(root)
    runtime = TUI::Runtime.new(screen, nav, ->(ev : TUI::KeyEvent) do
      interp.apply(on_key_fn, [Creme.tui_key_event_alist(ev).as(SchemeValue)])
      nil
    end)
    runtime.run
    NIL.as(SchemeValue)
  end

  # ---- Argument helpers ----

  private def tui_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end

  private def tui_sym_arg(v : SchemeValue, who : String) : Symbol
    raise SchemeRuntimeError.new("#{who}: expected symbol, got #{v.write_string}") unless v.is_a?(SchemeSym)
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
      raise SchemeRuntimeError.new("#{who}: unknown color name '#{v.name}'")
    end
  end

  private def tui_fn_arg(v : SchemeValue, who : String) : SchemeValue
    callable = v.is_a?(Builtin) || v.is_a?(BytecodeClosure) || v.is_a?(BytecodeCaseClosure)
    raise SchemeRuntimeError.new("#{who}: expected a procedure, got #{v.write_string}") unless callable
    v
  end

  private def tui_color_arg(v : SchemeValue, who : String) : TUI::Color
    raise SchemeRuntimeError.new("#{who}: expected a tui color, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "tui-color"
    v.get(TUI::Color)
  end

  private def tui_style_arg(v : SchemeValue, who : String) : TUI::Style
    raise SchemeRuntimeError.new("#{who}: expected a tui style, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "tui-style"
    v.get(TUI::Style)
  end

  private def tui_screen_arg(v : SchemeValue, who : String) : TUI::Screen
    raise SchemeRuntimeError.new("#{who}: expected a tui screen, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "tui-screen"
    v.get(TUI::Screen)
  end

  private def tui_buffer_arg(v : SchemeValue, who : String) : TUI::Buffer
    raise SchemeRuntimeError.new("#{who}: expected a tui buffer, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "tui-buffer"
    v.get(TUI::Buffer)
  end

  private def tui_scrollable_arg(v : SchemeValue, who : String) : TUI::Scrollable
    raise SchemeRuntimeError.new("#{who}: expected a tui scrollable pane, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "tui-scrollable"
    v.get(TUI::Scrollable)
  end

  private def tui_widget_arg(v : SchemeValue, who : String) : TUI::Widget
    raise SchemeRuntimeError.new("#{who}: expected a tui widget, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "tui-widget"
    v.get(TUI::Widget)
  end

  private def tui_vstack_arg(v : SchemeValue, who : String) : SchemeVStack
    widget = tui_widget_arg(v, who)
    raise SchemeRuntimeError.new("#{who}: expected a tui-vstack widget") unless widget.is_a?(SchemeVStack)
    widget
  end

  private def tui_text_edit_arg(v : SchemeValue, who : String) : TUI::TextEdit
    scrollable = tui_scrollable_arg(v, who)
    raise SchemeRuntimeError.new("#{who}: expected a tui-text-edit pane") unless scrollable.is_a?(TUI::TextEdit)
    scrollable
  end

  # A highlighter-fn's return value: a list of (text . style-or-#f)
  # pairs, matching the alist-of-pairs convention used elsewhere in this
  # module — #f means "no style" (TUI::Style.new's own default).
  private def tui_cells_from_scheme(v : SchemeValue, who : String) : Array(TUI::Cell)
    Creme.list_to_a(v).map do |pair|
      raise SchemeRuntimeError.new("#{who}: expected a list of (text . style) pairs") unless pair.is_a?(Cons)
      text = pair.car
      raise SchemeRuntimeError.new("#{who}: expected string cell text") unless text.is_a?(SchemeStr)
      style_v = pair.cdr
      style = style_v.is_a?(SchemeBox) && style_v.tag == "tui-style" ? style_v.get(TUI::Style) : TUI::Style.new
      TUI::Cell.new(text.value, style)
    end
  end

  # Alist of ("bold"|"dim"|"italic"|"underline"|"strikethrough"|"blink"|
  # "reverse" . #t/#f) and ("fg"|"bg" . tui-color) pairs, matching the
  # alist convention this codebase uses for object-shaped data.
  private def tui_style_from_alist(v : SchemeValue) : TUI::Style
    bold = false
    dim = false
    italic = false
    underline = false
    strikethrough = false
    blink = false
    reverse = false
    fg : TUI::Color? = nil
    bg : TUI::Color? = nil

    Creme.list_to_a(v).each do |pair|
      raise SchemeRuntimeError.new("tui-style: expected an alist of (key . value) pairs") unless pair.is_a?(Cons)
      key = pair.car
      raise SchemeRuntimeError.new("tui-style: expected a string key") unless key.is_a?(SchemeStr)
      value = pair.cdr
      case key.value
      when "bold"          then bold = Creme.truthy?(value)
      when "dim"           then dim = Creme.truthy?(value)
      when "italic"        then italic = Creme.truthy?(value)
      when "underline"     then underline = Creme.truthy?(value)
      when "strikethrough" then strikethrough = Creme.truthy?(value)
      when "blink"         then blink = Creme.truthy?(value)
      when "reverse"       then reverse = Creme.truthy?(value)
      when "fg"            then fg = tui_color_arg(value, "tui-style")
      when "bg"            then bg = tui_color_arg(value, "tui-style")
      else
        raise SchemeRuntimeError.new("tui-style: unknown style key '#{key.value}'")
      end
    end

    TUI::Style.new(bold: bold, dim: dim, italic: italic, underline: underline,
      strikethrough: strikethrough, blink: blink, reverse: reverse, fg: fg, bg: bg)
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "tui"], Creme::Builtins::Tui
  end
end
