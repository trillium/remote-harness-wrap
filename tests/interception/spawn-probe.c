#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
  pid_t pid;
  int rc;
  int st = 1;
  if (argc < 2) {
    fprintf(stderr, "usage: spawn-probe command [args...]\n");
    return 2;
  }
  rc = posix_spawnp(&pid, argv[1], NULL, NULL, &argv[1], environ);
  if (rc != 0) {
    fprintf(stderr, "spawn-rc=%d\n", rc);
    return 1;
  }
  if (waitpid(pid, &st, 0) < 0) {
    return 1;
  }
  if (WIFEXITED(st)) {
    return WEXITSTATUS(st);
  }
  if (WIFSIGNALED(st)) {
    return 128 + WTERMSIG(st);
  }
  return 1;
}
