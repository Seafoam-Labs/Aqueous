import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("welcome_setup", Path(__file__).resolve().parents[1] / "src/setup.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class Isolated(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="aqueous-welcome-test-")
        self.root = Path(self.tmp.name)
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.root / "home"), "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_STATE_HOME": str(self.root / "state"), "XDG_RUNTIME_DIR": str(self.root / "runtime"),
            "XDG_CURRENT_DESKTOP": "Aqueous", "WAYLAND_DISPLAY": "private-test",
            "AQUEOUS_NESTED": "0", "AQUEOUS_SHARE_DIR": str(self.root / "share"),
        })
        self.environment.start()
        self.executables = patch.object(setup.shutil, "which", return_value="/fixture/bin/shell")
        self.executables.start()

    def tearDown(self):
        self.executables.stop()
        self.environment.stop()
        self.tmp.cleanup()


class ProtocolTests(Isolated):
    def test_fragmented_frames_and_malformed_data(self):
        decoder = setup.Frames()
        event = {"$kind": "alpm.info", "EventType": "TransactionDone"}
        encoded = b"diagnostic noise" + setup.frame(event)
        actual = []
        for byte in encoded:
            actual += decoder.feed(bytes([byte]))
        self.assertEqual(actual, [event])
        with self.assertRaises(setup.SetupError):
            decoder.feed(b"[JSON]not base64[/JSON]")

    def test_all_optional_dependencies_use_supplied_indices(self):
        question = {"QuestionId": "67", "Options": [
            {"Index": 7}, {"Index": 19, "IsInstalled": True}, {"Index": 42, "IsSelected": False}]}
        self.assertEqual(setup.optional_answer(question), {
            "$kind": "a.optdeps", "QuestionId": "67", "SelectedIndices": [7, 42]})
        self.assertEqual(setup.optional_answer({"QuestionId": "68", "Options": []})["SelectedIndices"], [])

    def fixture(self, body):
        script = self.root / "shelly"
        script.write_text('''#!/usr/bin/env python3
import base64, json, os, sys, termios
def emit(value):
    data = b'[JSON]' + base64.b64encode(json.dumps(value).encode()) + b'[/JSON]\\n'
    # Fragment frames to exercise the actual streaming transport.
    for i in range(0, len(data), 9):
        os.write(1, data[i:i+9])
def answer():
    line = sys.stdin.buffer.readline()
    return json.loads(base64.b64decode(line[6:line.index(b'[/JSON]')]))
''' + body)
        script.chmod(0o755)
        return str(script)

    def test_real_child_password_and_package_questions_use_separate_channels(self):
        executable = self.fixture('''
tty = os.open('/dev/tty', os.O_RDWR)
assert not termios.tcgetattr(tty)[3] & termios.ECHO
for attempt in range(2):
    os.write(tty, b'[sudo] password for test: ')
    assert os.read(tty, 4096) == b'fixture-secret\\n'
    os.write(tty, b'\\n')
for number in ['1', '2']:
    emit({'$kind': 'q.optdeps', 'QuestionId': number, 'Options': [
        {'Index': 0, 'IsInstalled': False}, {'Index': 1, 'IsInstalled': True}, {'Index': 2}]})
    assert answer() == {'$kind':'a.optdeps','QuestionId':number,'SelectedIndices':[0,2]}
emit({'$kind':'q.transaction','QuestionId':'3', 'QuestionText':'Install packages?'})
assert answer() == {'$kind':'a.transaction','QuestionId':'3','Accept':True}
os.write(2, b'x' * 100000)  # Must be drained while the UI waits.
emit({'$kind':'alpm.info','EventType':'TransactionDone','Message':'Installed'})
os.close(tty)
''')
        r, w = os.pipe()
        events = []
        def respond(kind, **event):
            events.append((kind, event))
            if kind == "password":
                os.write(w, (json.dumps({"id": event["id"], "password": "fixture-secret"}) + "\n").encode())
            if kind == "question":
                os.write(w, (json.dumps({"id": event["id"], "accept": True}) + "\n").encode())
        try:
            setup.install([executable, "install", "standard", "pearl-de", "--ui-mode"], respond, r)
        finally:
            os.close(r); os.close(w)
        self.assertEqual(sum(kind == "password" for kind, _ in events), 2)
        self.assertNotIn("fixture-secret", json.dumps(events))

    def test_cancelled_zero_exit_is_not_success(self):
        executable = self.fixture("emit({'$kind':'alpm.info','EventType':'TransactionCancelled'})\n")
        r, w = os.pipe()
        try:
            with self.assertRaises(setup.Cancelled):
                setup.install([executable], lambda *a, **kw: None, r)
        finally:
            os.close(r); os.close(w)

    def test_exit_zero_without_transaction_done_is_not_success(self):
        executable = self.fixture("emit({'$kind':'alpm.progress','Percent':100})\n")
        r, w = os.pipe()
        try:
            with self.assertRaises(setup.SetupError):
                setup.install([executable], lambda *a, **kw: None, r)
        finally:
            os.close(r); os.close(w)

    def test_cancel_during_commit_finishes_transaction_and_skips_configuration(self):
        executable = self.fixture("""
import time
emit({'$kind':'alpm.info','Message':'Committing'})
time.sleep(.1)
emit({'$kind':'alpm.info','EventType':'TransactionDone'})
""")
        r, w = os.pipe()
        def cancel(kind, **event):
            if event.get("message") == "Committing":
                os.write(w, b'{"cancel":true}\n')
        try:
            with self.assertRaises(setup.Cancelled):
                setup.install([executable], cancel, r)
        finally:
            os.close(r); os.close(w)


class SessionTests(Isolated):
    def test_every_transition_preserves_active_session_until_next_login(self):
        for old in setup.SHELLS:
            for new in setup.SHELLS:
                with self.subTest(old=old, new=new):
                    path = setup.config_home() / "aqueous/session.toml"
                    setup.atomic(path, f'version=1\nshell="{old}"\n'.encode())
                    setup.prepare_session()
                    setup.atomic(path, f'version=1\nshell="{new}"\n'.encode())
                    self.assertEqual(setup.active_selection(), old)
                    self.assertEqual([s for s in setup.SHELLS if setup.condition(s) == 0], [old])
                    setup.prepare_session()
                    self.assertEqual(setup.active_selection(), new)
        self.assertEqual(setup.condition("dms", external=True), 1)
        with patch.dict(os.environ, XDG_CURRENT_DESKTOP="GNOME"):
            self.assertEqual(setup.condition("dms", external=True), 0)
            self.assertEqual(setup.condition("dms"), 1)

    def test_missing_selection_and_nested_session(self):
        self.assertEqual(setup.selection(), "none")
        with patch.dict(os.environ, AQUEOUS_NESTED="1"):
            setup.prepare_session()
            self.assertFalse(setup.runtime_file().exists())
            for shell in setup.SHELLS:
                self.assertEqual(setup.condition(shell), 1)

    def test_noctalia_defaults_only_for_selected_shell_and_never_overwritten(self):
        source = self.root / "share/noctalia/config.toml"
        setup.atomic(source, b"[bar]\n")
        setup.prepare_session()
        destination = setup.config_home() / "noctalia/config.toml"
        self.assertFalse(destination.exists())
        setup.atomic(setup.config_home() / "aqueous/session.toml", b'version=1\nshell="noctalia"\n')
        setup.prepare_session()
        self.assertEqual(destination.read_bytes(), b"[bar]\n")
        setup.atomic(destination, b"# custom\n")
        setup.prepare_session()
        self.assertEqual(destination.read_bytes(), b"# custom\n")

    def test_completion_keeps_existing_marker_contract(self):
        setup.complete()
        self.assertTrue((setup.state_home() / "welcome-v1").exists())
        self.assertIn("Hidden=true", (setup.config_home() / "autostart/org.aqueous.Welcome.desktop").read_text())

    def test_journal_recovers_interrupted_writes_and_refuses_concurrent_edits(self):
        path = setup.config_home() / "aqueous/session.toml"
        setup.atomic(path, b'version=1\nshell="dms"\n')
        journal = setup.Journal()
        journal.write(path, b'version=1\nshell="pearl"\n')
        setup.Journal().recover()
        self.assertEqual(setup.selection(), "dms")
        journal = setup.Journal()
        journal.write(path, b'version=1\nshell="pearl"\n')
        setup.atomic(path, b'version=1\nshell="noctalia"\n')
        with self.assertRaises(setup.SetupError):
            setup.Journal().recover()
        self.assertEqual(setup.selection(), "noctalia")

    def test_custom_actions_are_preserved(self):
        request, preserved = setup.configuration_request({"generation":"g", "fields":[
            {"id":"actions.toggle_start_menu","value":"my-launcher"},
            {"id":"actions.screenshot","value":"dms screenshot region"}]})
        self.assertEqual(preserved, ["actions.toggle_start_menu"])
        self.assertEqual(request["changes"], [{"id":"actions.screenshot","value":"aqueous-shell-action screenshot"}])

    def test_legacy_direct_shortcuts_follow_active_shell(self):
        request, _ = setup.configuration_request({"generation": "g", "fields": [], "custom_keybinds": [
            {"id": "old", "chord": "Super+Shift+S", "command": "spawn:dms screenshot region"},
            {"id": "custom", "chord": "Super+P", "command": "spawn:custom-capture"}]})
        self.assertEqual(request["custom_keybind_changes"], [{"id": "old", "op": "update",
                         "chord": "Super+Shift+S", "command": "spawn:aqueous-shell-action screenshot"}])

    def test_portal_update_preserves_comments_and_respects_custom_override(self):
        path = setup.config_home() / "xdg-desktop-portal-aqueous/Aqueous"
        setup.atomic(path, b'# my portal\n[screencast]\nmax_fps=30\nchooser_cmd=noctalia dmenu -p "Select a source to share:"\n')
        changed_path, data, note = setup.portal_change()
        self.assertEqual(changed_path, path)
        self.assertIsNone(note)
        self.assertIn(b"# my portal", data)
        self.assertIn(b"max_fps=30", data)
        self.assertIn(b"chooser_cmd=aqueous-shell-action chooser", data)
        setup.atomic(path, b"[screencast]\nchooser_cmd=my-custom-picker\n")
        _, data, note = setup.portal_change()
        self.assertIsNone(data)
        self.assertIn("Keep custom", note)

    def test_missing_shell_opens_recovery_without_starting_another_shell(self):
        setup.atomic(setup.config_home() / "aqueous/session.toml", b'version=1\nshell="pearl"\n')
        with patch.object(setup.shutil, "which", return_value=None), patch.object(setup.subprocess, "Popen") as launch:
            setup.prepare_session()
        self.assertEqual(setup.active_selection(), "none")
        self.assertEqual(setup.selection(), "pearl")
        self.assertEqual(launch.call_args.args[0][:2], ["aqueous-welcome", "--message"])

    def test_nothing_completes_without_shelly(self):
        snapshot = {"generation":"g", "fields":[], "raw_files":{}}
        with patch.object(setup, "helper", return_value=snapshot), patch.object(setup, "reply", return_value={"accept":True}), \
             patch.object(setup, "installed", side_effect=AssertionError("Nothing queried Shelly")), \
             patch.object(setup, "install", side_effect=AssertionError("Nothing installed packages")), patch.object(setup, "emit"):
            setup.setup("none", [])
        self.assertEqual(setup.selection(), "none")
        self.assertTrue((setup.state_home() / "welcome-v1").exists())

    def test_failed_install_keeps_selection_and_does_not_complete(self):
        setup.atomic(setup.config_home() / "aqueous/session.toml", b'version=1\nshell="dms"\n')
        snapshot = {"generation":"g", "fields":[], "raw_files":{}, "capabilities":list(setup.PEARL_CAPS)}
        with patch.object(setup, "helper", return_value=snapshot), patch.object(setup, "reply", return_value={"accept":True}), \
             patch.object(setup, "installed", return_value=set()), patch.object(setup, "emit"), \
             patch.object(setup, "install", side_effect=setup.SetupError("offline")) as installer:
            with self.assertRaises(setup.SetupError):
                setup.setup("pearl", [])
        self.assertEqual(installer.call_args.args[0], ["shelly", "install", "standard", "pearl-de", "--ui-mode"])
        self.assertEqual(setup.selection(), "dms")
        self.assertFalse((setup.state_home() / "welcome-v1").exists())


if __name__ == "__main__":
    unittest.main()
