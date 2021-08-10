#define _GNU_SOURCE

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

void __attribute__((noreturn)) die(char *msg)
{
  fprintf(stderr, "%s\n", msg);
  exit(1);
}

void die_with_usage() { die("usage: riju-pty CMDLINE..."); }

struct termios orig_termios;

void restore_termios() { tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_termios); }

int main(int argc, char **argv)
{
  if (argc <= 1)
    die_with_usage();
  int pty_master_fd = posix_openpt(O_RDWR);
  if (pty_master_fd < 0)
    die("posix_openpt failed");
  if (grantpt(pty_master_fd) < 0)
    die("grantpt failed");
  if (unlockpt(pty_master_fd) < 0)
    die("unlockpt failed");
  char *pty_slave_name = ptsname(pty_master_fd);
  if (pty_slave_name == NULL)
    die("ptsname failed");
  pid_t exec_pid = fork();
  if (exec_pid < 0)
    die("fork failed");
  else if (exec_pid == 0) {
    close(pty_master_fd);
    int pty_slave_fd = open(pty_slave_name, O_RDWR);
    if (pty_slave_fd < 0)
      die("open failed");
    if (dup2(pty_slave_fd, STDIN_FILENO) < 0)
      die("dup2 failed");
    if (dup2(pty_slave_fd, STDOUT_FILENO) < 0)
      die("dup2 failed");
    if (dup2(pty_slave_fd, STDERR_FILENO) < 0)
      die("dup2 failed");
    if (close(pty_slave_fd) < 0)
      die("close failed");
    execvp(argv[1], &argv[1]);
    die("execvp failed");
  }
  char buf[1024];
  int len, len_written;
  int pid = fork();
  if (pid < 0)
    die("fork failed");
  else if (pid == 0) {
    if (tcgetattr(STDIN_FILENO, &orig_termios) < 0)
      die("tcgetattr failed");
    if (atexit(restore_termios) != 0)
      die("atexit failed");
    struct termios raw = orig_termios;
    // https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
    raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= ~(OPOST);
    raw.c_cflag |= (CS8);
    raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) < 0)
      die("tcsetattr failed");
    while ((len = read(STDIN_FILENO, buf, 1024)) > 0) {
      char *ptr = buf;
      while (len > 0) {
        if (*ptr == '\x03') {
          if (kill(exec_pid, SIGINT) < 0)
            die("kill failed");
          len -= 1;
          ptr += 1;
          continue;
        }
        int limit = len;
        for (int idx = 0; idx < len; ++idx) {
          if (buf[idx] == '\x03') {
            limit = idx;
            break;
          }
        }
        len_written = write(pty_master_fd, ptr, limit);
        if (len_written < 0)
          die("write failed");
        len -= len_written;
        ptr += len_written;
      }
    }
  } else {
    if (setvbuf(stdout, NULL, _IONBF, 0) != 0)
      die("setvbuf failed");
    while ((len = read(pty_master_fd, buf, 1024)) > 0) {
      fwrite(buf, 1, len, stdout);
      if (ferror(stdout))
        die("fwrite failed");
      if (feof(stdout))
        break;
    }
  }
  return 0;
}
