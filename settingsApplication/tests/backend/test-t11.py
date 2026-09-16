#!/usr/bin/env python3
"""Isolated contract tests; run under dbus-run-session. No installed session use."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HELPER = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out/bin/aqueous-config"

with tempfile.TemporaryDirectory(prefix="aqueous-t11-") as scratch:
    tmp = Path(scratch)
    cfg = tmp / "config/aqueous"
    cfg.mkdir(parents=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("AQUEOUS_", "NOCTALIA_"))}
    env.update(HOME=str(tmp / "home"), XDG_CONFIG_HOME=str(tmp / "config"),
               XDG_STATE_HOME=str(tmp / "state"), XDG_RUNTIME_DIR=str(tmp / "runtime"),
               WAYLAND_DISPLAY="absent-test-compositor", DISPLAY="", GSETTINGS_BACKEND="memory",
               XCURSOR_PATH=str(tmp / "icons"), PATH=str(tmp / "bin") + ":" + os.environ["PATH"])
    for name in ("home", "runtime", "bin", "icons"):
        (tmp / name).mkdir(mode=0o700)
    # Deterministic isolated reload acknowledgement producer; no session socket.
    ctl = tmp / "bin/aqueousctl"
    ctl.write_text('#!/bin/sh\nif [ "$1" = outputs ]; then echo "[]"; else echo \'{"ok":true,"status":"applied","sequence":"7"}\'; fi\n')
    ctl.chmod(0o755)
    for name in ("wm", "layout", "input", "outputs", "rules", "appearance"):
        (cfg / f"{name}.toml").write_text("")
        env["AQUEOUS_CONFIG" if name == "wm" else "AQUEOUS_" + name.upper()] = str(cfg / f"{name}.toml")

    def run(command, request=None, *flags, ok=True):
        args = [str(HELPER), command, "--shell", "none", *flags]
        if request is not None:
            args += ["--request", "-"]
        proc = subprocess.run(args, input=json.dumps(request) if request is not None else None,
                              text=True, capture_output=True, env=env, timeout=35)
        result = json.loads(proc.stdout)
        if ok:
            assert proc.returncode == 0 and result["ok"], (proc.stderr, result)
        return result

    version = run("version")
    assert version["protocol"] == 1 and version["version"] == "0.8.3"
    assert not {"display_preview_v1"} & set(version["capabilities"])
    initial = run("snapshot")
    assert initial["display_model"]["version"] == 2
    assert initial["display_model"]["live"] == initial["display_observation"]
    assert "monitors" in initial and "live_outputs" in initial and "raw_files" in initial
    all_fields = '''[display]
apply_on_start = false
apply_on_reload = true
fallback_profile = "offline"
identify_by = "edid"
rollback_seconds = 15
[[output]]
name = "DP-*"
enabled = false
mirror_of = ""
edid = "duplicate"
mode = "1920x1080@59.94"
scale = 1.25
transform = "flipped-90"
position = [-1920, 0]
adaptive_sync = false
hdr = false
hdr_level = "1000"
sdr_white_level = 120
auto_hdr = false
auto_hdr_boost = 0.5
primary = false
future_output_key = "preserved"
[[display.profile]]
name = "offline"
[[display.profile.output]]
name = "missing"
hdr = true
'''
    req = {"protocol": 1, "expected_generation": initial["generation"], "raw_files": {"outputs": all_fields}}
    projected = run("validate", req)
    source = projected["display_configuration"]["parsed_sources"]["outputs"]
    spec = source["outputs"][0]
    assert spec["enabled"] is False and spec["primary"] is False and spec["mirror_of"] == ""
    assert spec["mode"] == {"width": 1920, "height": 1080, "refresh_mhz": 59940}
    assert spec["position"] == [-1920, 0] and spec["hdr_level"] == "l1000"
    assert source["profiles"][0]["outputs"][0]["enabled"] is None
    assert source["policy"]["rollback_seconds"] == 15
    assert projected["display_configuration"]["effective_policy"]["rollback_seconds"]["crash_safe_lease"] is False
    assert any(e["key"] == "future_output_key" for d in projected["display_declarations"] for e in d["entries"])
    review = projected["candidate_review"]
    assert review["original_generation"] == initial["generation"] and len(review["candidate_digest"]) == 64
    assert review["effects"] == ["unknown"] and not review["complete"] and not review["protected_apply"]
    assert run("snapshot")["raw_files"]["outputs"] == ""  # validation is read-only
    applied = run("apply", req, "--result", "v1")
    assert applied["save"] == "saved" and applied["reload"] == "applied" and applied["receipt"] == "unavailable"
    assert applied["candidate_digest"] == review["candidate_digest"]
    snap = run("snapshot")
    comment = {"protocol": 1, "expected_generation": snap["generation"], "raw_files": {"outputs": "# [[output]] hdr = true\n" + all_fields}}
    comment_review = run("validate", comment)["candidate_review"]
    assert comment_review["effects"] == ["none"] and comment_review["complete"]
    assert comment_review["candidate_digest"] != review["candidate_digest"]
    # Include a non-display file in the digest even for an otherwise equal plan.
    combined = dict(comment, raw_files={**comment["raw_files"], "wm": "[blur]\nenabled = false\n"})
    assert run("validate", combined)["candidate_review"]["candidate_digest"] != comment_review["candidate_digest"]
    # The legacy apply shape and reload diagnostic remain intact.
    old = run("apply", comment, "--report-reload", "yes")
    assert "fields" in old and "save" not in old
    stale = run("apply", req, ok=False)
    assert not stale["ok"] and stale["code"] == "external_change"
    # A later failed reload cannot turn a durable save into a failed save.
    ctl.write_text('#!/bin/sh\nif [ "$1" = outputs ]; then echo "[]"; else echo \'{"ok":true,"status":"accepted"}\'; fi\n')
    snap = run("snapshot")
    failure_req = {"protocol": 1, "expected_generation": snap["generation"], "raw_files": {"outputs": all_fields}}
    saved = run("apply", failure_req, "--result", "v1")
    assert saved["save"] == "saved" and saved["reload"] == "failed"
    assert saved["toolkit"]["typography"]["targets"] and saved["toolkit"]["cursor"]["targets"]
    # Another cooperating writer cannot enter even while the first prepares.
    lockfile = tmp / "state/aqueous/config-writer/lock"
    with lockfile.open("r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        busy = run("apply", failure_req, "--result", "v1", ok=False)
        assert busy["save"] == "failed" and busy["failure"]["code"] == "config_writer_busy"
        assert busy["failure"]["retryable"]
    assert (lockfile.stat().st_mode & 0o777) == 0o600
    assert (lockfile.parent.stat().st_mode & 0o777) == 0o700
    # Two actual helpers with the same base: hold the first during its snapshot
    # while it still owns the writer lock, then try the competing request.
    fc_list = tmp / "bin/fc-list"
    fc_list.write_text('#!/bin/sh\nif [ -n "$AQ_TEST_HOLD" ]; then\n touch "$AQ_TEST_HOLD.ready"\n while [ ! -f "$AQ_TEST_HOLD.release" ]; do sleep 0.01; done\nfi\n')
    fc_list.chmod(0o755)
    snap = run("snapshot")
    same_base = {"protocol": 1, "expected_generation": snap["generation"],
                 "raw_files": {"outputs": all_fields + "\n# writer one\n"}}
    hold = tmp / "hold"
    first = subprocess.Popen([str(HELPER), "apply", "--shell", "none", "--request", "-", "--result", "v1"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, env=dict(env, AQ_TEST_HOLD=str(hold)))
    try:
        first.stdin.write(json.dumps(same_base))
        first.stdin.close()
        first.stdin = None
        deadline = time.monotonic() + 4
        while not Path(str(hold) + ".ready").exists():
            assert time.monotonic() < deadline and first.poll() is None
            time.sleep(0.01)
        competing = run("apply", same_base, "--result", "v1", ok=False)
        assert competing["failure"]["code"] == "config_writer_busy"
    finally:
        Path(str(hold) + ".release").touch()
        first_out, first_err = first.communicate(timeout=35)
    assert first.returncode == 0 and json.loads(first_out)["save"] == "saved", first_err
    assert run("apply", same_base, ok=False)["code"] == "external_change"
    # Generation-scoped IDs cannot target shifted collection records.
    (cfg / "rules.toml").write_text('[[window]]\napp_id = "one"\n[[window]]\napp_id = "two"\n')
    collection = run("snapshot")
    rule = collection["window_rules"][1]["id"]
    (cfg / "rules.toml").write_text('[[window]]\napp_id = "inserted"\n' + (cfg / "rules.toml").read_text())
    stale_rule = run("validate", {"protocol": 1, "expected_generation": collection["generation"],
                                  "window_rule_changes": [{"id": rule, "values": {"floating": True}}]}, ok=False)
    assert stale_rule["code"] == "external_change"
    # Real helper-only staging: absent GUI path, actual canonical reload binary.
    stage = tmp / "package"
    install_env = dict(env, DESTDIR=str(stage), PREFIX="/usr", AQUEOUS_CONFIG_BINARY=str(HELPER),
                       AQUEOUS_SETTINGS_BINARY=str(tmp / "missing-gui"),
                       AQUEOUSCTL_BINARY=str(ROOT.parent / "compositor/zig-out/bin/aqueousctl"))
    subprocess.run([str(ROOT / "packaging/install.sh"), "--helper-only"], env=install_env, check=True)
    assert (stage / "usr/bin/aqueousctl").is_file()
    assert not (stage / "usr/bin/aqueous-settings").exists()
    assert not (stage / "usr/share/applications").exists() and not (stage / "etc").exists()
    assert not (stage / "usr/share/aqueous").exists()
    HELPER = stage / "usr/bin/aqueous-config"
    run("version")
    installed_snapshot = run("snapshot")
    unchanged = {"protocol": 1, "expected_generation": installed_snapshot["generation"], "changes": []}
    run("validate", unchanged)
    run("apply", unchanged)
    print(json.dumps({"helper": version, "tests": "passed", "live_compositor": False, "hardware": "not tested"}))
