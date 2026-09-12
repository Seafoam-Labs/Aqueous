// Test-only bounded, mmap-backed traces. No production source includes this file.
#ifndef CAPTURE_TRACE_H
#define CAPTURE_TRACE_H
#define _GNU_SOURCE
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#ifndef CAPTURE_TRACE_UNIT
#define CAPTURE_TRACE_UNIT "probe"
#endif
static inline uint64_t capture_now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}
static inline int capture_flag(const char *key) {
    const char *s = getenv(key);
    return s && *s && strcmp(s, "0") && strcmp(s, "false");
}
// Each record occupies a complete line, even if the process is terminated.
// The last slot records overflow. A truncated trace can never establish a pass.
static inline void capture_trace(const char *event, uintptr_t a, uintptr_t b, int64_t c,
                                 int64_t d) {
    enum { SLOT = 384, COUNT = 32768 };
    static char *map;
    static unsigned count;
    static int initialized;
    if (!initialized) {
        initialized = 1;
        const char *dir = getenv("AQUEOUS_CAPTURE_TRACE_DIR");
        if (!dir)
            return;
        char path[4096];
        snprintf(path, sizeof(path), "%s/%s-%ld.jsonl", dir, CAPTURE_TRACE_UNIT, (long)getpid());
        int fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd < 0) {
            perror(path);
            return;
        }
        if (ftruncate(fd, SLOT * COUNT) == 0) {
            void *p = mmap(NULL, SLOT * COUNT, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (p != MAP_FAILED)
                map = p;
        }
        close(fd);
    }
    if (!map)
        return;
    unsigned index = count < COUNT - 1 ? count : COUNT - 1;
    char line[SLOT];
    memset(line, ' ', sizeof(line));
    int n =
        snprintf(line, sizeof(line),
                 "{\"event\":\"%s\",\"ns\":%" PRIu64 ",\"seq\":%u,\"a\":%" PRIuPTR
                 ",\"b\":%" PRIuPTR ",\"c\":%" PRId64 ",\"d\":%" PRId64 "}",
                 count < COUNT - 1 ? event : "trace_overflow", capture_now(), count, a, b, c, d);
    if (n > 0 && n < SLOT - 1)
        line[n] = ' ';
    line[SLOT - 1] = '\n';
    memcpy(map + index * SLOT, line, SLOT);
    count++;
}
#endif
