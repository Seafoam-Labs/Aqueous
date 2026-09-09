#include <sys/inotify.h>
#include <unistd.h>
#include <errno.h>
int aq_theme_watch_open(void) { return inotify_init1(IN_NONBLOCK | IN_CLOEXEC); }
void aq_theme_watch_add(int fd, const char *parent) {
    if (fd >= 0) (void)inotify_add_watch(fd, parent, IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF);
}
int aq_theme_watch_changed(int fd) {
    if (fd < 0) return 0;
    char buffer[4096]; int changed = 0;
    for (;;) {
        ssize_t size = read(fd, buffer, sizeof buffer);
        if (size > 0) { changed = 1; continue; }
        if (size < 0 && errno == EINTR) continue;
        return changed;
    }
}
