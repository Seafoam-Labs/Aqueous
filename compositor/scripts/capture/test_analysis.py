#!/usr/bin/env python3
"""Exercise the evidence classifier against missing evidence and ownership faults."""
import json
from pathlib import Path
import tempfile
import unittest
import run


class Analysis(unittest.TestCase):
    def classify(self, extra=(), summary=None, backend='headless'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'trace').mkdir()
            events = ['client_commit', 'copy_begin', 'frame_ready', 'queue', 'acquire', 'read_complete', 'release']
            rows = [dict(event=e, ns=i, seq=i, a=1, b=2, c=0, d=0) for i, e in enumerate(events)]
            rows.extend(dict(event=e, ns=10+i, seq=10+i, a=1, b=2, c=2, d=0) for i,e in enumerate(extra))
            (root / 'trace/consumer-1.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
            s = dict(frames=100, metadata_seen=100, transport='dmabuf', failed=False)
            s.update(summary or {})
            return run.analyze(root, s, backend, 'test')

    def test_headless_never_proves_drm_planes(self):
        r = self.classify(['scanout_result'])
        self.assertEqual(r['statuses']['planes'], 'not exercised')

    def test_overflow_cannot_pass(self):
        r = self.classify(['trace_overflow'])
        self.assertTrue(r['trace_incomplete'])
        self.assertEqual(r['statuses']['damage'], 'inconclusive')

    def test_duplicate_acquire_is_ownership_error(self):
        r = self.classify(['acquire', 'acquire'])
        self.assertEqual(len(r['ownership_errors']), 1)
        self.assertEqual(r['statuses']['scheduling'], 'inconclusive')

    def test_unrecovered_starvation_is_not_clean(self):
        r = self.classify(['dequeue_empty'])
        self.assertEqual(r['starvation_recovery_ns'], [None])
        self.assertEqual(r['statuses']['scheduling'], 'inconclusive')

    def test_corruption_is_not_automatic_root_cause(self):
        r = self.classify(summary={'bad_frames': 1})
        self.assertTrue(r['unexpected_pixels'])
        self.assertEqual(r['statuses']['synchronization'], 'inconclusive')

    def test_stalled_fixture_does_not_pass(self):
        r = self.classify(summary={'tail_gap_ns': 1_000_000_000})
        self.assertEqual(r['statuses']['damage'], 'inconclusive')

    def test_shm_does_not_cover_dmabuf_sync(self):
        self.assertEqual(self.classify(summary={'transport': 'shm'})['statuses']['synchronization'], 'not exercised')

    def test_missing_trace_does_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'trace').mkdir()
            r=run.analyze(root,dict(frames=100,metadata_seen=100,transport='dmabuf'), 'drm','test')
            self.assertTrue(r['trace_incomplete'])
            self.assertEqual(r['statuses']['synchronization'], 'inconclusive')


if __name__ == '__main__':
    unittest.main()
