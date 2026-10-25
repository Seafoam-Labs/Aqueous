#!/usr/bin/env python3
"""Instrument a private patched wlroots tree, or summarize its fence ownership log.

This is local diagnostic tooling, not a production patch or an FD sweeper.
"""
import argparse
from collections import Counter
import difflib
import json
from pathlib import Path
import re

HEADER = r'''#ifndef AQUEOUS_SYNC_FD_TRACE_H
#define AQUEOUS_SYNC_FD_TRACE_H
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <wlr/render/drm_syncobj.h>
#include "render/dmabuf.h"
static inline int aq_trace_fd(const char *event, int fd, const char *site, int line) {
    int saved_errno = errno;
    if (fd >= 0 && getenv("AQUEOUS_TRACE_SYNC_FDS")) {
        fprintf(stderr, "AQ_SYNC_FD pid=%ld event=%s fd=%d site=%s:%d\n",
            (long)getpid(), event, fd, site, line);
    }
    errno = saved_errno;
    return fd;
}
static inline int aq_trace_close(int fd, const char *site, int line) {
    int result = close(fd);
    if (result == 0) aq_trace_fd("close", fd, site, line);
    return result;
}
#define close(fd) aq_trace_close((fd), __FILE__, __LINE__)
#define wlr_drm_syncobj_timeline_export_sync_file(t, p) \
    aq_trace_fd("export", wlr_drm_syncobj_timeline_export_sync_file((t), (p)), __FILE__, __LINE__)
#define dmabuf_export_sync_file(fd, flags) \
    aq_trace_fd("export", dmabuf_export_sync_file((fd), (flags)), __FILE__, __LINE__)
#endif
'''


def instrument(source):
    paths = ['render/vulkan/pass.c', 'render/vulkan/renderer.c',
             'backend/drm/atomic.c', 'backend/drm/drm.c', 'render/drm_syncobj_merger.c']
    before = {p: (source / p).read_text() for p in paths}
    after = dict(before)

    def edit(path, old, new):
        if after[path].count(old) != 1:
            raise RuntimeError(f'Instrumentation anchor changed: {path}: {old}')
        after[path] = after[path].replace(old, new)

    edit('render/vulkan/pass.c', '\n\treturn *sem_ptr;',
         '\n\taq_trace_fd("transfer-vulkan", sync_file_fd, __FILE__, __LINE__);\n\treturn *sem_ptr;')
    edit('render/vulkan/renderer.c', '\n\tif (sync_file_fd == -1) {',
         '\n\taq_trace_fd("export", sync_file_fd, __FILE__, __LINE__);\n\tif (sync_file_fd == -1) {')
    edit('render/vulkan/renderer.c', '\n\t\t\tif (fd >= 0) close(fd);',
         '\n\t\t\taq_trace_fd("export", fd, __FILE__, __LINE__);\n\t\t\tif (fd >= 0) close(fd);')
    edit('render/drm_syncobj_merger.c', '\n\treturn merge_data.fence;',
         '\n\treturn aq_trace_fd("export", merge_data.fence, __FILE__, __LINE__);')
    for p in paths:
        if 'aqueous-sync-fd-trace.h' in before[p]:
            raise RuntimeError(f'Already instrumented: {p}')
        after[p] = '#include "util/aqueous-sync-fd-trace.h"\n' + after[p]
    # Validate every anchor before mutating anything. Caller supplies a private
    # reconstructed tree; no installed binaries or repository patches are edited.
    (source / 'include/util/aqueous-sync-fd-trace.h').write_text(HEADER)
    patch = ''.join(difflib.unified_diff([], HEADER.splitlines(True),
                 fromfile='/dev/null', tofile='b/include/util/aqueous-sync-fd-trace.h'))
    for p in paths:
        (source / p).write_text(after[p])
        patch += ''.join(difflib.unified_diff(before[p].splitlines(True), after[p].splitlines(True),
                                            fromfile='a/' + p, tofile='b/' + p))
    (source / 'aqueous-sync-fd-trace.patch').write_text(patch)
    print(f'Instrumented {source}; enable with AQUEOUS_TRACE_SYNC_FDS=1. Patch saved in that tree.')


def summarize(lines):
    live, overwritten, transfers = {}, [], 0
    pattern = re.compile(r'AQ_SYNC_FD pid=(\d+) event=([\w-]+) fd=(\d+) site=(\S+)')
    for line in lines:
        match = pattern.search(line)
        if not match:
            continue
        pid, event, fd, site = match.groups()
        key = (int(pid), int(fd))
        if event == 'export':
            if key in live:
                overwritten.append({'pid': key[0], 'fd': key[1], 'previous_site': live[key], 'site': site})
            live[key] = site
        elif event in ('close', 'transfer-vulkan'):
            live.pop(key, None)
            transfers += event == 'transfer-vulkan'
    return {'unmatched_exports': [{'pid': p, 'fd': fd, 'site': site} for (p, fd), site in sorted(live.items())],
            'by_allocation_site': dict(Counter(live.values())),
            'successful_vulkan_transfers': transfers, 'reused_without_observed_release': overwritten}


def snapshot(pid):
    proc = Path('/proc') / str(pid)
    counts = Counter()
    for path in (proc / 'fd').iterdir():
        try:
            target = path.readlink().as_posix()
        except FileNotFoundError:
            continue
        counts['sync_file' if target == 'anon_inode:sync_file' else 'other'] += 1
    memory = [line for line in (proc / 'status').read_text().splitlines()
              if line.startswith(('VmRSS:', 'VmData:', 'RssAnon:'))]
    return {'pid': pid, 'descriptors': dict(counts), 'memory_separate_from_fds': memory}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--instrument', type=Path, metavar='PRIVATE_PATCHED_SOURCE')
    group.add_argument('--report', type=Path, metavar='LOG')
    group.add_argument('--snapshot', type=int, metavar='LOCAL_PID')
    args = parser.parse_args()
    if args.instrument:
        instrument(args.instrument)
    elif args.report:
        print(json.dumps(summarize(args.report.open()), indent=2))
    else:
        print(json.dumps(snapshot(args.snapshot), indent=2))


if __name__ == '__main__':
    main()
