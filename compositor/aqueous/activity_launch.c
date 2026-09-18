// SPDX-License-Identifier: GPL-3.0-only
// Service MainPID stays unchanged across exec. Failure only disables activity.
#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
static int capability(void) {
    const char *ipc = getenv("AQUEOUS_SOCKET");
    if (!ipc || strlen(ipc) >= 108) return -1;
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strcpy(addr.sun_path, ipc);
    char *slash = strrchr(addr.sun_path, '/');
    if (!slash || (size_t)(slash-addr.sun_path) + sizeof("/activity.sock") > sizeof(addr.sun_path)) return -1;
    strcpy(slash, "/activity.sock");
    int sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (sock < 0) return -1;
    int result = -1;
    if (connect(sock, (void *)&addr, sizeof(addr)) < 0) goto out;
    struct pollfd p = {.fd = sock, .events = POLLIN};
    if (poll(&p, 1, 2500) <= 0) goto out;
    char byte = 0;
    struct iovec iov = {.iov_base = &byte, .iov_len = 1};
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof(control)};
    if (recvmsg(sock, &msg, MSG_CMSG_CLOEXEC) != 1) goto out;
    unsigned received = 0;
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS || cmsg->cmsg_len < CMSG_LEN(0)) continue;
        size_t count = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t i = 0; i < count; ++i) {
            int fd;
            memcpy(&fd, (char *)CMSG_DATA(cmsg) + i * sizeof(fd), sizeof(fd));
            if (received++ == 0) result = fd;
            else close(fd);
        }
    }
    if (byte != 1 || received != 1 || (msg.msg_flags & (MSG_CTRUNC | MSG_TRUNC))) {
        if (result >= 0) close(result);
        result = -1;
    }
out:
    close(sock);
    return result;
}
int main(int argc, char **argv) {
    if (argc < 2 || argv[1][0] != '/') {
        fputs("usage: aqueous-activity-launch /absolute/shell [arguments...]\n", stderr);
        return 2;
    }
    unsetenv("AQUEOUS_INPUT_ACTIVITY_FD");
    int fd = capability();
    if (fd >= 0) {
        char value[32];
        snprintf(value, sizeof(value), "%d", fd);
        if (setenv("AQUEOUS_INPUT_ACTIVITY_FD", value, 1) < 0 || fcntl(fd, F_SETFD, 0) < 0) {
            close(fd);
            unsetenv("AQUEOUS_INPUT_ACTIVITY_FD");
        }
    }
    execv(argv[1], argv+1);
    perror("aqueous-activity-launch: exec");
    return 1;
}
