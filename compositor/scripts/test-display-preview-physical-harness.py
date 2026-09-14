#!/usr/bin/env python3
"""Check physical harness admission without accessing devices or starting a session."""
import argparse
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('physical_preview', Path(__file__).with_name('test-display-preview-physical.py'))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class Admission(unittest.TestCase):
    def options(self, **changes):
        return argparse.Namespace(**(dict(dedicated_seat=True, recovery_console=True,
                                          drm_device=Path('/dev/dri/card1'), connector=['DP-1']) | changes))

    def test_requires_dedicated_seat_and_recovery_console(self):
        for field in ('dedicated_seat', 'recovery_console'):
            with self.assertRaises(ValueError):
                harness.prerequisites(self.options(**{field: False}), {})

    def test_refuses_existing_graphical_session(self):
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET'):
            with self.assertRaises(ValueError):
                harness.prerequisites(self.options(), {key: 'active'})

    def test_exact_card_and_connector_selection(self):
        harness.prerequisites(self.options(), {})
        for changes in ({'connector': []}, {'connector': ['*']}, {'connector': ['DP-1,DP-2']},
                        {'drm_device': Path('/dev/dri/renderD128')}, {'drm_device': Path('card1')}):
            with self.assertRaises(ValueError):
                harness.prerequisites(self.options(**changes), {})


if __name__ == '__main__':
    unittest.main()
