#!/usr/bin/env python3
"""Test complete production DRM ownership functions using mocked KMS and real FDs."""
import argparse
import os
from pathlib import Path
import resource
import runpy
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('prefix', type=Path)
parser.add_argument('--no-negative-controls', action='store_true',
                    help='Run only the regressions, e.g. against the source before the fixes')
args = parser.parse_args()
source, prefix = args.source, args.prefix
function = runpy.run_path(str(Path(__file__).with_name('test-vulkan-sync.py')))['function']
atomic = (source / 'backend/drm/atomic.c').read_text()
production = '\n'.join(function(atomic, name) for name in [
    'create_mode_blob', 'create_gamma_lut_blob', 'create_fb_damage_clips_blob',
    'convert_cta861_eotf', 'convert_cta861_color_coord', 'create_hdr_output_metadata_blob',
    'convert_primaries_to_colorspace', 'destroy_blob', 'commit_blob', 'rollback_blob', 'drm_atomic_connector_prepare',
    'drm_atomic_connector_apply_commit', 'drm_atomic_connector_rollback_commit',
    'atomic_device_commit',
])
production = function((source / 'render/color.c').read_text(), 'color_transform_lut_3x1d_from_base') + production
env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'),
           LD_LIBRARY_PATH=str(prefix / 'lib'))
flags = shlex.split(subprocess.check_output([
    'pkg-config', '--cflags', '--libs', 'wlroots-0.20', 'libdrm', 'wayland-server', 'pixman-1'], env=env, text=True))
merger = (source / 'render/drm_syncobj_merger.c').read_text()
surface = (source / 'types/wlr_linux_drm_syncobj_v1.c').read_text()
def structure(text, name):
    start = text.index('struct ' + name + ' {')
    end = text.index('\n};', start) + 3
    return text[start:end] + '\n'
syncobj = structure(surface, 'wlr_linux_drm_syncobj_surface_v1')
syncobj += structure(merger, 'export_waiter')
syncobj += '\n'.join(function(merger, name) for name in [
    'sync_file_merge', 'wlr_drm_syncobj_merger_create', 'wlr_drm_syncobj_merger_ref',
    'merger_log_failure', 'merger_wait_point', 'merger_wait_sync_file',
    'wlr_drm_syncobj_merger_unref', 'merger_add_exportable', 'export_waiter_handle_ready',
    'wlr_drm_syncobj_merger_add'])
syncobj += '\n'.join(function(surface, name) for name in [
    'surface_synced_finish_state', 'surface_synced_move_state', 'surface_synced_commit',
    'wlr_linux_drm_syncobj_v1_state_add_release_point'])
syncobj += function((source / 'types/scene/surface.c').read_text(), 'handle_scene_buffer_output_sample')
scene = (source / 'types/scene/wlr_scene.c').read_text()
syncobj += structure(scene, 'render_list_entry')
syncobj += '\n'.join(function(scene, name) for name in [
    'scene_entry_prepare_release', 'scene_render_list_submit'])
# Verify the tested submission boundary is wired into the real scene builder.
entry = function(scene, 'scene_entry_render')
assert entry.index('scene_entry_prepare_release(') < entry.index('wlr_render_pass_add_texture(')
assert '.release_deferred = true' in entry
build = function(scene, 'wlr_scene_output_build_state')
assert 'scene_render_list_submit(render_pass, list_data, list_len, scene_output)' in build
assert 'wlr_render_pass_submit(' not in build
timeline = (source / 'render/drm_syncobj.c').read_text()
errors = '\n'.join(function(timeline, name) for name in [
    'wlr_drm_syncobj_timeline_export_sync_file', 'wlr_drm_syncobj_timeline_import_sync_file',
    'wlr_drm_syncobj_timeline_check', 'wlr_drm_syncobj_timeline_signal',
    'wlr_drm_syncobj_timeline_waiter_init'])
with tempfile.TemporaryDirectory(prefix='aqueous-drm-sync-') as tmp:
    tmp = Path(tmp)
    for fixture, header, code in [('drm-sync', 'drm-sync-functions.h', production),
                                   ('syncobj-errors', 'syncobj-errors.h', errors),
                                   ('syncobj-lifetime', 'syncobj-functions.h', syncobj)]:
        (tmp / header).write_text(code)
        variants = [('plain', code, False), ('asan', code, True)]
        if args.no_negative_controls:
            pass
        elif fixture == 'syncobj-errors':
            assert 'errno = error;' in code
            variants.append(('lost-original-error', code.replace('errno = error;', '(void)error;'), False))
        elif fixture == 'drm-sync':
            # Restore the lost-local-FD defect independently of blob cleanup.
            old = 'state->primary_in_fence_fd = wlr_drm_syncobj_timeline_export_sync_file('
            assert code.count(old) == 1
            broken = code.replace(old, 'int leaked_fence = wlr_drm_syncobj_timeline_export_sync_file(')
            broken = broken.replace('if (state->primary_in_fence_fd < 0)', 'if (leaked_fence < 0)')
            variants.append(('lost-fence', broken, False))
        else:
            old = 'flags, loop, export_waiter_handle_ready)) {\n\t\tfree(add);'
            assert code.count(old) == 1
            variants.append(('lost-waiter', code.replace(old, old.replace('\n\t\tfree(add);', '')), True))
            mutations = {
                'drop-earlier-fence': ('return merger_wait_point(merger, src_timeline, src_point);\n\t\t}',
                    'close(merger->sync_fd); merger->sync_fd = -1;\n\t\t\treturn merger_wait_point(merger, src_timeline, src_point);\n\t\t}'),
                'availability-as-completion': ('DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT, NULL);',
                    'DRM_SYNCOBJ_WAIT_FLAGS_WAIT_AVAILABLE, NULL);'),
                'ignored-publication': ('if (!published && merger_wait_sync_file(merger->sync_fd))',
                    'if (!published && (merger_wait_sync_file(merger->sync_fd), true))'),
                'ignored-deferred-failure': ('bool ok = !merger->failed && merger_add_exportable(merger, add->src_timeline, add->src_point);',
                    'bool ok = (merger_add_exportable(merger, add->src_timeline, add->src_point), true); merger->failed = false;'),
                'ignored-scene-failure': ('event->release_timeline, event->release_point, output->event_loop)) {',
                    'event->release_timeline, event->release_point, output->event_loop) && false) {'),
                'pre-submit-release': ('!event->release_deferred) {', 'true) {'),
                'lost-generation-ref': ('entry->release_merger = wlr_drm_syncobj_merger_ref(state->release_merger);',
                    'entry->release_merger = state->release_merger;'),
                'wait-rejected-frame': ('if (submitted || !vulkan) {', 'if (true) {'),
                'missing-submitted-release': ('if (submitted || !vulkan) {', 'if (!submitted || !vulkan) {'),
            }
            for label, (old, new) in mutations.items():
                assert code.count(old) == 1, label
                variants.append((label, code.replace(old, new), False))
        for label, variant, sanitizer in variants:
            (tmp / header).write_text(variant)
            binary = tmp / (fixture + '-' + label)
            subprocess.run(['cc', '-std=c11', '-D_POSIX_C_SOURCE=200809L', '-DWLR_USE_UNSTABLE',
                '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-g',
                *(['-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-no-pie'] if sanitizer else []),
                '-I' + str(source / 'include'), '-I' + str(tmp),
                str(Path(__file__).parent / ('fixtures/' + fixture + '.c')), *flags, '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True, env=env,
                           preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
            if label == 'lost-fence':
                assert result.returncode == -6 and 'fd_count() == baseline' in result.stderr, result.stderr
                print('PASS: negative control rejected (lost input fence)')
            elif label == 'lost-waiter':
                assert result.returncode != 0 and 'LeakSanitizer: detected memory leaks' in result.stderr and 'wlr_drm_syncobj_merger_add' in result.stderr, result.stderr
                print('PASS: negative control rejected (lost waiter allocation)')
            elif label not in ('plain', 'asan'):
                assert result.returncode == -6 and 'Assertion' in result.stderr, result.stderr
                print(f'PASS: negative control rejected ({label})')
            else:
                if result.returncode:
                    raise RuntimeError(result.stdout + result.stderr)
                print(result.stdout.strip())
print('PASS: DRM synchronization production functions (plain + ASan/UBSan)')
