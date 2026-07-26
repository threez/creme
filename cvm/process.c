/* (creme process) -- see process.h.
 *
 * Just `process-run`, matching src/scheme/modules/creme/process.cr's own
 * exact contract: (process-run cmd args) -> (list stdout stderr exit-code
 * success?), where cmd is a string and args a list of strings (NOT
 * including cmd itself, same as Crystal's own Process.run(cmd, args)).
 * Backed here by plain POSIX fork/pipe/execvp/waitpid rather than any
 * higher-level process library, since cvm has no other process/IO
 * abstraction of its own to build on (unlike native Crystal, which
 * already has Process/IO::Memory).
 *
 * Exists specifically so spec/creme/main_spec.scm -- the one entry point
 * for running every spec/creme spec file (each ending "_spec.scm") and
 * reporting ONE combined total (see modules/creme/spec-runner.sld's own header
 * comment) -- works the same way whether it's driven natively (`./bin/
 * creme spec/creme/main_spec.scm`) or reentrantly under cvm itself
 * (`./cvm/cvm spec/creme/main_spec.scm`): each spec file still gets
 * spawned as its own genuinely separate OS process either way, since
 * several spec files (prim_call_spec.scm, compiler_defmacro_spec.scm)
 * deliberately end by PERMANENTLY redefining a shared builtin to test
 * deopt behavior -- combining every file into one shared process (the
 * only alternative before this existed) would need a fragile, hand-
 * maintained load order to keep those files from corrupting every
 * other file that happens to run afterward. Real process isolation
 * sidesteps that risk entirely, so it was worth adding here rather than
 * working around its absence. */
#include <errno.h>
#include <poll.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <gc.h>

#include "process.h"

static void pr_buf_grow(char **buf, size_t *cap, size_t len, size_t extra) {
  if (len + extra > *cap) {
    size_t newcap = *cap ? *cap * 2 : 4096;
    while (newcap < len + extra) newcap *= 2;
    *buf = GC_REALLOC(*buf, newcap);
    *cap = newcap;
  }
}

static char *pr_cstring(Value s, const char *who) {
  if (s.tag != T_STR) cvm_abort("%s: expected a string", who);
  char *cs = GC_MALLOC((size_t)s.as.str.len + 1);
  memcpy(cs, s.as.str.chars, (size_t)s.as.str.len);
  cs[s.as.str.len] = 0;
  return cs;
}

/* Reads both the stdout and stderr pipes to EOF, interleaved via poll(2)
 * so neither one can deadlock the child by filling its own pipe buffer
 * while this side is only reading the other -- the same hazard a naive
 * "read stdout fully, then read stderr fully" sequence would hit against
 * a program that writes enough to both streams. */
static void pr_drain_pipes(int out_fd, int err_fd,
                            char **out_buf, size_t *out_len,
                            char **err_buf, size_t *err_len) {
  size_t out_cap = 0, err_cap = 0;
  int out_open = 1, err_open = 1;
  char tmp[4096];

  while (out_open || err_open) {
    struct pollfd fds[2];
    int nfds = 0, out_idx = -1, err_idx = -1;
    if (out_open) { out_idx = nfds; fds[nfds].fd = out_fd; fds[nfds].events = POLLIN; nfds++; }
    if (err_open) { err_idx = nfds; fds[nfds].fd = err_fd; fds[nfds].events = POLLIN; nfds++; }

    int pr = poll(fds, (nfds_t)nfds, -1);
    if (pr < 0) {
      if (errno == EINTR) continue;
      break;
    }

    if (out_open && (fds[out_idx].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t n = read(out_fd, tmp, sizeof(tmp));
      if (n > 0) {
        pr_buf_grow(out_buf, &out_cap, *out_len, (size_t)n);
        memcpy(*out_buf + *out_len, tmp, (size_t)n);
        *out_len += (size_t)n;
      } else {
        close(out_fd);
        out_open = 0;
      }
    }
    if (err_open && (fds[err_idx].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t n = read(err_fd, tmp, sizeof(tmp));
      if (n > 0) {
        pr_buf_grow(err_buf, &err_cap, *err_len, (size_t)n);
        memcpy(*err_buf + *err_len, tmp, (size_t)n);
        *err_len += (size_t)n;
      } else {
        close(err_fd);
        err_open = 0;
      }
    }
  }
}

static Value bi_process_run(VM *vm, Value *args, int nargs) {
  if (nargs != 2) cvm_abort("process-run: expected (cmd args)");
  char *cmd = pr_cstring(args[0], "process-run");

  int argc = 1;
  for (Value c = args[1]; c.tag == T_PAIR; c = c.as.pair->cdr) argc++;
  char **argv = GC_MALLOC(sizeof(char *) * (size_t)(argc + 1));
  argv[0] = cmd;
  int i = 1;
  for (Value c = args[1]; c.tag == T_PAIR; c = c.as.pair->cdr) argv[i++] = pr_cstring(c.as.pair->car, "process-run");
  argv[argc] = NULL;

  int out_pipe[2], err_pipe[2];
  if (pipe(out_pipe) != 0 || pipe(err_pipe) != 0) cvm_abort("process-run: pipe() failed");

  pid_t pid = fork();
  if (pid < 0) cvm_abort("process-run: fork() failed");

  if (pid == 0) {
    dup2(out_pipe[1], STDOUT_FILENO);
    dup2(err_pipe[1], STDERR_FILENO);
    close(out_pipe[0]);
    close(out_pipe[1]);
    close(err_pipe[0]);
    close(err_pipe[1]);
    execvp(cmd, argv);
    _exit(127); /* execvp only returns on failure */
  }

  close(out_pipe[1]);
  close(err_pipe[1]);

  char *out_buf = NULL, *err_buf = NULL;
  size_t out_len = 0, err_len = 0;
  pr_drain_pipes(out_pipe[0], err_pipe[0], &out_buf, &out_len, &err_buf, &err_len);

  int status = 0;
  waitpid(pid, &status, 0);
  int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

  Value result = v_nil();
  result = cvm_cons(vm, v_bool(exit_code == 0), result);
  result = cvm_cons(vm, v_int(exit_code), result);
  result = cvm_cons(vm, v_str(err_buf ? err_buf : "", (int)err_len), result);
  result = cvm_cons(vm, v_str(out_buf ? out_buf : "", (int)out_len), result);
  return result;
}

void cvm_register_process_builtins(VM *vm) {
  cvm_register_builtin(vm, "process-run", bi_process_run);
}
