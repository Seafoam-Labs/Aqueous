// SPDX-License-Identifier: GPL-3.0-only
// Bootstrap only: no input data enters this module. Slow service-manager queries
// run in one bounded worker, never on the compositor's input/event thread.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <systemd/sd-bus.h>
#include <systemd/sd-login.h>
#ifndef SO_PEERPIDFD
#define SO_PEERPIDFD 77
#endif

struct bootstrap {
    int listener, peer, peer_pidfd, capability, owner_pidfd;
    pid_t peer_pid, owner_pid;
    char path[108], ipc[108], unit[80], launcher[PATH_MAX];
    pthread_t worker;
    bool working, consumed;
    atomic_bool done;
    bool verified;
    int64_t expires, next_accept;
#ifdef AQUEOUS_ACTIVITY_TESTING
    pid_t test_pid;
#endif
};
static int64_t now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static bool alive(int fd) {
    struct pollfd p = {.fd = fd, .events = POLLIN};
    return fd >= 0 && poll(&p, 1, 0) == 0;
}
static bool same_file(int a, int b) {
    struct stat x, y;
    return a >= 0 && b >= 0 && fstat(a, &x) == 0 && fstat(b, &y) == 0 &&
        x.st_dev == y.st_dev && x.st_ino == y.st_ino;
}
static bool peer_environment(struct bootstrap *b) {
    char path[64], buf[131072], expected[160];
    snprintf(path, sizeof(path), "/proc/%d/environ", b->peer_pid);
    snprintf(expected, sizeof(expected), "AQUEOUS_SOCKET=%s", b->ipc);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    ssize_t n = read(fd, buf, sizeof(buf));
    close(fd);
    if (n <= 0 || n == sizeof(buf) || buf[n-1] != 0) return false;
    bool found = false;
    for (size_t i = 0; i < (size_t)n; i += strlen(buf+i) + 1) {
        if (!strncmp(buf+i, "AQUEOUS_SOCKET=", 15)) {
            if (found || strcmp(buf+i, expected)) return false;
            found = true;
        }
    }
    return found;
}
static bool verify(struct bootstrap *b) {
    if (!alive(b->peer_pidfd) || !peer_environment(b)) return false;
#ifdef AQUEOUS_ACTIVITY_TESTING
    if (b->test_pid > 0 && b->peer_pid == b->test_pid) return true;
#endif
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/exe", b->peer_pid);
    int exe = open(path, O_PATH | O_CLOEXEC);
    int wrapper = open(b->launcher, O_PATH | O_CLOEXEC);
    bool matches = same_file(exe, wrapper);
    if (exe >= 0) close(exe);
    if (wrapper >= 0) close(wrapper);
    if (!matches) return false;
    char *unit = NULL;
    if (sd_pidfd_get_user_unit(b->peer_pidfd, &unit) < 0) return false;
    matches = !strcmp(unit, b->unit);
    free(unit);
    if (!matches) return false;
    sd_bus *bus = NULL;
    sd_bus_message *reply = NULL;
    bool allowed = false;
    if (sd_bus_open_user(&bus) < 0) goto out;
    sd_bus_set_method_call_timeout(bus, 500000);
    if (sd_bus_call_method(bus, "org.freedesktop.systemd1", "/org/freedesktop/systemd1",
            "org.freedesktop.systemd1.Manager", "GetUnit", NULL, &reply, "s", b->unit) < 0) goto out;
    const char *unit_path;
    if (sd_bus_message_read(reply, "o", &unit_path) < 0) goto out;
    uint32_t main_pid = 0;
    if (sd_bus_get_property_trivial(bus, "org.freedesktop.systemd1", unit_path,
            "org.freedesktop.systemd1.Service", "MainPID", NULL, 'u', &main_pid) < 0) goto out;
    allowed = main_pid == (uint32_t)b->peer_pid && alive(b->peer_pidfd);
out:
    sd_bus_message_unref(reply);
    sd_bus_unref(bus);
    return allowed;
}
static void *worker(void *data) {
    struct bootstrap *b = data;
    b->verified = verify(b);
    atomic_store_explicit(&b->done, true, memory_order_release);
    return NULL;
}
static void clear_peer(struct bootstrap *b) {
    if (b->peer >= 0) close(b->peer);
    if (b->peer_pidfd >= 0) close(b->peer_pidfd);
    b->peer = b->peer_pidfd = -1;
}
static void clear_owner(struct bootstrap *b) {
    if (b->capability >= 0) close(b->capability);
    if (b->owner_pidfd >= 0) close(b->owner_pidfd);
    b->capability = b->owner_pidfd = -1;
    b->owner_pid = 0;
    b->consumed = false;
}
void *aq_activity_bootstrap_create(const char *ipc, const char *unit) {
    struct bootstrap *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    atomic_init(&b->done, false);
    b->listener = b->peer = b->peer_pidfd = b->capability = b->owner_pidfd = -1;
    if (strlen(ipc) >= sizeof(b->ipc) || strlen(unit) >= sizeof(b->unit)) goto fail;
    strcpy(b->ipc, ipc);
    strcpy(b->path, ipc);
    char *slash = strrchr(b->path, '/');
    if (!slash || (size_t)(slash-b->path) + sizeof("/activity.sock") > sizeof(b->path)) goto fail;
    strcpy(slash, "/activity.sock");
    strcpy(b->unit, unit);
    ssize_t n = readlink("/proc/self/exe", b->launcher, sizeof(b->launcher)-1);
    if (n < 0) goto fail;
    b->launcher[n] = 0;
    slash = strrchr(b->launcher, '/');
    if (!slash || (size_t)(slash-b->launcher) + sizeof("/aqueous-activity-launch") > sizeof(b->launcher)) goto fail;
    strcpy(slash, "/aqueous-activity-launch");
    b->listener = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (b->listener < 0) goto fail;
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strcpy(addr.sun_path, b->path);
    // The parent is the existing exclusive per-instance IPC directory. Never
    // unlink an existing endpoint belonging to another compositor.
    if (bind(b->listener, (void *)&addr, sizeof(addr)) < 0) goto fail;
    if (chmod(b->path, 0600) < 0 || listen(b->listener, 4) < 0) {
        unlink(b->path);
        goto fail;
    }
    return b;
fail:
    if (b->listener >= 0) close(b->listener);
    free(b);
    return NULL;
}
void aq_activity_bootstrap_destroy(void *data) {
    struct bootstrap *b = data;
    if (!b) return;
    if (b->working) pthread_join(b->worker, NULL);
    clear_peer(b);
    clear_owner(b);
    close(b->listener);
    unlink(b->path);
    free(b);
}
static bool send_capability(int peer, int fd) {
    char byte = 1;
    struct iovec iov = {.iov_base = &byte, .iov_len = 1};
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof(control)};
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(fd));
    return sendmsg(peer, &msg, MSG_NOSIGNAL | MSG_DONTWAIT) == 1;
}
void aq_activity_bootstrap_tick(void *data) {
    struct bootstrap *b = data;
    if (!b) return;
    const int64_t now = now_ms();
    if (b->owner_pid && (!alive(b->owner_pidfd) || (!b->consumed && now >= b->expires))) clear_owner(b);
    if (b->working) {
        if (!atomic_load_explicit(&b->done, memory_order_acquire)) return;
        pthread_join(b->worker, NULL);
        b->working = false;
        if (b->verified && !b->owner_pid && alive(b->peer_pidfd)) {
            int fd = memfd_create("aqueous-activity", MFD_CLOEXEC | MFD_ALLOW_SEALING);
            const int seals = F_SEAL_SEAL | F_SEAL_WRITE | F_SEAL_SHRINK | F_SEAL_GROW;
            if (fd >= 0 && fcntl(fd, F_ADD_SEALS, seals) == 0 && send_capability(b->peer, fd)) {
                b->capability = fd;
                b->owner_pid = b->peer_pid;
                b->owner_pidfd = b->peer_pidfd;
                b->peer_pidfd = -1;
                b->expires = now + 10000;
            } else if (fd >= 0) close(fd);
        }
        clear_peer(b);
    }
    if (now < b->next_accept) return;
    b->next_accept = now + 250;
    int fd = accept4(b->listener, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0) return;
    if (b->owner_pid) { close(fd); return; }
    struct ucred cred;
    socklen_t len = sizeof(cred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) < 0 || len != sizeof(cred) || cred.uid != getuid()) { close(fd); return; }
    int pidfd = -1;
    len = sizeof(pidfd);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERPIDFD, &pidfd, &len) < 0 || len != sizeof(pidfd)) { close(fd); return; }
    fcntl(pidfd, F_SETFD, FD_CLOEXEC);
    b->peer = fd;
    b->peer_pidfd = pidfd;
    b->peer_pid = cred.pid;
    atomic_store(&b->done, false);
    if (pthread_create(&b->worker, NULL, worker, b) != 0) clear_peer(b);
    else b->working = true;
}
bool aq_activity_claim(void *data, int fd, int pid) {
    struct bootstrap *b = data;
    if (!b || b->consumed || pid != b->owner_pid || now_ms() >= b->expires ||
        !alive(b->owner_pidfd) || !same_file(fd, b->capability)) return false;
    b->consumed = true;
    close(b->capability);
    b->capability = -1;
    return true;
}
bool aq_activity_owner_alive(void *data) {
    struct bootstrap *b = data;
    return b && b->consumed && alive(b->owner_pidfd);
}
void aq_activity_revoke(void *data) {
    struct bootstrap *b = data;
    if (b) clear_owner(b);
}
#ifdef AQUEOUS_ACTIVITY_TESTING
void aq_activity_test_owner(void *data, int pid) {
    struct bootstrap *b = data;
    if (b) b->test_pid = pid;
}
#endif
