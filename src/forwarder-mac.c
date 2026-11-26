#define _GNU_SOURCE
/*
 * LD_PRELOAD execve forwarder.
 *
 * macOS build. Load it with DYLD_INSERT_LIBRARIES into a harness that is
 * not hardened (OpenCode, adhoc Codex). exec and posix_spawn of a user
 * command become a local ssh to RW_SSH_TARGET. ssh, dyld, and any basename
 * in RW_EXEMPT stay local. A hardened binary ignores this library.
 *
 * The hook uses one static command buffer. One exec at a time. glibc's
 * posix_spawn is interposed in the parent, because the vfork child calls
 * libc's internal execve and would not hit an execve-only hook.
 *
 * Env forwarded to the remote command: RW_ENV_MODE=full sends the caller's
 * env minus LD_PRELOAD, RW_*, and SSH_AUTH_SOCK. The default is a short
 * allowlist (PATH, HOME, TERM, LANG, LC_ALL, LC_CTYPE, USER, LOGNAME,
 * SHELL) so a harness token in the environment is not copied to the remote.
 * The local ssh process also has LD_PRELOAD removed.
 *
 * RW_GUEST_ROOT and RW_REMOTE_ROOT rewrite that prefix in the exec path,
 * in argv, and in the cwd. RW_REMOTE_CWD, when set, wins over the cwd.
 */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static int (*real_execve)(const char *, char *const [], char *const []);
static int (*real_posix_spawn)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                               const posix_spawnattr_t *, char *const [], char *const []);

static char cmd[1024 * 1024];
static char remote_cmd[2 * 1024 * 1024];
static char *ssh_argv[48];
static char *clean_env[512];
static char *var_argv[256];

/* dlsym follows DYLD_INTERPOSE, so it returns this library. The export in
 * libsystem_kernel is the un-interposed function. __posix_spawn is a
 * five-argument syscall and does not accept file actions. */
static void *kernel_symbol(const char *symbol) {
  uint32_t i;
  uint32_t n = _dyld_image_count();
  for (i = 0; i < n; i++) {
    const char *name = _dyld_get_image_name(i);
    NSSymbol sym;
    if (!name || !strstr(name, "libsystem_kernel.dylib")) {
      continue;
    }
    sym = NSLookupSymbolInImage(_dyld_get_image_header(i), symbol,
                                 NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR);
    return sym ? NSAddressOfSymbol(sym) : NULL;
  }
  return NULL;
}

static int init_reals(void) {
  if (real_execve && real_posix_spawn) {
    return 0;
  }
  if (!real_execve) {
    real_execve = kernel_symbol("_execve");
  }
  if (!real_posix_spawn) {
    real_posix_spawn = kernel_symbol("_posix_spawn");
  }
  return (real_execve && real_posix_spawn) ? 0 : -1;
}

/* One process that re-enters the hook aborts instead of filling the log. */
static int guard_call(void) {
  static int calls;
  calls++;
  if (calls > 64) {
    _exit(95);
  }
  return 0;
}

static const char *base_of(const char *path) {
  const char *slash;
  if (!path || !*path) {
    return "";
  }
  slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

static int list_has(const char *list, const char *base) {
  size_t n;
  const char *p;
  if (!list || !base || !*base) {
    return 0;
  }
  n = strlen(base);
  p = list;
  while (*p) {
    const char *start;
    while (*p == ',') {
      p++;
    }
    if (!*p) {
      break;
    }
    start = p;
    while (*p && *p != ',') {
      p++;
    }
    if ((size_t)(p - start) == n && memcmp(start, base, n) == 0) {
      return 1;
    }
  }
  return 0;
}

/* posix_spawnp and execvp have no raw twin. Resolve PATH, then call the raw
 * absolute-path function so the exempt path does not re-enter the wrapper. */
static int resolve_path(const char *file, char *out, size_t outsz) {
  const char *path;
  const char *cursor;
  size_t flen;
  if (!file || !*file || !out || outsz < 2) {
    return -1;
  }
  if (strchr(file, '/')) {
    if (strlen(file) >= outsz) {
      return -1;
    }
    memcpy(out, file, strlen(file) + 1);
    return 0;
  }
  flen = strlen(file);
  path = getenv("PATH");
  if (!path || !*path) {
    path = "/usr/bin:/bin";
  }
  cursor = path;
  while (*cursor) {
    const char *colon = strchr(cursor, ':');
    size_t n = colon ? (size_t)(colon - cursor) : strlen(cursor);
    const char *dir = cursor;
    size_t dlen = n;
    if (n == 0) {
      dir = ".";
      dlen = 1;
    }
    if (dlen + 1 + flen + 1 <= outsz) {
      memcpy(out, dir, dlen);
      out[dlen] = '/';
      memcpy(out + dlen + 1, file, flen + 1);
      if (access(out, X_OK) == 0) {
        return 0;
      }
    }
    if (!colon) {
      break;
    }
    cursor = colon + 1;
  }
  return -1;
}

static int is_linker(const char *base) {
  return strncmp(base, "ld-linux", 8) == 0 || strncmp(base, "ld-musl", 7) == 0 ||
         strcmp(base, "ld.so") == 0 || strcmp(base, "dyld") == 0;
}

/* A harness often re-execs a sibling (Codex execs .codex-wrapped). That
 * sibling is still the harness. Tool commands live in other directories. */
static int same_dir_as_self(const char *file) {
  char self[PATH_MAX];
  char self_real[PATH_MAX];
  char file_real[PATH_MAX];
  uint32_t sz = sizeof self;
  char *slash;
  if (!file || file[0] != '/') {
    return 0;
  }
  if (_NSGetExecutablePath(self, &sz) != 0) {
    return 0;
  }
  if (!realpath(self, self_real) || !realpath(file, file_real)) {
    return 0;
  }
  slash = strrchr(self_real, '/');
  if (!slash) {
    return 0;
  }
  *slash = '\0';
  slash = strrchr(file_real, '/');
  if (!slash) {
    return 0;
  }
  *slash = '\0';
  return strcmp(self_real, file_real) == 0;
}

/* Returns a pass reason, or NULL when the call should be forwarded. */
static const char *pass_reason(const char *file) {
  const char *target = getenv("RW_SSH_TARGET");
  const char *base = base_of(file);
  if (!target || !*target) {
    return "pass-notarget";
  }
  if (!file || !*file) {
    return "pass-empty";
  }
  if (strcmp(base, "ssh") == 0 || is_linker(base) || list_has(getenv("RW_EXEMPT"), base)) {
    return "pass-exempt";
  }
  if (same_dir_as_self(file)) {
    return "pass-selfdir";
  }
  return NULL;
}

static void log_line(const char *decision, const char *path, char *const argv[]) {
  const char *logp;
  guard_call();
  logp = getenv("RW_LOG");
  char buf[768];
  int fd;
  int n;
  if (!logp || !*logp) {
    return;
  }
  fd = open(logp, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) {
    return;
  }
  n = snprintf(buf, sizeof buf, "pid=%d decision=%s path=%s argv0=%s target=%s\n", getpid(),
               decision, path ? path : "-", (argv && argv[0]) ? argv[0] : "-",
               getenv("RW_SSH_TARGET") ? getenv("RW_SSH_TARGET") : "-");
  if (n > 0) {
    size_t len = (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1;
    ssize_t w = write(fd, buf, len);
    (void)w;
  }
  close(fd);
}

static int ident_ok(const char *name) {
  if (!name || !((*name >= 'A' && *name <= 'Z') || (*name >= 'a' && *name <= 'z') || *name == '_')) {
    return 0;
  }
  for (name++; *name; name++) {
    if (!((*name >= 'A' && *name <= 'Z') || (*name >= 'a' && *name <= 'z') ||
          (*name >= '0' && *name <= '9') || *name == '_')) {
      return 0;
    }
  }
  return 1;
}

static int skip_env(const char *entry) {
  const char *eq = strchr(entry, '=');
  size_t n = eq ? (size_t)(eq - entry) : strlen(entry);
  if (n == 10 && strncmp(entry, "LD_PRELOAD", 10) == 0) {
    return 1;
  }
  if (n >= 3 && strncmp(entry, "RW_", 3) == 0) {
    return 1;
  }
  if (n == 13 && strncmp(entry, "SSH_AUTH_SOCK", 13) == 0) {
    return 1;
  }
  if (n >= 5 && strncmp(entry, "DYLD_", 5) == 0) {
    return 1;
  }
  return 0;
}

static int append_raw(size_t *used, const char *s, size_t n) {
  if (*used + n + 1 > sizeof cmd) {
    return -1;
  }
  memcpy(cmd + *used, s, n);
  *used += n;
  cmd[*used] = '\0';
  return 0;
}

static int append_str(size_t *used, const char *s) {
  return append_raw(used, s, strlen(s));
}

static int append_quoted(size_t *used, const char *s) {
  if (append_str(used, "'") != 0) {
    return -1;
  }
  for (; *s; s++) {
    if (*s == '\'') {
      if (append_str(used, "'\\''") != 0) {
        return -1;
      }
    } else {
      if (append_raw(used, s, 1) != 0) {
        return -1;
      }
    }
  }
  return append_str(used, "'");
}

static int append_exports(size_t *used, char *const envp[], int reduced) {
  int i;
  if (!envp) {
    return 0;
  }
  for (i = 0; envp[i]; i++) {
    const char *eq;
    char name[256];
    size_t n;
    if (skip_env(envp[i])) {
      continue;
    }
    eq = strchr(envp[i], '=');
    if (!eq) {
      continue;
    }
    n = (size_t)(eq - envp[i]);
    if (n == 0 || n >= sizeof name) {
      continue;
    }
    memcpy(name, envp[i], n);
    name[n] = '\0';
    if (!ident_ok(name)) {
      continue;
    }
    if (reduced) {
      int keep = strcmp(name, "PATH") == 0 || strcmp(name, "HOME") == 0 ||
                 strcmp(name, "TERM") == 0 || strcmp(name, "LANG") == 0 ||
                 strcmp(name, "LC_ALL") == 0 || strcmp(name, "LC_CTYPE") == 0 ||
                 strcmp(name, "USER") == 0 || strcmp(name, "LOGNAME") == 0 ||
                 strcmp(name, "SHELL") == 0;
      if (!keep) {
        continue;
      }
    }
    if (append_str(used, "export ") != 0 || append_str(used, name) != 0 || append_str(used, "=") != 0 ||
        append_quoted(used, eq + 1) != 0 || append_str(used, "\n") != 0) {
      return -1;
    }
  }
  return 0;
}

/* One exec at a time, same as cmd. subst_out holds one rewritten argument. */
static char subst_out[256 * 1024];
static char argv_store[1024 * 1024];
static char *mapped_argv[256];
static const char *mapped_file_s;
static char cwd_store[8192];

static void root_len(const char *root, size_t *n) {
  *n = root ? strlen(root) : 0;
  while (*n > 1 && root[*n - 1] == '/') {
    (*n)--;
  }
}

/* Rewrite every RW_GUEST_ROOT prefix to RW_REMOTE_ROOT. A root of "/" is ignored. */
static int subst_into(const char *in, char *dest, size_t destsz) {
  const char *guest = getenv("RW_GUEST_ROOT");
  const char *remote = getenv("RW_REMOTE_ROOT");
  size_t ng = 0;
  size_t nr = 0;
  size_t o = 0;
  size_t left;
  const char *p;
  if (!in) {
    if (destsz == 0) {
      return -1;
    }
    dest[0] = '\0';
    return 0;
  }
  root_len(guest, &ng);
  root_len(remote, &nr);
  if (ng < 2 || nr < 1 || !guest || !remote) {
    if (strlen(in) + 1 > destsz) {
      return -1;
    }
    memcpy(dest, in, strlen(in) + 1);
    return 0;
  }
  p = in;
  left = strlen(in);
  while (left > 0) {
    if (left >= ng && memcmp(p, guest, ng) == 0 && (p[ng] == '\0' || p[ng] == '/')) {
      if (o + nr >= destsz) {
        return -1;
      }
      memcpy(dest + o, remote, nr);
      o += nr;
      p += ng;
      left -= ng;
    } else {
      if (o + 1 >= destsz) {
        return -1;
      }
      dest[o++] = *p++;
      left--;
    }
  }
  if (o >= destsz) {
    return -1;
  }
  dest[o] = '\0';
  return 0;
}

static const char *stash(size_t *used, const char *s) {
  size_t n = strlen(s) + 1;
  char *p;
  if (*used + n > sizeof argv_store) {
    return NULL;
  }
  p = argv_store + *used;
  memcpy(p, s, n);
  *used += n;
  return p;
}

static int map_args(const char *file, char *const argv[]) {
  size_t used = 0;
  int i;
  if (subst_into(file ? file : "", subst_out, sizeof subst_out) != 0) {
    return -1;
  }
  mapped_file_s = stash(&used, subst_out);
  /* macOS login shell is /bin/zsh. The Linux host has /bin/bash and does
   * not have /bin/zsh, so a harness shell lands as bash. */
  if (mapped_file_s && strcmp(base_of(mapped_file_s), "zsh") == 0) {
    mapped_file_s = "/bin/bash";
  }
  if (!mapped_file_s) {
    return -1;
  }
  if (!argv) {
    mapped_argv[0] = NULL;
    return 0;
  }
  for (i = 0; argv[i] && i < 255; i++) {
    if (subst_into(argv[i], subst_out, sizeof subst_out) != 0) {
      return -1;
    }
    mapped_argv[i] = (char *)stash(&used, subst_out);
    if (!mapped_argv[i]) {
      return -1;
    }
  }
  if (argv[i]) {
    return -1;
  }
  mapped_argv[i] = NULL;
  return 0;
}

/* 0 and *out set or NULL. -1 if a translated cwd does not fit. */
static int pick_cwd(const char **out) {
  const char *fixed = getenv("RW_REMOTE_CWD");
  char cwd[4096];
  *out = NULL;
  if (fixed && *fixed) {
    *out = fixed;
    return 0;
  }
  if (!getenv("RW_GUEST_ROOT") || !getenv("RW_REMOTE_ROOT")) {
    return 0;
  }
  if (!getcwd(cwd, sizeof cwd)) {
    return 0;
  }
  if (subst_into(cwd, cwd_store, sizeof cwd_store) != 0) {
    return -1;
  }
  if (strcmp(cwd_store, cwd) == 0) {
    return 0;
  }
  *out = cwd_store;
  return 0;
}

static int build_cmd(const char *file, char *const argv[], char *const envp[]) {
  size_t used = 0;
  const char *cwd = NULL;
  const char *argv0;
  int argi;
  const char *mode = getenv("RW_ENV_MODE");
  int reduced = !(mode && strcmp(mode, "full") == 0);
  cmd[0] = '\0';
  if (map_args(file, argv) != 0 || pick_cwd(&cwd) != 0) {
    return -1;
  }
  if (append_exports(&used, envp ? envp : environ, reduced) != 0) {
    if (reduced) {
      return -1;
    }
    used = 0;
    cmd[0] = '\0';
    if (append_exports(&used, envp ? envp : environ, 1) != 0) {
      return -1;
    }
  }
  if (cwd && *cwd) {
    if (append_str(&used, "cd ") != 0 || append_quoted(&used, cwd) != 0 ||
        append_str(&used, " && ") != 0) {
      return -1;
    }
  }
  argv0 = mapped_argv[0] ? mapped_argv[0] : mapped_file_s;
  if (append_str(&used, "exec -a ") != 0 || append_quoted(&used, argv0) != 0 ||
      append_str(&used, " ") != 0 || append_quoted(&used, mapped_file_s) != 0) {
    return -1;
  }
  /* mapped_argv[0] is NULL when the caller passed no argv. Do not read [1]. */
  if (mapped_argv[0]) {
    for (argi = 1; mapped_argv[argi]; argi++) {
      if (append_str(&used, " ") != 0 || append_quoted(&used, mapped_argv[argi]) != 0) {
        return -1;
      }
    }
  }
  if (append_str(&used, "\n") != 0) {
    return -1;
  }
  return 0;
}

static char *const *build_clean_env(char *const envp[]) {
  int n = 0;
  int i;
  if (!envp) {
    envp = environ;
  }
  for (i = 0; envp && envp[i] && n < 510; i++) {
    if (strncmp(envp[i], "LD_PRELOAD=", 11) == 0 || strncmp(envp[i], "DYLD_", 5) == 0 ||
        strncmp(envp[i], "RW_", 3) == 0) {
      continue;
    }
    clean_env[n++] = envp[i];
  }
  clean_env[n] = NULL;
  return clean_env;
}

static int build_ssh_argv(void) {
  const char *target = getenv("RW_SSH_TARGET");
  const char *ident = getenv("RW_SSH_IDENTITY");
  const char *known = getenv("RW_KNOWN_HOSTS");
  const char *port = getenv("RW_SSH_PORT");
  const char *cpath = getenv("RW_CONTROL_PATH");
  static char known_opt[512];
  static char cpath_opt[512];
  int i = 0;
  if (!cpath || !*cpath) {
    cpath = "/tmp/rw-fwd-%C";
  }
  snprintf(cpath_opt, sizeof cpath_opt, "ControlPath=%s", cpath);
  ssh_argv[i++] = "ssh";
  ssh_argv[i++] = "-T";
  ssh_argv[i++] = "-o";
  ssh_argv[i++] = "BatchMode=yes";
  ssh_argv[i++] = "-o";
  ssh_argv[i++] = "ConnectTimeout=8";
  ssh_argv[i++] = "-o";
  ssh_argv[i++] = "LogLevel=ERROR";
  ssh_argv[i++] = "-o";
  ssh_argv[i++] = "GlobalKnownHostsFile=/dev/null";
  if (known && *known) {
    snprintf(known_opt, sizeof known_opt, "UserKnownHostsFile=%s", known);
    ssh_argv[i++] = "-o";
    ssh_argv[i++] = "StrictHostKeyChecking=yes";
    ssh_argv[i++] = "-o";
    ssh_argv[i++] = known_opt;
  } else {
    ssh_argv[i++] = "-o";
    ssh_argv[i++] = "StrictHostKeyChecking=accept-new";
    ssh_argv[i++] = "-o";
    ssh_argv[i++] = "UserKnownHostsFile=/dev/null";
  }
  ssh_argv[i++] = "-o";
  ssh_argv[i++] = "ControlMaster=auto";
  ssh_argv[i++] = "-o";
  ssh_argv[i++] = "ControlPersist=5m";
  ssh_argv[i++] = "-o";
  ssh_argv[i++] = cpath_opt;
  if (ident && *ident) {
    ssh_argv[i++] = "-i";
    ssh_argv[i++] = (char *)ident;
    ssh_argv[i++] = "-o";
    ssh_argv[i++] = "IdentitiesOnly=yes";
  }
  if (port && *port) {
    ssh_argv[i++] = "-p";
    ssh_argv[i++] = (char *)port;
  }
  /* One string. ssh joins argv with spaces and the remote shell parses it.
     An unquoted -c script would be only the first word, which is `export`
     and prints the environment. */
  {
    size_t used = 0;
    const char *prefix = "bash --noprofile --norc -c '";
    const char *s;
    size_t n = strlen(prefix);
    if (n + 2 >= sizeof remote_cmd) {
      return -1;
    }
    memcpy(remote_cmd, prefix, n);
    used = n;
    for (s = cmd; *s; s++) {
      if (*s == '\'') {
        if (used + 6 >= sizeof remote_cmd) {
          return -1;
        }
        memcpy(remote_cmd + used, "'\\''", 4);
        used += 4;
      } else {
        if (used + 3 >= sizeof remote_cmd) {
          return -1;
        }
        remote_cmd[used++] = *s;
      }
    }
    remote_cmd[used++] = '\'';
    remote_cmd[used] = '\0';
  }
  ssh_argv[i++] = (char *)target;
  ssh_argv[i++] = remote_cmd;
  ssh_argv[i++] = NULL;
  return 0;
}

static int forward_exec(const char *file, char *const argv[], char *const envp[]) {
  if (build_cmd(file, argv, envp) != 0 || build_ssh_argv() != 0) {
    errno = E2BIG;
    return -1;
  }
  return real_execve("/usr/bin/ssh", ssh_argv, build_clean_env(envp));
}

static int forward_spawn(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                         const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
  if (build_cmd(file, argv, envp) != 0 || build_ssh_argv() != 0) {
    return E2BIG;
  }
  return real_posix_spawn(pid, "/usr/bin/ssh", fa, attr, ssh_argv, build_clean_env(envp));
}


#define DYLD_INTERPOSE(_replacement, _replacee)                                            \
  __attribute__((used)) static struct {                                                    \
    const void *replacement;                                                               \
    const void *replacee;                                                                  \
  } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {              \
      (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee}

int rw_execve(const char *file, char *const argv[], char *const envp[]) {
  const char *why;
  if (init_reals() != 0) {
    errno = ENOSYS;
    return -1;
  }
  why = pass_reason(file);
  log_line(why ? why : "forward", file, argv);
  if (why) {
    return real_execve(file, argv, envp);
  }
  return forward_exec(file, argv, envp);
}

int rw_execv(const char *file, char *const argv[]) {
  return rw_execve(file, argv, environ);
}

int rw_execvp(const char *file, char *const argv[]) {
  const char *why;
  if (init_reals() != 0) {
    errno = ENOSYS;
    return -1;
  }
  why = pass_reason(file);
  log_line(why ? why : "forward", file, argv);
  if (why) {
    char resolved[4096];
    if (resolve_path(file, resolved, sizeof resolved) != 0) {
      errno = ENOENT;
      return -1;
    }
    return real_execve(resolved, argv, environ);
  }
  return forward_exec(file, argv, environ);
}

static int collect_args(va_list ap, const char *arg0) {
  int i = 0;
  var_argv[i++] = (char *)arg0;
  for (;;) {
    char *a;
    if (i >= 255) {
      return -1;
    }
    a = va_arg(ap, char *);
    var_argv[i++] = a;
    if (!a) {
      return 0;
    }
  }
}

int rw_execl(const char *path, const char *arg, ...) {
  va_list ap;
  va_start(ap, arg);
  if (collect_args(ap, arg) != 0) {
    va_end(ap);
    errno = E2BIG;
    return -1;
  }
  va_end(ap);
  return rw_execve(path, var_argv, environ);
}

int rw_execlp(const char *file, const char *arg, ...) {
  va_list ap;
  va_start(ap, arg);
  if (collect_args(ap, arg) != 0) {
    va_end(ap);
    errno = E2BIG;
    return -1;
  }
  va_end(ap);
  return rw_execvp(file, var_argv);
}

int rw_execle(const char *path, const char *arg, ...) {
  va_list ap;
  char *const *envp;
  va_start(ap, arg);
  if (collect_args(ap, arg) != 0) {
    va_end(ap);
    errno = E2BIG;
    return -1;
  }
  envp = va_arg(ap, char *const *);
  va_end(ap);
  return rw_execve(path, var_argv, envp);
}

int rw_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                   const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
  const char *why;
  if (init_reals() != 0) {
    return ENOSYS;
  }
  why = pass_reason(path);
  log_line(why ? why : "forward-spawn", path, argv);
  if (why) {
    return real_posix_spawn(pid, path, fa, attr, argv, envp);
  }
  return forward_spawn(pid, path, fa, attr, argv, envp);
}

int rw_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                    const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
  const char *why;
  if (init_reals() != 0) {
    return ENOSYS;
  }
  why = pass_reason(file);
  log_line(why ? why : "forward-spawn", file, argv);
  if (why) {
    char resolved[4096];
    if (resolve_path(file, resolved, sizeof resolved) != 0) {
      return ENOENT;
    }
    return real_posix_spawn(pid, resolved, fa, attr, argv, envp);
  }
  return forward_spawn(pid, file, fa, attr, argv, envp);
}

DYLD_INTERPOSE(rw_execve, execve);
DYLD_INTERPOSE(rw_execv, execv);
DYLD_INTERPOSE(rw_execvp, execvp);
DYLD_INTERPOSE(rw_execl, execl);
DYLD_INTERPOSE(rw_execlp, execlp);
DYLD_INTERPOSE(rw_execle, execle);
DYLD_INTERPOSE(rw_posix_spawn, posix_spawn);
DYLD_INTERPOSE(rw_posix_spawnp, posix_spawnp);

static void ctor(void) __attribute__((constructor));
static void ctor(void) {
  init_reals();
  log_line("loaded", "ctor", NULL);
}
