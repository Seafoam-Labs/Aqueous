// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

/* All file access happens after fork. Keep the validated open file as stdin
 * and use its procfs name so a replacement path cannot become a FIFO/device.
 * The child is supervised from the Wayland loop; never wait for audio there. */
int aqueous_bell_spawn(const char *path, const char *volume) {
    /* Build the environment before fork; do not call malloc/setenv in a child
     * that may inherit locks held by renderer/library threads. */
    extern char **environ;
    size_t count = 0;
    while (environ[count]) ++count;
    char **env = calloc(count + 2, sizeof(char *));
    if (!env) return -1;
    size_t n = 0;
    for (size_t i = 0; i < count; ++i)
        if (strncmp(environ[i], "LC_ALL=", 7) != 0) env[n++] = environ[i];
    env[n] = "LC_ALL=C";
    pid_t pid = fork();
    if (pid != 0) { free(env); return pid; }
    if (setsid() < 0) _exit(126);
    sigset_t mask;
    sigemptyset(&mask);
    sigprocmask(SIG_SETMASK, &mask, NULL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) _exit(126);
    if (dup2(fd, STDIN_FILENO) < 0) _exit(126);
    if (fd != STDIN_FILENO) close(fd);
    int null = open("/dev/null", O_WRONLY);
    if (null < 0 || dup2(null, STDOUT_FILENO) < 0 || dup2(null, STDERR_FILENO) < 0) _exit(126);
    if (null > STDERR_FILENO) close(null);
    /* The compositor already uses Linux APIs and procfs. */
    if (close_range(3, ~0U, 0) < 0) {
        struct rlimit limit;
        if (getrlimit(RLIMIT_NOFILE, &limit) < 0) _exit(126);
        for (rlim_t i = 3; i < limit.rlim_cur; ++i) close((int)i);
    }
    char *const argv[] = {"pw-play", "--media-role=Notification", "--volume", (char *)volume, "/proc/self/fd/0", NULL};
    execvpe(argv[0], argv, env);
    _exit(127);
}

/* 0 = running, 1 = success, -1 = failed/already reaped. Only this PID is owned. */
int aqueous_bell_poll(int pid) {
    int status;
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == 0 || (result < 0 && errno == EINTR)) return 0;
    if (result < 0) return -1;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 1 : -1;
}

void aqueous_bell_signal(int pid, int force) {
    /* Use the owned unreaped PID, never a recycled process-group ID. */
    kill(pid, force ? SIGKILL : SIGTERM);
}

void aqueous_bell_finish(int pid) {
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}
