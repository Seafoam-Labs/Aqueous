#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Seafoam Labs
# SPDX-License-Identifier: GPL-3.0-only
#
# Development: stdlib only, no external dependencies; Python 3.11+ for tomllib.
# Verify with `ruff check`, `ruff format --check`, and `ty check`. The repo has
# no ruff config, so ruff infers a pre-3.11 target, classes tomllib as
# third-party, and wants it in its own import block; leave it there. Not wired
# into `zig build test`: this harness drives a live session and is run by hand.
"""Measure what [scaling].buffer_policy = "integer-ceil" costs versus "native".

The single wm.toml line is the only variable; hot reload applies each toggle in
about 2 seconds. Workload windows are pinned to a fractional-scale output and
run in ABBA arm order, interleaved across cycles with a cooldown between runs:

  mpv        wall time for 600 frames rendered with --untimed (ms)
  qt         MangoHud gpu_load mean (%), fps mean, frame_time p95 (ms), and
             battery power mean (W) when discharging

Interpretation:
  At output scale 1.25 the policy advertises ceil(1.25) = 2.0, so an affected
  client renders (2.0 / 1.25)^2 = 2.56x the pixels and the compositor
  downscales that buffer on damage. Rough expectations on an iGPU: mpv
  wall-time ratio 1.3x to 2x, since the constant decode cost dilutes it;
  qt gpu_load up roughly in proportion at unthrottled workloads; power
  +0.5 to 2 W under load on the fractional panel. Idle desktop cost is zero by
  design because the compositor is damage-driven, so idle power is never a
  policy cost. When a stddev exceeds 10 percent of its mean, add cycles before
  believing a ratio.

  Only clients implementing wp_fractional_scale_v1 change: GTK3/4, Qt6,
  Chromium/Electron, mpv, ghostty. SDL2 and Proton titles ignore the protocol
  and XWayland keeps its own DPI story, so neither is benchmarked; a delta
  there would be noise rather than signal.

  mpv scores wall time over a fixed frame count because --benchmark was removed
  in mpv 0.41.0. Compositor CPU comes from a top scrape and power from a 1 s
  sysfs thread, since perf, pidstat, and sysprof are not installed. There is no
  headless mode and no compositor-internal frame timing: the cost being
  measured lives in the real client and render path on hardware, and no in-tree
  hook exposes the compositor's share.

Requires a running aqueous session with aqueousctl reachable, plus mpv,
ffmpeg, the Qt6 qml runtime, and MangoHud for the qt arm. The GPU workload is
Qt Quick rather than a browser because MangoHud cannot hook Chromium or
Electron on native Wayland (no interceptable swapchain; issues #477, #2018)
and blacklists every GTK app by engine, while Qt's Vulkan RHI backend
presents through a VkSwapchain it does hook. Runs where no CSV appears are
excluded rather than scored as zero.

Usage:
  aqueous-scalebench.py [--sanity] [--cycles N] [--cpu]

  --sanity   run mpv twice under the *current* policy; the printed ratio must
             be ~1.00 or the harness itself is broken
  --cycles   ABBA cycles per benchmark (default 2)
  --cpu      also sample compositor %CPU during mpv runs

Env:
  AQUEOUS_WM_TOML   config to toggle (default ~/.config/aqueous-git/wm.toml)
  AQUEOUS_OUTPUT    output workload windows must land on (default eDP-1); at
                    scale 1.0 integer-ceil is a no-op, so use the
                    fractional-scale panel as the treatment and a 1.0 output as
                    a null control
  QML_BIN           default /usr/lib/qt6/bin/qml; a qml on PATH may be Qt5
  MPV_APP_ID        default mpv
  QT_APP_ID         default org.qt-project.qml

Results land in ${TMPDIR:-/tmp}/scalebench/<UTC stamp>/:
results.tsv (bench, arm, cycle, run_index, score, unit), summary.txt, per-run
logs, MangoHud CSVs, and the generated fixtures. The original buffer_policy
value is restored on every exit path, along with any rules.toml
buffer_scale_policy overrides disabled for the run (a content_type rule
forcing "native" would otherwise silently null the treatment for exactly the
workload windows being measured).
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal, NoReturn, TextIO, TypeGuard, cast

import tomllib

# Children inherit log files rather than pipes, which typeshed types as bytes.
Process = subprocess.Popen[bytes]

Policy = Literal["native", "integer-ceil"]

POLICIES: tuple[Policy, ...] = ("native", "integer-ceil")
ABBA_ARMS: tuple[Policy, Policy, Policy, Policy] = (
    "native",
    "integer-ceil",
    "integer-ceil",
    "native",
)

REQUIRED_COMMANDS = ("mpv", "ffmpeg", "aqueousctl")
HOT_RELOAD_SECONDS = 2.0
COOLDOWN_SECONDS = 5.0
MPV_TIMEOUT_SECONDS = 120.0
MPV_KILL_GRACE_SECONDS = 5.0
QT_TIMEOUT_SECONDS = 50.0
QT_KILL_GRACE_SECONDS = 5.0
WINDOW_WAIT_ATTEMPTS = 20
WINDOW_WAIT_INTERVAL_SECONDS = 0.5

POLICY_LINE = re.compile(r'^buffer_policy = "([^"]*)"', re.MULTILINE)
POLICY_LINE_COUNT = re.compile(r"^buffer_policy = ", re.MULTILINE)
RULE_POLICY_LINE = re.compile(r"^buffer_scale_policy = ", re.MULTILINE)

WORKLOAD_QML = """import QtQuick
import QtQuick.Window
import QtQuick.Effects

Window {
    id: win
    visible: true
    visibility: Window.FullScreen
    color: "#101018"
    title: "scalebench-qt"

    Item {
        id: field
        anchors.fill: parent
        // Offscreen target: the field re-renders every frame into a buffer
        // whose pixel size tracks the client scale factor.
        layer.enabled: true
        layer.smooth: true

        Repeater {
            id: rep
            model: 4000
            Rectangle {
                width: 32 + (index % 14) * 10
                height: width
                radius: width / 2
                antialiasing: true
                color: Qt.hsla((index % 360) / 360, 0.85, 0.6, 0.9)
            }
        }
    }

    // Full-screen blur over the offscreen field; the pass cost scales with
    // buffer resolution, so it widens under the treatment's larger backing store.
    MultiEffect {
        source: field
        anchors.fill: field
        blurEnabled: true
        blurMax: 64
        blur: 0.85
    }

    FrameAnimation {
        running: win.visible
        // Seeded RNG keeps the particle field identical across runs.
        property var balls: []
        property int seed: 1234567
        function rnd() {
            seed = (Math.imul(seed, 1103515245) + 12345) & 0x7fffffff;
            return seed / 0x7fffffff;
        }
        Component.onCompleted: {
            for (let i = 0; i < rep.count; i++)
                balls.push({ x: rnd(), y: rnd(),
                             vx: (rnd() - 0.5) * 12, vy: (rnd() - 0.5) * 12 });
        }
        onTriggered: {
            const w = win.width, h = win.height;
            for (let i = 0; i < rep.count; i++) {
                const b = balls[i];
                b.x += b.vx / w; b.y += b.vy / h;
                if (b.x < 0 || b.x > 1) { b.vx *= -1; b.x = Math.min(Math.max(b.x, 0), 1); }
                if (b.y < 0 || b.y > 1) { b.vy *= -1; b.y = Math.min(Math.max(b.y, 0), 1); }
                const it = rep.itemAt(i);
                it.x = b.x * w;
                it.y = b.y * h;
            }
        }
    }
}
"""


def log(message: str) -> None:
    print(f"[scalebench] {message}")


def warn(message: str) -> None:
    print(f"[scalebench] {message}", file=sys.stderr)


def die(message: str) -> NoReturn:
    warn(message)
    raise SystemExit(1)


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def utc_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def usable(value: float | None) -> TypeGuard[float]:
    """True when a score is present; failed reads are recorded as None or NaN."""
    return value is not None and not math.isnan(value)


def format_score(value: float | None) -> str:
    return f"{value:.3f}" if usable(value) else "nan"


def mean(values: Sequence[float]) -> float | None:
    return statistics.fmean(values) if values else None


def median(values: Sequence[float]) -> float | None:
    return statistics.median(values) if values else None


def stddev(values: Sequence[float]) -> float | None:
    return statistics.stdev(values) if len(values) > 1 else None


def percentile_95(values: Sequence[float]) -> float | None:
    """Nearest-rank p95 with no interpolation, so scores stay comparable."""
    if not values:
        return None
    ordered = sorted(values)
    index = min(max(int(len(ordered) * 0.95), 1), len(ordered))
    return ordered[index - 1]


def ratio(numerator: float | None, denominator: float | None) -> float | None:
    if not usable(numerator) or not usable(denominator) or not denominator:
        return None
    return numerator / denominator


def read_sysfs(path: Path) -> str | None:
    try:
        return path.read_text().strip()
    except OSError:
        return None


def compositor_pid() -> int | None:
    completed = subprocess.run(
        ["pgrep", "-x", "aqueous"], capture_output=True, text=True, check=False
    )
    for line in completed.stdout.split():
        return int(line)
    return None


def parses_as_toml(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError):
        return False
    return True


def write_validated_toml(target: Path, text: str, failure: str) -> None:
    """Atomically replace target with text after proving it parses as TOML."""
    descriptor, raw = tempfile.mkstemp(
        dir=target.parent, prefix=f".{target.stem}-", suffix=".toml"
    )
    staged = Path(raw)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(text)
        if not parses_as_toml(staged):
            die(failure)
        staged.chmod(target.stat().st_mode & 0o7777)
        os.replace(staged, target)
    except BaseException:
        staged.unlink(missing_ok=True)
        raise


def discover_rules_path(wm_toml: Path) -> Path | None:
    """Follow the compositor's rules discovery order; first existing path wins."""
    env = os.environ.get("AQUEOUS_RULES")
    if env:
        candidate = Path(env).expanduser()
        return candidate if candidate.is_file() else None
    try:
        with wm_toml.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError):
        data = {}
    section = data.get("rules")
    if isinstance(section, dict):
        configured = section.get("path")
        if isinstance(configured, str) and configured:
            candidate = Path(configured).expanduser()
            return candidate if candidate.is_file() else None
    home = Path.home()
    xdg = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")).expanduser()
    for directory in (xdg, home / ".config"):
        candidate = directory / "aqueous" / "rules.toml"
        if candidate.is_file():
            return candidate
    return None


def signal_group(process: Process, signum: int) -> None:
    """Signal the child's whole group; a lone SIGTERM orphans browser helpers."""
    try:
        os.killpg(process.pid, signum)
    except (OSError, ProcessLookupError):
        try:
            process.send_signal(signum)
        except (OSError, ProcessLookupError):
            pass


def terminate(process: Process | None) -> int | None:
    if process is None:
        return None
    signal_group(process, signal.SIGTERM)
    try:
        process.wait(timeout=5.0)
    except subprocess.TimeoutExpired:
        signal_group(process, signal.SIGKILL)
        process.wait()
    return process.returncode


def wait_or_kill(
    process: Process, timeout: float, grace: float
) -> tuple[int | None, bool]:
    """Wait up to `timeout`, then SIGTERM and SIGKILL after `grace`.

    Returns the exit code and whether the timeout fired.
    """
    try:
        return process.wait(timeout=timeout), False
    except subprocess.TimeoutExpired:
        signal_group(process, signal.SIGTERM)
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            signal_group(process, signal.SIGKILL)
            process.wait()
        return process.returncode, True


@dataclass(frozen=True)
class Sample:
    """One recorded score; the row written to results.tsv."""

    bench: str
    arm: str
    cycle: int
    run: int
    score: float | None
    unit: str

    def row(self) -> str:
        return "\t".join(
            (
                self.bench,
                self.arm,
                str(self.cycle),
                str(self.run),
                format_score(self.score),
                self.unit,
            )
        )


@dataclass(frozen=True)
class Options:
    wm_toml: Path
    output: str
    qml_bin: str
    mpv_app_id: str
    qt_app_id: str
    cycles: int
    sanity: bool
    cpu_sample: bool
    results: Path

    @property
    def backup(self) -> Path:
        return Path(f"{self.wm_toml}.scalebench.bak")


def positive_int(raw: str) -> int:
    try:
        value = int(raw)
    except ValueError:
        raise argparse.ArgumentTypeError(
            "--cycles must be a positive integer"
        ) from None
    if value < 1:
        raise argparse.ArgumentTypeError("--cycles must be a positive integer")
    return value


def parse_args(argv: Sequence[str] | None) -> Options:
    parser = argparse.ArgumentParser(
        prog="aqueous-scalebench.py",
        description=(
            'A/B-measure [scaling].buffer_policy = "integer-ceil" against '
            '"native" on a live aqueous session.'
        ),
        epilog=("Env: AQUEOUS_WM_TOML, AQUEOUS_OUTPUT, QML_BIN, MPV_APP_ID, QT_APP_ID"),
    )
    parser.add_argument(
        "--sanity",
        action="store_true",
        help=(
            "run mpv twice under the *current* policy; the printed ratio must "
            "be ~1.00 or the harness itself is broken"
        ),
    )
    parser.add_argument(
        "--cycles",
        type=positive_int,
        default=2,
        metavar="N",
        help="ABBA cycles per benchmark (default 2)",
    )
    parser.add_argument(
        "--cpu",
        action="store_true",
        help="also sample compositor %%CPU during mpv runs",
    )
    args = parser.parse_args(argv)

    home = Path.home()
    wm_toml = Path(
        os.environ.get("AQUEOUS_WM_TOML", home / ".config/aqueous-git/wm.toml")
    ).expanduser()
    return Options(
        wm_toml=wm_toml,
        output=os.environ.get("AQUEOUS_OUTPUT", "eDP-1"),
        qml_bin=os.environ.get("QML_BIN", "/usr/lib/qt6/bin/qml"),
        mpv_app_id=os.environ.get("MPV_APP_ID", "mpv"),
        qt_app_id=os.environ.get("QT_APP_ID", "org.qt-project.qml"),
        cycles=args.cycles,
        sanity=args.sanity,
        cpu_sample=args.cpu,
        results=Path(tempfile.gettempdir()) / "scalebench" / utc_stamp(),
    )


class PowerSampler:
    """Sample BAT0 power_now once per second into a CSV until stopped."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.stopped.set()
        self.thread.join(timeout=3.0)

    def _run(self) -> None:
        with self.path.open("w") as handle:
            while not self.stopped.is_set():
                micro_watts = read_sysfs(Path("/sys/class/power_supply/BAT0/power_now"))
                if micro_watts is not None:
                    handle.write(f"{int(time.time())},{micro_watts}\n")
                    handle.flush()
                self.stopped.wait(1.0)


def mean_power_watts(path: Path) -> float | None:
    readings: list[float] = []
    try:
        with path.open(newline="") as handle:
            for row in csv.reader(handle):
                if len(row) < 2:
                    continue
                try:
                    readings.append(float(row[1]))
                except ValueError:
                    continue
    except OSError:
        return None
    value = mean(readings)
    return None if value is None else value / 1e6


def csv_column(path: Path, names: Sequence[str]) -> list[float]:
    """Extract a data column by header name, trying each spelling in order.

    With log_versioning, MangoHud prefixes version and system-info blocks
    before the frame-metrics header, so scan for the line carrying `fps`.
    The column set varies by version, so a missing column yields no values
    rather than an error.
    """
    try:
        lines = path.read_text(newline="", errors="replace").splitlines()
    except OSError:
        return []
    start = next((i for i, line in enumerate(lines) if "fps" in line.split(",")), None)
    if start is None:
        return []
    reader = csv.DictReader(lines[start:])
    if reader.fieldnames is None:
        return []
    by_name = {name.strip(): name for name in reader.fieldnames}
    key = next((by_name[name] for name in names if name in by_name), None)
    if key is None:
        return []
    values: list[float] = []
    for row in reader:
        raw = (row.get(key) or "").strip()
        if not raw:
            continue
        try:
            values.append(float(raw))
        except ValueError:
            continue
    return values


def newest_csv(directory: Path) -> Path | None:
    candidates = sorted(
        (
            path
            for path in directory.glob("*.csv")
            if not path.stem.endswith("_summary")
        ),
        key=lambda path: path.stat().st_mtime,
    )
    return candidates[-1] if candidates else None


def mean_top_cpu(log_path: Path, pid: int) -> float | None:
    column: int | None = None
    values: list[float] = []
    try:
        lines = log_path.read_text(errors="replace").splitlines()
    except OSError:
        return None
    for line in lines:
        fields = line.split()
        if column is None:
            if "%CPU" in fields:
                column = fields.index("%CPU")
            continue
        if len(fields) > column and fields[0] == str(pid):
            try:
                values.append(float(fields[column]))
            except ValueError:
                continue
    return mean(values)


class ScaleBench:
    def __init__(self, options: Options) -> None:
        self.options = options
        self.current_policy: Policy = "native"
        self.power = False
        self.restored = False
        self.rules_toml: Path | None = None
        self.samples: list[Sample] = []

    def preflight(self) -> None:
        options = self.options
        commands = [*REQUIRED_COMMANDS, options.qml_bin]
        if options.cpu_sample:
            commands.append("top")
        if not options.sanity:
            commands.append("mangohud")
        for command in commands:
            if shutil.which(command) is None:
                die(f"missing required command: {command}")
        if compositor_pid() is None:
            die("no running aqueous process (pgrep -x aqueous)")

        listed = subprocess.run(
            ["aqueousctl", "outputs"], capture_output=True, text=True, check=False
        ).stdout
        if options.output not in listed:
            die(f"output {options.output} not listed by 'aqueousctl outputs'")

        if not options.wm_toml.is_file():
            die(f"no such config: {options.wm_toml}")
        text = options.wm_toml.read_text()
        found = len(POLICY_LINE_COUNT.findall(text))
        if found != 1:
            die(
                f"expected exactly one '^buffer_policy = ' line in "
                f"{options.wm_toml}, found {found}"
            )
        match = POLICY_LINE.search(text)
        value = match.group(1) if match else ""
        if value not in POLICIES:
            die(f"unexpected buffer_policy value: {value}")
        self.current_policy = cast(Policy, value)

        ac = read_sysfs(Path("/sys/class/power_supply/AC/online")) or "1"
        status = read_sysfs(Path("/sys/class/power_supply/BAT0/status"))
        if ac == "0" and status == "Discharging":
            self.power = True
        else:
            log("on AC or not discharging; battery power benchmark disabled")

        shutil.copy2(options.wm_toml, options.backup)
        options.results.mkdir(parents=True, exist_ok=True)
        self.neutralize_rules()
        log(f"session policy: {self.current_policy}")
        log(f"results dir: {options.results}")

    def neutralize_rules(self) -> None:
        """Comment out rules.toml buffer_scale_policy overrides for the run.

        A rule like content_type = "video" -> native silently nulls the
        wm.toml treatment for exactly the workload windows being measured,
        and mpv commits that content type on every run.
        """
        path = discover_rules_path(self.options.wm_toml)
        if path is None:
            return
        text = path.read_text()
        count = len(RULE_POLICY_LINE.findall(text))
        if count == 0:
            return
        updated = RULE_POLICY_LINE.sub(
            "# scalebench-disabled: buffer_scale_policy = ", text
        )
        shutil.copy2(path, Path(f"{path}.scalebench.bak"))
        write_validated_toml(path, updated, f"{path} failed TOML validation after edit")
        self.rules_toml = path
        time.sleep(HOT_RELOAD_SECONDS)
        log(f"disabled {count} buffer_scale_policy override(s) in {path}")

    def restore_config(self) -> None:
        if self.restored:
            return
        self.restored = True
        self._restore(self.options.backup, self.options.wm_toml)
        if self.rules_toml is not None:
            self._restore(Path(f"{self.rules_toml}.scalebench.bak"), self.rules_toml)

    def _restore(self, backup: Path, target: Path) -> None:
        if not backup.is_file():
            return
        if not parses_as_toml(backup):
            warn(f"backup failed TOML validation; left untouched at {backup}")
            return
        backup.replace(target)
        log(f"restored original {target}")

    def set_policy(self, value: Policy) -> None:
        """Rewrite the single buffer_policy line, then let hot reload apply it.

        Edit a temp copy in the config's own directory, prove the value landed
        and that the copy still parses as TOML, then atomically replace the
        original, preserving its mode.
        """
        target = self.options.wm_toml
        text = target.read_text()
        updated, count = re.subn(
            r'^buffer_policy = "[^"]*"',
            f'buffer_policy = "{value}"',
            text,
            count=1,
            flags=re.MULTILINE,
        )
        if count != 1 or not re.search(
            rf'^buffer_policy = "{re.escape(value)}"', updated, re.MULTILINE
        ):
            die(f"toggle to '{value}' did not apply")

        write_validated_toml(
            target, updated, "wm.toml failed TOML validation after edit"
        )
        time.sleep(HOT_RELOAD_SECONDS)
        log(f"buffer_policy = {value}")

    def generate_fixtures(self) -> None:
        clip = self.options.results / "clip.mp4"
        if not clip.is_file():
            log("generating 2560x1440@60 test clip (one time)...")
            subprocess.run(
                [
                    "ffmpeg",
                    "-y",
                    "-loglevel",
                    "error",
                    "-f",
                    "lavfi",
                    "-i",
                    "testsrc2=size=2560x1440:rate=60",
                    "-t",
                    "30",
                    "-c:v",
                    "libx264",
                    "-crf",
                    "18",
                    "-pix_fmt",
                    "yuv420p",
                    "-an",
                    str(clip),
                ],
                check=True,
            )
        workload = self.options.results / "workload.qml"
        if not workload.is_file():
            workload.write_text(WORKLOAD_QML)

    def verify_window(self, app_id: str) -> bool:
        """Assert the workload is a native Wayland window on the treatment output.

        An XWayland window or the wrong output would silently null the A/B.
        """
        for _ in range(WINDOW_WAIT_ATTEMPTS):
            completed = subprocess.run(
                ["aqueousctl", "windows", "--json"],
                capture_output=True,
                text=True,
                check=False,
            )
            try:
                windows = json.loads(completed.stdout)
            except json.JSONDecodeError:
                windows = []
            if isinstance(windows, list) and any(
                isinstance(window, dict)
                and window.get("app_id") == app_id
                and window.get("output") == self.options.output
                and window.get("backend") == "xdg"
                for window in windows
            ):
                return True
            time.sleep(WINDOW_WAIT_INTERVAL_SECONDS)
        log(
            f"window '{app_id}' never appeared on {self.options.output} as "
            "native Wayland (backend xdg)"
        )
        return False

    def record(self, sample: Sample) -> None:
        self.samples.append(sample)
        with (self.options.results / "results.tsv").open("a") as handle:
            handle.write(sample.row() + "\n")

    def scores(self, bench: str, arm: str) -> list[float]:
        values: list[float] = []
        for sample in self.samples:
            if sample.bench == bench and sample.arm == arm and usable(sample.score):
                values.append(sample.score)
        return values

    def bench_mpv(self, arm: str, cycle: int, run: int) -> bool:
        options = self.options
        pid = compositor_pid()
        top_log = options.results / f"top-{arm}-{run}.log"
        command = [
            "mpv",
            "--untimed",
            "--audio=no",
            "--osd-level=0",
            "--fullscreen",
            "--frames=600",
            str(options.results / "clip.mp4"),
        ]
        top_handle: TextIO | None = None
        top: Process | None = None
        if options.cpu_sample and pid is not None:
            top_handle = top_log.open("w")
            top = subprocess.Popen(
                ["top", "-b", "-d", "1", "-n", "130", "-p", str(pid)],
                stdout=top_handle,
                stderr=subprocess.DEVNULL,
            )
        # Decode cost and startup are constant across arms, so the wall-time
        # delta isolates render and present cost at the larger backing buffer.
        started = time.monotonic()
        try:
            with (options.results / f"mpv-{arm}-{run}.log").open("w") as mpv_log:
                mpv = subprocess.Popen(
                    command,
                    stdout=mpv_log,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                if not self.verify_window(options.mpv_app_id):
                    terminate(mpv)
                    return False
                # The deadline covers the window check, as `timeout 120` did.
                code, _ = wait_or_kill(
                    mpv,
                    max(started + MPV_TIMEOUT_SECONDS - time.monotonic(), 0.0),
                    MPV_KILL_GRACE_SECONDS,
                )
        finally:
            terminate(top)
            if top_handle is not None:
                top_handle.close()
        elapsed_ms = (time.monotonic() - started) * 1000.0

        if code != 0:
            log(f"mpv ({arm}/{cycle}/{run}) exited {code}; see mpv-{arm}-{run}.log")
            return False
        self.record(Sample("mpv", arm, cycle, run, elapsed_ms, "ms"))
        log(f"mpv {arm}/{cycle}/{run}: {elapsed_ms:.0f} ms")

        if options.cpu_sample and pid is not None and top_log.is_file():
            cpu = mean_top_cpu(top_log, pid)
            if cpu is not None:
                self.record(Sample("mpv-cpu", arm, cycle, run, cpu, "pct"))
                log(f"compositor CPU mean: {cpu:.2f}%")
        return True

    def bench_qt(self, arm: str, cycle: int, run: int) -> bool:
        options = self.options
        outdir = options.results / f"mango-{arm}-{run}"
        outdir.mkdir(parents=True, exist_ok=True)
        power_csv = options.results / f"power-{arm}-{run}.csv"
        mangohud_config = ",".join(
            (
                "fps",
                "frame_timing",
                # Config toggles are gpu_stats/cpu_stats; gpu_load/cpu_load are
                # only the CSV column names. no_display kills logging entirely
                # (flightlessmango/MangoHud#1782), so the overlay stays visible.
                "gpu_stats",
                "cpu_stats",
                "log_versioning",
                f"output_folder={outdir}",
                # log_interval defaults to 100 ms.
                "autostart_log=2",
                "log_duration=40",
            )
        )
        environment = os.environ | {
            "MANGOHUD_CONFIG": mangohud_config,
            # Under the default OpenGL RHI, Qt presents through EGL, which
            # MangoHud cannot hook on Wayland (flightlessmango/MangoHud#477);
            # the Vulkan backend presents through a VkSwapchain it can.
            "QSG_RHI_BACKEND": "vulkan",
            "QT_QPA_PLATFORM": "wayland",
        }
        command = [
            # MANGOHUD_CONFIG alone injects nothing; the wrapper LD_PRELOADs
            # the hook and enables the implicit Vulkan layer.
            "mangohud",
            options.qml_bin,
            str(options.results / "workload.qml"),
        ]

        sampler = PowerSampler(power_csv) if self.power else None
        started = time.monotonic()
        if sampler is not None:
            sampler.start()
        try:
            with (options.results / f"qt-{arm}-{run}.log").open("w") as handle:
                qt = subprocess.Popen(
                    command,
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                    env=environment,
                    start_new_session=True,
                )
                if not self.verify_window(options.qt_app_id):
                    terminate(qt)
                    return False
                # MangoHud logs for 40 s from 2 s after launch, so the 50 s
                # deadline, which also covers the window check, is the normal
                # end of a run.
                code, timed_out = wait_or_kill(
                    qt,
                    max(started + QT_TIMEOUT_SECONDS - time.monotonic(), 0.0),
                    QT_KILL_GRACE_SECONDS,
                )
        finally:
            if sampler is not None:
                sampler.stop()

        if not timed_out and code != 0:
            log(f"qt ({arm}/{cycle}/{run}) exited {code}; see qt-{arm}-{run}.log")
            return False

        csv_path = newest_csv(outdir)
        if csv_path is None:
            log(f"no MangoHud CSV in {outdir}; run excluded")
            return False
        gpu = mean(csv_column(csv_path, ("gpu_load", "GPU_load", "gpu%")))
        fps = mean(csv_column(csv_path, ("fps", "FPS")))
        frame_time = percentile_95(
            csv_column(csv_path, ("frame_time", "frametime", "FrameTime"))
        )
        self.record(Sample("qt-gpu", arm, cycle, run, gpu, "pct"))
        self.record(Sample("qt-fps", arm, cycle, run, fps, "fps"))
        self.record(Sample("qt-p95", arm, cycle, run, frame_time, "ms"))
        log(
            f"qt {arm}/{cycle}/{run}: gpu={format_score(gpu)}% "
            f"fps={format_score(fps)} p95={format_score(frame_time)} ms ({csv_path})"
        )

        if self.power and power_csv.is_file():
            watts = mean_power_watts(power_csv)
            if watts is not None:
                self.record(Sample("qt-power", arm, cycle, run, watts, "W"))
                log(f"battery power mean: {watts:.3f} W")
        return True

    def run_suite(self) -> None:
        benches: tuple[str, ...] = ("mpv",) if self.options.sanity else ("mpv", "qt")
        runners: dict[str, Callable[[str, int, int], bool]] = {
            "mpv": self.bench_mpv,
            "qt": self.bench_qt,
        }
        arms: Sequence[Policy] = (
            (self.current_policy, self.current_policy)
            if self.options.sanity
            else ABBA_ARMS
        )
        for bench in benches:
            run = 0
            for cycle in range(1, self.options.cycles + 1):
                for index, arm in enumerate(arms):
                    label = f"sanity-{index + 1}" if self.options.sanity else arm
                    run += 1
                    log(f"== {bench} arm={label} cycle={cycle} run={run} ==")
                    self.set_policy(arm)
                    if not runners[bench](label, cycle, run):
                        log("run excluded (failed)")
                    time.sleep(COOLDOWN_SECONDS)

    def analyze(self) -> None:
        if not self.samples:
            log("no recorded runs")
            return
        options = self.options
        a_arm, b_arm = (
            ("sanity-1", "sanity-2") if options.sanity else ("native", "integer-ceil")
        )
        groups = list(
            dict.fromkeys((sample.bench, sample.arm) for sample in self.samples)
        )
        benches = list(dict.fromkeys(sample.bench for sample in self.samples))
        units: dict[tuple[str, str], str] = {}
        for sample in self.samples:
            units.setdefault((sample.bench, sample.arm), sample.unit)

        lines: list[str] = [
            f"aqueous-scalebench summary  {utc_iso()}",
            (
                f"output={options.output} cycles={options.cycles} "
                f"sanity={int(options.sanity)} session policy={self.current_policy}"
            ),
            "",
            (
                f"{'bench':<16} {'arm':<14} {'n':>3} {'mean':>10} {'median':>10} "
                f"{'stddev':>10} {'unit':>5}"
            ),
        ]
        for bench, arm in groups:
            values = self.scores(bench, arm)
            lines.append(
                f"{bench:<16} {arm:<14} {len(values):>3} "
                f"{format_score(mean(values)):>10} "
                f"{format_score(median(values)):>10} "
                f"{format_score(stddev(values)):>10} {units[(bench, arm)]:>5}"
            )
        lines += ["", f"ratios ({b_arm} / {a_arm}, means):"]
        for bench in benches:
            a = mean(self.scores(bench, a_arm))
            b = mean(self.scores(bench, b_arm))
            lines.append(
                f"  {bench:<16} {format_score(a):>10} -> {format_score(b):<10} "
                f"ratio {format_score(ratio(b, a))}"
            )
        lines.append("")
        if options.sanity:
            lines += [
                "sanity: both arms ran the same policy, so every ratio must be",
                "~1.00. Anything else means the harness itself is broken.",
            ]
        else:
            lines += [
                "a ratio of 1.0 everywhere means the toggle never applied or the",
                "client is not fractional-scale aware; check the backend assertion",
                "and confirm text sharpness changed visually.",
            ]
        summary = "\n".join(lines)
        print(summary)
        (options.results / "summary.txt").write_text(summary + "\n")


def install_signal_handlers() -> None:
    def handler(signum: int, _frame: object) -> NoReturn:
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)


def main(argv: Sequence[str] | None = None) -> int:
    options = parse_args(argv)
    bench = ScaleBench(options)
    install_signal_handlers()
    try:
        bench.preflight()
        bench.generate_fixtures()
        bench.run_suite()
    finally:
        # Restore before any final output so the session is never left in a
        # benchmark state, even if analysis below fails.
        bench.restore_config()
    print()
    bench.analyze()
    log(f"raw results: {options.results}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
