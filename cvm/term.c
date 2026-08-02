/* (creme builtin term) -- see term.h.
 *
 * A direct C port of src/scheme/modules/creme/term.cr, which itself reuses
 * the exact same `stty` shell-outs and escape-sequence disambiguation logic
 * as lib/tui/src/tui/core/term.cr and lib/tui/src/tui/core/keys.cr. Kept in
 * lockstep with term.cr BY HAND (same procedure names/arities, same alist
 * shapes: `((kind . "char") (char . #\x))` for a keypress, `((kind .
 * "<name>"))` for every other kind -- see kind_alist/char_alist below) so a
 * portable Scheme REPL loop can call the SAME procedures regardless of
 * which backend (cvm or native/self-hosted Crystal) it's running under.
 *
 * Deliberately shells out to `stty` (system(3)) rather than touching
 * termios.h directly, exactly matching term.cr's own approach -- not
 * because cvm couldn't use termios directly, but so both backends flip the
 * SAME real terminal driver knobs the SAME way, for genuine behavioral
 * parity rather than two independently-behaving raw-mode implementations.
 *
 * term-read-key reads raw, unbuffered bytes directly off STDIN_FILENO via
 * read(2) -- NOT getline/FILE* (see builtins.c's bi_read_line for the
 * buffered-FILE* convention used elsewhere in this codebase) -- because raw
 * mode's whole point is byte-at-a-time input with no line buffering to
 * wait on. The one exception (matching term.cr's Keys.read/ESC_TIMEOUT
 * approach) is a bare `\e`: whether it's a standalone Escape keypress or
 * the start of a longer CSI/SS3 sequence can't be told apart by looking at
 * just that one byte, so read_byte_timeout below waits up to
 * TERM_ESC_TIMEOUT_MS (50ms, same value as term.cr's ESC_TIMEOUT) via
 * select(2) for a follow-up byte before giving up and reporting a bare
 * "escape". A real terminal sends a whole escape sequence back-to-back in
 * a single burst well under 50ms; a human pressing the bare Escape key
 * alone never types a `[`/`O` byte within that window, so 50ms cleanly
 * separates the two cases in practice.
 *
 * KNOWN LIMITATION (matches the task spec, not term.cr specifically): each
 * byte >= 32 is reported as its own Latin-1-ish "char" kind -- no UTF-8
 * multi-byte decoding. A multi-byte UTF-8 character typed at the terminal
 * currently surfaces as N separate single-byte "char" events instead of
 * one multi-byte one. Fine for v1 (ASCII-heavy REPL editing); a real
 * decoder would need to buffer continuation bytes across term-read-key
 * calls. */
#include <errno.h>
#include <gc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

#include "term.h"

/* Same value as term.cr's ESC_TIMEOUT/TUI::Keys::ESC_TIMEOUT -- how long to
 * wait for a follow-up byte after a bare `\e` before deciding it really was
 * just a standalone Escape keypress. */
#define TERM_ESC_TIMEOUT_USEC 50000

/* Builds a Value from a C string literal/static buffer directly (no copy)
 * -- safe because v_str/v_sym (value.h) just store the pointer, and every
 * string this file ever wraps this way is a `static const char *` literal
 * with the process's whole lifetime, exactly like actor.c's/vm.c's own
 * v_sym("...", N) call sites (see those files for the established
 * convention this follows). */
static Value term_lit_str(const char *s) { return v_str(s, (int)strlen(s)); }
static Value term_lit_sym(const char *s) { return v_sym(s, (int)strlen(s)); }

/* ((kind . "<kind>")) -- every non-char key event's alist shape. */
static Value kind_alist(VM *vm, const char *kind) {
  Value pair = cvm_cons(vm, term_lit_sym("kind"), term_lit_str(kind));
  return cvm_cons(vm, pair, v_nil());
}

/* ((kind . "char") (char . #\<byte>)) -- the one kind that carries a
 * payload; `byte` is treated as its own Latin-1-ish codepoint (see this
 * file's header comment on the UTF-8 limitation). */
static Value char_alist(VM *vm, int byte) {
  Value kind_pair = cvm_cons(vm, term_lit_sym("kind"), term_lit_str("char"));
  Value char_pair = cvm_cons(vm, term_lit_sym("char"), v_char(byte));
  return cvm_cons(vm, kind_pair, cvm_cons(vm, char_pair, v_nil()));
}

/* (term-raw-mode-enter!) */
static Value bi_term_raw_mode_enter(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args; (void)nargs;
  if (system("stty -echo -icanon -isig min 1 time 0 2>/dev/null") == -1) { /* ignore -- best effort, same as term.cr's own unchecked system() call */ }
  return v_nil();
}

/* (term-raw-mode-exit!) */
static Value bi_term_raw_mode_exit(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args; (void)nargs;
  if (system("stty echo icanon isig 2>/dev/null") == -1) { /* ignore -- best effort */ }
  return v_nil();
}

/* Blocking single-byte read off STDIN_FILENO, retrying across EINTR (a
 * profiler SIGPROF tick or similar could otherwise interrupt it). Returns
 * 1 with `*out` set on a real byte, 0 on genuine EOF (read() returned 0). */
static int term_read_byte_blocking(unsigned char *out) {
  for (;;) {
    ssize_t n = read(STDIN_FILENO, out, 1);
    if (n == 1) return 1;
    if (n == 0) return 0; /* EOF */
    if (n < 0 && errno == EINTR) continue;
    return 0; /* treat any other read() error as EOF -- never hang/crash */
  }
}

/* select(2)-gated single-byte read with a TERM_ESC_TIMEOUT_USEC deadline --
 * used only for the byte(s) immediately following a bare `\e`. Returns 1
 * with `*out` set if a byte arrived in time; 0 if the timeout elapsed OR
 * the read hit real EOF (both cases fold into "give up on this escape
 * sequence", matching term.cr's own read_byte_timeout returning nil for
 * either an IO::TimeoutError or EOF). */
static int term_read_byte_timeout(unsigned char *out) {
  fd_set rfds;
  struct timeval tv;
  FD_ZERO(&rfds);
  FD_SET(STDIN_FILENO, &rfds);
  tv.tv_sec = 0;
  tv.tv_usec = TERM_ESC_TIMEOUT_USEC;
  int r = select(STDIN_FILENO + 1, &rfds, NULL, NULL, &tv);
  if (r <= 0) return 0; /* r == 0: timed out; r < 0: treat as timed out too */
  return term_read_byte_blocking(out);
}

/* Mirrors term.cr's read_csi_seq exactly: a single-letter CSI sequence
 * (arrows, Home/End) is already complete after `first` -- reading further
 * would swallow the NEXT keypress's bytes hunting for a terminator that
 * already arrived. `seq`/`seq_len` is an in/out buffer of capacity >= 8. */
static void term_read_csi_seq(unsigned char first, char *seq, int *seq_len) {
  seq[0] = (char)first;
  *seq_len = 1;
  if (first >= '@' && first <= '~') return;
  for (int i = 0; i < 7; i++) {
    unsigned char b;
    if (!term_read_byte_timeout(&b)) break;
    seq[*seq_len] = (char)b;
    (*seq_len)++;
    if (b >= '@' && b <= '~') break;
  }
}

static Value term_csi_key(VM *vm, const char *seq, int len) {
  if (len == 1 && seq[0] == 'A') return kind_alist(vm, "up");
  if (len == 1 && seq[0] == 'B') return kind_alist(vm, "down");
  if (len == 1 && seq[0] == 'C') return kind_alist(vm, "right");
  if (len == 1 && seq[0] == 'D') return kind_alist(vm, "left");
  if (len == 1 && seq[0] == 'H') return kind_alist(vm, "home");
  if (len == 1 && seq[0] == 'F') return kind_alist(vm, "end");
  if (len == 2 && seq[0] == '3' && seq[1] == '~') return kind_alist(vm, "delete");
  /* Alt/Ctrl+Right ("1;3C"/"1;5C") and Alt/Ctrl+Left ("1;3D"/"1;5D") --
   * mirrors term.cr's csi_key exactly. */
  if (len == 4 && seq[0] == '1' && seq[1] == ';' && (seq[2] == '3' || seq[2] == '5') && seq[3] == 'C') {
    return kind_alist(vm, "word-right");
  }
  if (len == 4 && seq[0] == '1' && seq[1] == ';' && (seq[2] == '3' || seq[2] == '5') && seq[3] == 'D') {
    return kind_alist(vm, "word-left");
  }
  return kind_alist(vm, "unknown");
}

static Value term_parse_ss3(VM *vm) {
  unsigned char b;
  if (!term_read_byte_timeout(&b)) return kind_alist(vm, "escape");
  switch (b) {
    case 'A': return kind_alist(vm, "up");
    case 'B': return kind_alist(vm, "down");
    case 'C': return kind_alist(vm, "right");
    case 'D': return kind_alist(vm, "left");
    case 'H': return kind_alist(vm, "home");
    case 'F': return kind_alist(vm, "end");
    default:  return kind_alist(vm, "unknown");
  }
}

static Value term_parse_csi(VM *vm) {
  unsigned char first;
  if (!term_read_byte_timeout(&first)) return kind_alist(vm, "unknown");
  char seq[8];
  int seq_len = 0;
  term_read_csi_seq(first, seq, &seq_len);
  return term_csi_key(vm, seq, seq_len);
}

static Value term_parse_escape(VM *vm) {
  unsigned char b;
  if (!term_read_byte_timeout(&b)) return kind_alist(vm, "escape");
  if (b == '[') return term_parse_csi(vm);
  if (b == 'O') return term_parse_ss3(vm);
  /* Alt-Left/Alt-Right, bare-ESC form (some terminal configs send this
   * instead of the CSI form term_csi_key handles above) -- mirrors
   * term.cr's parse_escape exactly. */
  if (b == 'b') return kind_alist(vm, "word-left");
  if (b == 'f') return kind_alist(vm, "word-right");
  return kind_alist(vm, "escape");
}

/* (term-read-key) -- blocking read of one key event; see this file's
 * header comment for the byte-classification rules and their one known
 * limitation (no UTF-8 decoding). */
static Value bi_term_read_key(VM *vm, Value *args, int nargs) {
  (void)args; (void)nargs;
  unsigned char byte;
  if (!term_read_byte_blocking(&byte)) return kind_alist(vm, "eof");

  switch (byte) {
    case '\r': case '\n': return kind_alist(vm, "enter");
    case 0x7F: case 0x08: return kind_alist(vm, "backspace");
    case 0x01:            return kind_alist(vm, "ctrl-a");
    case 0x03:            return kind_alist(vm, "ctrl-c");
    case 0x04:            return kind_alist(vm, "ctrl-d");
    case 0x05:            return kind_alist(vm, "ctrl-e");
    case 0x09:            return kind_alist(vm, "tab");
    case 0x1b:            return term_parse_escape(vm);
    default:
      if (byte >= 32) return char_alist(vm, byte);
      return kind_alist(vm, "unknown");
  }
}

/* (term-move-cursor! rows cols) -- relative-only ANSI cursor movement; see
 * term.cr's own term_move_cursor for the exact same contract (0 on either
 * axis skips that axis's escape sequence entirely). */
static Value bi_term_move_cursor(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 2 || args[0].tag != T_INT || args[1].tag != T_INT) {
    cvm_abort("term-move-cursor!: expected two integers");
  }
  int64_t rows = args[0].as.i;
  int64_t cols = args[1].as.i;
  if (rows != 0) {
    printf("\x1b[%lld%c", (long long)(rows > 0 ? rows : -rows), rows > 0 ? 'B' : 'A');
  }
  if (cols != 0) {
    printf("\x1b[%lld%c", (long long)(cols > 0 ? cols : -cols), cols > 0 ? 'C' : 'D');
  }
  fflush(stdout);
  return v_nil();
}

/* (term-clear-to-eol!) */
static Value bi_term_clear_to_eol(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args; (void)nargs;
  fputs("\x1b[K", stdout);
  fflush(stdout);
  return v_nil();
}

/* (term-write! s) -- writes s's raw bytes (NOT NUL-terminated C-string
 * semantics -- Scheme strings can contain embedded NULs) then flushes,
 * since raw mode disables the terminal's own line-buffering-triggered
 * flush-on-newline. */
static Value bi_term_write(VM *vm, Value *args, int nargs) {
  (void)vm;
  if (nargs < 1 || args[0].tag != T_STR) cvm_abort("term-write!: expected a string");
  fwrite(args[0].as.chars, 1, (size_t)args[0].aux, stdout);
  fflush(stdout);
  return v_nil();
}

/* Whether STDOUT is an actual terminal, not a pipe/redirected file -- see
 * src/scheme/modules/creme/term.cr's own stdout_tty_p for the same
 * builtin natively; kept in sync so (creme spec)'s color decision behaves
 * identically under bin/creme, --self-hosted, and cvm/cvm. */
static Value bi_stdout_tty(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args; (void)nargs;
  return v_bool(isatty(STDOUT_FILENO));
}

/* Whether STDIN is an actual terminal, not a pipe/redirected file -- same
 * pattern as bi_stdout_tty above, added alongside it for the same reason:
 * see term.cr's own stdin_tty_p for the Crystal-side twin (used by the
 * portable term REPL to decide whether it's safe to flip stdin into
 * raw/cbreak mode at all). */
static Value bi_stdin_tty(VM *vm, Value *args, int nargs) {
  (void)vm; (void)args; (void)nargs;
  return v_bool(isatty(STDIN_FILENO));
}

void cvm_register_term_builtins(VM *vm) {
  cvm_register_builtin(vm, "term-raw-mode-enter!", bi_term_raw_mode_enter);
  cvm_register_builtin(vm, "term-raw-mode-exit!", bi_term_raw_mode_exit);
  cvm_register_builtin(vm, "term-read-key", bi_term_read_key);
  cvm_register_builtin(vm, "term-move-cursor!", bi_term_move_cursor);
  cvm_register_builtin(vm, "term-clear-to-eol!", bi_term_clear_to_eol);
  cvm_register_builtin(vm, "term-write!", bi_term_write);
  cvm_register_builtin(vm, "stdout-tty?", bi_stdout_tty);
  cvm_register_builtin(vm, "stdin-tty?", bi_stdin_tty);
}
