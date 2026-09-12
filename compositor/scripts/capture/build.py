#!/usr/bin/env python3
"""Build isolated capture probes and instrument pinned sources, never installed packages."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import urllib.request

HERE = Path(__file__).resolve().parent
COMPOSITOR = HERE.parents[1]
REPO = COMPOSITOR.parent
PORTAL_SHA = '3122966d46ab108f505525bcb2498f9121b446ee8438fbfceb73a7a1fa1ad400'
WLROOTS_SHA = '972c7ac44b17828f4702bfae7cd8347346a3fb5b2c1076cfa2c3fcedac5ec343'


def run(cmd, **kw):
    subprocess.run(list(map(str, cmd)), check=True, **kw)


def extract(archive, target, digest):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError(f'Unexpected archive hash: {archive}')
    target.mkdir(parents=True)
    with tarfile.open(archive) as tar:
        # Archive hashes are pinned; still reject traversal and escaping links.
        tar.extractall(target, filter='data')
    entries = list(target.iterdir())
    if len(entries) != 1 or not entries[0].is_dir():
        raise RuntimeError('Expected one archive root')
    return entries[0]


class Instrument:
    def __init__(self, source, unit):
        self.source, self.unit, self.originals = source, unit, {}
        shutil.copyfile(HERE / 'trace.h', source / 'capture-trace.h')

    def edit(self, path, old, new, count=1):
        p = self.source / path
        s = p.read_text()
        self.originals.setdefault(path, s)
        actual = s.count(old)
        if actual != count:
            raise RuntimeError(f'{path}: expected {count} copies of {old!r}, found {actual}')
        p.write_text(s.replace(old, new))

    def header(self, path, unit):
        p = self.source / path
        s = p.read_text()
        self.originals.setdefault(path, s)
        p.write_text(f'#define CAPTURE_TRACE_UNIT "{unit}"\n#include "capture-trace.h"\n' + s)

    def save(self, path):
        text = ''.join(''.join(difflib.unified_diff(before.splitlines(True),
            (self.source / name).read_text().splitlines(True),
            fromfile=f'a/{name}', tofile=f'b/{name}')) for name, before in self.originals.items())
        path.write_text(text)


def instrument_portal(source, patch):
    i = Instrument(source, 'portal')
    p = 'src/screencast/pipewire_screencast.c'
    i.header(p, 'portal-pipewire')
    i.edit(p, 'if (!cast->avoid_dmabufs) {',
           'if (!cast->avoid_dmabufs && !capture_flag("AQUEOUS_CAPTURE_FORCE_SHM")) {', 2)
    i.edit(p, 'logprint(WARN, "pipewire: out of buffers");',
           'capture_trace("dequeue_empty", (uintptr_t)cast, 0, 0, 0);\n\t\tlogprint(WARN, "pipewire: out of buffers");')
    i.edit(p, 'cast->current_frame.completed = false;',
           'cast->current_frame.completed = false;\n\tcapture_trace("dequeue", (uintptr_t)cast, (uintptr_t)cast->current_frame.pw_buffer, cast->current_frame.pw_buffer->buffer->datas[0].fd, 0);')
    i.edit(p, 'pw_stream_queue_buffer(cast->stream, pw_buf);', '''if (capture_flag("AQUEOUS_CAPTURE_FULL_METADATA") || capture_flag("AQUEOUS_CAPTURE_BAD_METADATA")) {
        struct spa_meta *m = spa_buffer_find_meta(spa_buf, SPA_META_VideoDamage);
        if (m && m->size >= sizeof(struct spa_region)) {
            memset(m->data, 0, m->size);
            if (!capture_flag("AQUEOUS_CAPTURE_BAD_METADATA"))
                *(struct spa_region *)m->data = SPA_REGION(0, 0, cast->pwr_format.size.width, cast->pwr_format.size.height);
        }
    }
    capture_trace("queue", (uintptr_t)cast, (uintptr_t)pw_buf, d[0].fd, buffer_corrupt);
    pw_stream_queue_buffer(cast->stream, pw_buf);''')
    i.edit(p, 'logprint(DEBUG, "pipewire: add buffer event handle");',
           'capture_trace("add_buffer", (uintptr_t)cast, (uintptr_t)buffer, 0, 0);\n\tlogprint(DEBUG, "pipewire: add buffer event handle");')
    i.edit(p, 'logprint(DEBUG, "pipewire: remove buffer event handle");',
           'capture_trace("remove_buffer", (uintptr_t)cast, (uintptr_t)buffer, 0, 0);\n\tlogprint(DEBUG, "pipewire: remove buffer event handle");')
    p = 'src/screencast/ext_image_copy.c'
    i.header(p, 'portal-ext')
    i.edit(p, 'logprint(TRACE, "ext: ready event handler");',
           'capture_trace("capture_ready", (uintptr_t)cast, (uintptr_t)cast->current_frame.pw_buffer, 0, 0);\n\tlogprint(TRACE, "ext: ready event handler");')
    i.edit(p, 'ext_image_copy_capture_frame_v1_capture(cast->ext_session.frame);',
           'capture_trace("capture_request", (uintptr_t)cast, (uintptr_t)cast->current_frame.pw_buffer, 0, 0);\n\text_image_copy_capture_frame_v1_capture(cast->ext_session.frame);')
    i.save(patch)


def instrument_wlroots(source, patch):
    i = Instrument(source, 'wlroots')
    p = 'types/wlr_ext_image_copy_capture_v1.c'
    i.header(p, 'compositor-copy')
    helpers = '''
#include <wlr/render/vulkan.h>
#include <vulkan/vulkan.h>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <poll.h>
static void capture_wait(struct wlr_renderer *renderer, const char *flag) {
    if (!capture_flag(flag) || !wlr_renderer_is_vk(renderer)) return;
    VkDevice device = wlr_vk_renderer_get_device(renderer);
    VkQueue queue;
    vkGetDeviceQueue(device, wlr_vk_renderer_get_queue_family(renderer), 0, &queue);
    uint64_t begin = capture_now();
    VkResult result = vkQueueWaitIdle(queue);
    capture_trace(flag, (uintptr_t)renderer, 0, result, capture_now() - begin);
}
static void capture_fence(struct wlr_buffer *buffer, const char *event) {
    if (!getenv("AQUEOUS_CAPTURE_TRACE_DIR")) return;
    struct wlr_dmabuf_attributes attrs;
    if (!wlr_buffer_get_dmabuf(buffer, &attrs)) return;
    struct dma_buf_export_sync_file sync = {.flags = DMA_BUF_SYNC_READ, .fd = -1};
    int result = ioctl(attrs.fd[0], DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &sync);
    int signaled = -1;
    if (result == 0) {
        struct pollfd p = {.fd = sync.fd, .events = POLLIN};
        signaled = poll(&p, 1, 0) > 0 && (p.revents & POLLIN);
        close(sync.fd);
    }
    capture_trace(event, (uintptr_t)buffer, 0, attrs.fd[0], signaled);
}
'''
    i.edit(p, '#define IMAGE_COPY_CAPTURE_MANAGER_V1_VERSION 1', helpers + '\n#define IMAGE_COPY_CAPTURE_MANAGER_V1_VERSION 1')
    i.edit(p, 'struct wlr_buffer *dst = frame->buffer;', '''struct wlr_buffer *dst = frame->buffer;
    capture_trace("copy_begin", (uintptr_t)src, (uintptr_t)dst, src->width, src->height);
    capture_fence(src, "source_fence");
    capture_wait(renderer, "AQUEOUS_CAPTURE_WAIT_SOURCE");''')
    i.edit(p, 'copy_dmabuf(dst, src, renderer, &frame->buffer_damage)',
           'copy_dmabuf(dst, src, renderer, capture_flag("AQUEOUS_CAPTURE_FULL_COPY") ? NULL : &frame->buffer_damage)')
    i.edit(p, 'capture_color_send(frame, shm ? (converted ? &sdr : description) : NULL);', '''capture_wait(renderer, "AQUEOUS_CAPTURE_WAIT_COPY");
    capture_fence(dst, "copy_fence");
    capture_trace("copy_submitted", (uintptr_t)src, (uintptr_t)dst, shm, 0);
    capture_color_send(frame, shm ? (converted ? &sdr : description) : NULL);''')
    i.edit(p, 'ext_image_copy_capture_frame_v1_send_ready(frame->resource);',
           'capture_trace("frame_ready", (uintptr_t)frame, (uintptr_t)frame->buffer, 0, 0);\n\text_image_copy_capture_frame_v1_send_ready(frame->resource);')
    p = 'types/ext_image_capture_source_v1/output.c'
    i.header(p, 'compositor-output')
    i.edit(p, '#include <wlr/types/wlr_output.h>', '#include <wlr/types/wlr_output.h>\n#include <wlr/types/wlr_output_layer.h>')
    i.edit(p, 'wlr_output_lock_attach_render(source->output, true);',
           'wlr_output_lock_attach_render(source->output, true);\n\tcapture_trace("capture_start", (uintptr_t)source->output, 0, source->num_started, 0);')
    i.edit(p, 'wlr_output_lock_attach_render(source->output, false);',
           'wlr_output_lock_attach_render(source->output, false);\n\tcapture_trace("capture_stop", (uintptr_t)source->output, 0, source->num_started, 0);')
    i.edit(p, 'struct wlr_buffer *buffer = event->state->buffer;', '''struct wlr_buffer *buffer = event->state->buffer;
        capture_trace("output_commit", (uintptr_t)source->output, (uintptr_t)buffer, source->output->commit_seq, event->state->layers_len);
        for (size_t j = 0; j < event->state->layers_len; j++)
            capture_trace("committed_layer", (uintptr_t)source->output, (uintptr_t)event->state->layers[j].buffer, event->state->layers[j].accepted, source->output->commit_seq);''')
    p = 'types/scene/wlr_scene.c'
    i.header(p, 'compositor-scene')
    i.edit(p, 'scanout_result = scene_entry_try_direct_scanout(&list_data[0], state, &render_data);',
           'scanout_result = scene_entry_try_direct_scanout(&list_data[0], state, &render_data);\n\t\tcapture_trace("scanout_result", (uintptr_t)scene_output->output, (uintptr_t)state->buffer, scanout_result, 0);')
    i.save(patch)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--stage', choices=['probes', 'portal', 'wlroots', 'all'], default='all')
    ap.add_argument('--portal-archive', type=Path)
    ap.add_argument('--wlroots-archive', type=Path, default=COMPOSITOR / '.deps/downloads/wlroots-0.20.2.tar.gz')
    ap.add_argument('--unrenamed', action='store_true')
    args = ap.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    if args.stage in ('probes', 'all'):
        proto = Path(subprocess.check_output(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip()) / 'stable/xdg-shell/xdg-shell.xml'
        run(['wayland-scanner', 'client-header', proto, out / 'xdg-shell-client-protocol.h'])
        run(['wayland-scanner', 'private-code', proto, out / 'xdg-shell.c'])
        for name, packages, extra in [('fixture', ['wayland-client', 'wayland-egl', 'egl', 'glesv2'], [out / 'xdg-shell.c']),
                                      ('consumer', ['libpipewire-0.3', 'egl', 'glesv2', 'gbm', 'libdrm'], []),
                                      ('check-pattern', [], [])]:
            flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', *packages], text=True).split() if packages else []
            run(['cc', '-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror', f'-I{out}',
                 HERE / f'{name}.c', *extra, *flags, '-o', out / name])
    if args.stage in ('portal', 'all'):
        archive = args.portal_archive or out / 'portal.tar.gz'
        if not archive.exists():
            urllib.request.urlretrieve('https://codeload.github.com/emersion/xdg-desktop-portal-wlr/tar.gz/refs/tags/v0.8.4', archive)
        src = extract(archive, out / 'portal-source', PORTAL_SHA)
        if not args.unrenamed:
            run(['patch', '--fuzz=0', '-p1', '-i', REPO / 'packaging/portal/0001-rename-backend-for-aqueous.patch'], cwd=src)
        instrument_portal(src, out / 'portal-diagnostics.patch')
        run(['meson', 'setup', out / 'portal-build', src, '-Dsystemd=disabled', '-Dman-pages=disabled', '--sysconfdir=/etc'])
        run(['meson', 'compile', '-C', out / 'portal-build'])
        name = 'xdg-desktop-portal-wlr' if args.unrenamed else 'xdg-desktop-portal-aqueous'
        shutil.copy2(out / 'portal-build' / name, out / 'portal')
    if args.stage in ('wlroots', 'all'):
        src = extract(args.wlroots_archive, out / 'wlroots-source', WLROOTS_SHA)
        build_script = (COMPOSITOR / 'scripts/build-wlroots-render-hook.sh').read_text()
        for name in re.findall(r'\$here/patches/wlroots/([^"\n]+)', build_script):
            # Match the repository's production builder; existing patches rely
            # on context fuzz after earlier patches in this pinned series.
            run(['patch', '-p1', '-i', COMPOSITOR / 'patches/wlroots' / name], cwd=src)
        instrument_wlroots(src, out / 'wlroots-diagnostics.patch')
        run(['meson', 'setup', out / 'wlroots-build', src, '--prefix', out / 'wlroots', '--libdir=lib',
             '-Dexamples=false', '-Dbackends=drm,libinput,x11', '-Drenderers=vulkan', '-Dxwayland=enabled',
             '-Dallocators=gbm', '-Dsession=enabled', '-Dlibliftoff=enabled', '-Dcolor-management=enabled'])
        run(['meson', 'compile', '-C', out / 'wlroots-build'])
        run(['meson', 'install', '-C', out / 'wlroots-build'])
    manifest = out / f'build-{args.stage}.json'
    manifest.write_text(json.dumps({'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
        'portal_sha256': PORTAL_SHA, 'wlroots_sha256': WLROOTS_SHA, 'unrenamed': args.unrenamed,
        'stage': args.stage, 'patch_hashes': {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [REPO / 'packaging/portal/0001-rename-backend-for-aqueous.patch', *sorted((COMPOSITOR / 'patches/wlroots').glob('*.patch'))]},
        'source_hashes': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in HERE.glob('*') if p.is_file()}}, indent=2) + '\n')


if __name__ == '__main__':
    main()
