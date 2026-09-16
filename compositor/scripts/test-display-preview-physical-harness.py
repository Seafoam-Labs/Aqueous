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


class FeatureGroups(unittest.TestCase):
    def test_transitions_are_bidirectional(self):
        for group in harness.GROUPS[1:]:
            self.assertNotEqual(harness.group_fields(group), harness.group_fields(group, False))
            self.assertEqual(harness.transition_cases(group)['transition-off'], harness.group_fields(group, False))
        self.assertEqual(harness.group_fields('auto_hdr', False), {'hdr':True, 'auto_hdr':False})

    def test_combined_and_auto_hdr_have_independent_cases(self):
        self.assertIn('hdr-off-vrr-on', harness.transition_cases('hdr_vrr'))
        self.assertIn('vrr-off-hdr-on', harness.transition_cases('hdr_vrr'))
        self.assertEqual(harness.transition_cases('auto_hdr')['auto-boost-zero'], {'auto_hdr_boost':0})
        self.assertEqual(harness.transition_cases('auto_hdr')['auto-boost-full'], {'auto_hdr_boost':1})

    def test_requirements_match_the_group(self):
        self.assertNotIn('visual-hdr', harness.required_cases('sdr'))
        self.assertNotIn('panel-vrr', harness.required_cases('auto_hdr'))
        self.assertIn('combined-across-heads', harness.required_cases('hdr_vrr'))
        self.assertIn('auto-boost-full', harness.required_cases('auto_hdr'))
        self.assertNotIn('unsupported-mode', harness.required_cases('sdr', simulate=True))

    def test_summary_never_counts_unsupported_or_unrun_as_passed(self):
        cases = {value:{'status':value} for value in ('passed','failed','unsupported','not_run')}
        self.assertEqual(harness.summarize(cases), {value:[value] for value in cases})


if __name__ == '__main__':
    unittest.main()
