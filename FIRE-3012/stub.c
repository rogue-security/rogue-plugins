#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
int main(int argc, char **argv) {
  char buf[4096]; size_t n, total = 0;
  while ((n = fread(buf, 1, sizeof buf, stdin)) > 0) total += n;
  const char *home = getenv("HOME");
  char path[PATH_MAX]; snprintf(path, sizeof path, "%s/.rogue-spike-3012/calls.log", home ? home : ".");
  FILE *f = fopen(path, "a"); if (!f) return 0;
  char cmd[64], parent[256] = ""; snprintf(cmd, sizeof cmd, "ps -o command= -p %d", (int)getppid());
  FILE *p = popen(cmd, "r"); if (p) { if (!fgets(parent, sizeof parent, p)) parent[0] = 0; pclose(p); }
  parent[strcspn(parent, "\n")] = 0;
  fprintf(f, "argv0=%s args=", argv[0]);
  for (int i = 1; i < argc; i++) fprintf(f, "[%s]", argv[i]);
  fprintf(f, " stdin_bytes=%zu parent=%s\n", total, parent);
  fclose(f); fputs("{}", stdout); return 0;
}
