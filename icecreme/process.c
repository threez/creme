/* (creme process) -- see process.h.
 *
 * Just `process-run`, matching src/creme/modules/creme/process.cr's own
 * exact contract: (process-run cmd args) -> (list stdout stderr exit-code
 * success?), where cmd is a string and args a list of strings (NOT
 * including cmd itself, same as Crystal's own Process.run(cmd, args)).
 * Backed here by plain POSIX fork/pipe/execvp/waitpid rather than any
 * higher-level process library, since icecreme has no other process/IO
 * abstraction of its own to build on (unlike native Crystal, which
 * already has Process/IO::Memory).
 *
 * Exists specifically so spec/creme/main_spec.scm -- the one entry point
 * for running every spec/creme spec file (each ending "_spec.scm") and
 * reporting ONE combined total (see modules/creme/spec-runner.sld's own header
 * comment) -- works the same way whether it's driven natively (`./bin/
 * creme spec/creme/main_spec.scm`) or reentrantly under icecreme itself
 * (`./icecreme/icecreme spec/creme/main_spec.scm`): each spec file still gets
 * spawned as its own genuinely separate OS process either way, since
 * several spec files (prim_call_spec.scm, compiler_defmacro_spec.scm)
 * deliberately end by PERMANENTLY redefining a shared builtin to test
 * deopt behavior -- combining every file into one shared process (the
 * only alternative before this existed) would need a fragile, hand-
 * maintained load order to keep those files from corrupting every
 * other file that happens to run afterward. Real process isolation
 * sidesteps that risk entirely, so it was worth adding here rather than
 * working around its absence. */
#include "builtin_config.h"

#if CREME_WITH_PROCESS

#include <errno.h>
#include <poll.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <gc.h>

#include "embed.h"
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
  if (s.tag != T_STR) creme_abort("%s: expected a string", who);
  char *cs = GC_MALLOC((size_t)s.aux + 1);
  memcpy(cs, s.as.chars, (size_t)s.aux);
  cs[s.aux] = 0;
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
      break; /* fds still open here are closed after the loop */
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
  /* Close any fd still open (e.g. after a poll() error break) so they don't leak. */
  if (out_open) close(out_fd);
  if (err_open) close(err_fd);
}

/* Close every descriptor above stdio in the just-forked child so the spawned
 * program can't touch our inherited listener/DB/actor sockets (also drops the
 * pipe fds, so no explicit closes are needed before execvp). */
static void close_inherited_fds(void) {
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__) || defined(__DragonFly__) || defined(__APPLE__)
  closefrom(3);
#else
#if defined(__linux__) && defined(SYS_close_range)
  /* One syscall on Linux >= 5.9 instead of an O(RLIMIT_NOFILE) close() loop;
   * fall through to the loop if the kernel is older (ENOSYS). */
  if (syscall(SYS_close_range, 3, ~0U, 0) == 0) return;
#endif
  long maxfd = sysconf(_SC_OPEN_MAX);
  if (maxfd < 0) maxfd = 1024;
  for (int fd = 3; fd < (int)maxfd; fd++) close(fd);
#endif
}

static Value bi_process_run(VM *vm, Value *args, int nargs) {
  creme_check_exact_args(nargs, 2, "process-run");
  const char *cmd = creme_arg_cstr(args, nargs, 0, "process-run");

  int n = creme_list_length(args[1]);
  Value *arg_vals = GC_MALLOC(sizeof(Value) * (size_t)(n ? n : 1));
  creme_list_to_values(args[1], arg_vals, n, "process-run");

  char **argv = GC_MALLOC(sizeof(char *) * (size_t)(n + 2));
  argv[0] = (char *)cmd;
  for (int i = 0; i < n; i++) argv[i + 1] = pr_cstring(arg_vals[i], "process-run");
  argv[n + 1] = NULL;

  int out_pipe[2], err_pipe[2];
  if (pipe(out_pipe) != 0) creme_abort("process-run: pipe() failed");
  if (pipe(err_pipe) != 0) {
    close(out_pipe[0]);
    close(out_pipe[1]);
    creme_abort("process-run: pipe() failed");
  }

  pid_t pid = fork();
  if (pid < 0) {
    close(out_pipe[0]);
    close(out_pipe[1]);
    close(err_pipe[0]);
    close(err_pipe[1]);
    creme_abort("process-run: fork() failed");
  }

  if (pid == 0) {
    if (dup2(out_pipe[1], STDOUT_FILENO) < 0 || dup2(err_pipe[1], STDERR_FILENO) < 0) _exit(127);
    close_inherited_fds();
    execvp(cmd, argv);
    _exit(127); /* execvp only returns on failure */
  }

  close(out_pipe[1]);
  close(err_pipe[1]);

  char *out_buf = NULL, *err_buf = NULL;
  size_t out_len = 0, err_len = 0;
  pr_drain_pipes(out_pipe[0], err_pipe[0], &out_buf, &out_len, &err_buf, &err_len);

  int status = 0;
  pid_t w;
  do { w = waitpid(pid, &status, 0); } while (w < 0 && errno == EINTR);
  int exit_code = (w >= 0 && WIFEXITED(status)) ? WEXITSTATUS(status) : -1;

  Value result = v_nil();
  result = creme_cons(vm, v_bool(exit_code == 0), result);
  result = creme_cons(vm, v_int(exit_code), result);
  result = creme_cons(vm, v_str(err_buf ? err_buf : "", (int)err_len), result);
  result = creme_cons(vm, v_str(out_buf ? out_buf : "", (int)out_len), result);
  return result;
}

/* (sleep-ms! milliseconds) -- real nanosleep(2), matching native Crystal's
 * own sleep-ms! contract (src/creme/modules/creme/process.cr) exactly:
 * an exact non-negative integer count of milliseconds, unspecified return.
 * icecreme actors (actor.c) are real OS threads (one pthread each, not a
 * green-thread scheduler), so blocking here only blocks the ONE calling
 * thread -- exactly like native's sleep! only yields the calling fiber --
 * never the whole process. Exists so portable Scheme code (e.g. (creme
 * raft-scheme)'s election/heartbeat tickers) has a real timer primitive to
 * call under icecreme at all; before this, icecreme had no sleep of any kind. */
static Value bi_sleep_ms(VM *vm, Value *args, int nargs) {
  (void)vm;
  creme_check_exact_args(nargs, 1, "sleep-ms!");
  int64_t ms = creme_arg_int(args, nargs, 0, "sleep-ms!");
  if (ms < 0) creme_abort("sleep-ms!: expected a non-negative integer count of milliseconds");
  struct timespec req;
  req.tv_sec = ms / 1000;
  req.tv_nsec = (ms % 1000) * 1000000L;
  while (nanosleep(&req, &req) != 0 && errno == EINTR) {
    /* interrupted by a signal -- nanosleep already refilled req with the
     * remaining time, so just retry until the full duration has elapsed */
  }
  return v_nil();
}

void creme_register_process_builtins(VM *vm) {
  creme_register_builtin(vm, "process-run", bi_process_run);
  creme_register_builtin(vm, "sleep-ms!", bi_sleep_ms);
}

#endif /* CREME_WITH_PROCESS */
