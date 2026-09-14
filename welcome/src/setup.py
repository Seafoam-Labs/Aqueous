#!/usr/bin/env python3
"""Unprivileged welcome worker and Aqueous session selector (Python 3.11+).

The GTK process exchanges bounded JSON lines with this worker. Shelly itself is
executed directly: package questions use its framed pipes; sudo's /dev/tty
password conversation has a private controlling terminal with echo disabled.
No password is included in a command, log, journal, or environment variable.
"""
import argparse
import base64
import configparser
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time
import tomllib
import uuid

LIMIT = 1024 * 1024
SHELLS = {
    "pearl": ("pearl-de", "pearl", "aqueous-pearl.service"),
    "dms": ("dms-shell", "dms", "aqueous-dms.service"),
    "noctalia": ("noctalia", "noctalia", "aqueous-noctalia.service"),
    "none": (None, None, None),
}
PEARL_CAPS = {"shell_none", "schema_fields", "validate", "generation_check",
              "stdin_requests", "apply_result_v1", "operation_receipts_v1",
              "candidate_impact_v1", "recoverable_commit_v1"}


class SetupError(Exception):
    pass


class Cancelled(SetupError):
    pass


def emit(kind, **values):
    print(json.dumps({"kind": kind, **values}, ensure_ascii=True), flush=True)


def reply():
    # Avoid a buffered readline consuming replies intended for install()'s
    # descriptor-based event loop (e.g. approve followed immediately by cancel).
    line = bytearray()
    while not line.endswith(b"\n"):
        byte = os.read(sys.stdin.fileno(), 1)
        if not byte or len(line) >= LIMIT:
            raise Cancelled("Setup window disconnected.")
        line.extend(byte)
    value = json.loads(line)
    if value.get("cancel"):
        raise Cancelled("Setup cancelled.")
    return value


def config_home():
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))


def state_home():
    return Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "aqueous"


def runtime_file():
    return Path(os.environ["XDG_RUNTIME_DIR"]) / "aqueous/welcome-session.json"


def read_bytes(path):
    if path.is_symlink():
        raise SetupError(f"Refusing to replace symbolic link: {path}")
    if not path.exists():
        return None
    if not path.is_file() or path.stat().st_size > LIMIT:
        raise SetupError(f"Not a bounded regular configuration file: {path}")
    return path.read_bytes()


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    read_bytes(path)
    fd, temporary = tempfile.mkstemp(prefix=".welcome-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def json_write(path, value):
    atomic(path, (json.dumps(value, indent=2) + "\n").encode())


def run(argv, request=None, timeout=30):
    # Spool bounded query results to files: a misbehaving child cannot fill RAM.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=out, stderr=err)
        try:
            child.communicate(None if request is None else json.dumps(request).encode(), timeout=timeout)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            raise SetupError(f"{argv[0]} timed out") from None
        out.seek(0)
        result = out.read(16 * LIMIT + 1)
        if len(result) > 16 * LIMIT:
            raise SetupError(f"{argv[0]} returned too much data")
        if child.returncode:
            err.seek(0)
            detail = err.read(4096).decode(errors="replace")
            raise SetupError(f"{argv[0]} failed: {detail or result[:4096].decode(errors='replace')}")
        return result


def helper(command, request=None):
    argv = ["aqueous-config", command, "--shell", "none"]
    if request is not None:
        argv += ["--request", "-"]
    value = json.loads(run(argv, request))
    if not value.get("ok", True):
        raise SetupError(value.get("message", "Aqueous configuration request failed"))
    return value


def installed(backend):
    rows = json.loads(run(["shelly", "list", backend, "--json"]))
    if not isinstance(rows, list):
        raise SetupError("Unsupported Shelly package-list format")
    key = "Id" if backend == "flatpak" else "Name"
    names = {row[key] for row in rows if key in row}
    if backend == "standard" and "dms-aqueous" in names:
        names.add("dms-shell")
    return names


class Frames:
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        self.buffer.extend(data)
        if len(self.buffer) > LIMIT:
            raise SetupError("Shelly frame exceeded the size limit")
        frames = []
        while True:
            start = self.buffer.find(b"[JSON]")
            if start < 0:
                # Retain only a possible partial prefix, discarding diagnostics.
                self.buffer[:] = self.buffer[-5:]
                break
            end = self.buffer.find(b"[/JSON]", start + 6)
            if end < 0:
                del self.buffer[:start]
                break
            try:
                frames.append(json.loads(base64.b64decode(self.buffer[start + 6:end], validate=True)))
            except (ValueError, UnicodeError) as exc:
                raise SetupError("Invalid Shelly frame") from exc
            del self.buffer[:end + 7]
        return frames


def frame(value):
    return b"[JSON]" + base64.b64encode(json.dumps(value).encode()) + b"[/JSON]\n"


def optional_answer(event):
    return {"$kind": "a.optdeps", "QuestionId": event["QuestionId"],
            "SelectedIndices": [o["Index"] for o in event.get("Options", [])
                                if not o.get("IsInstalled", False)]}


def question_answer(event, response):
    kind = event["$kind"]
    result = {"$kind": kind.replace("q.", "a.", 1), "QuestionId": event["QuestionId"]}
    if kind == "q.provider":
        choice = response.get("choice")
        if choice not in [o["Index"] for o in event.get("Options", [])]:
            raise SetupError("Choose a valid package provider")
        result["SelectedIndex"] = choice
    elif kind in ("q.yesno", "q.transaction", "q.pkgbuilddiff"):
        result["ProceedWithUpdate" if kind == "q.pkgbuilddiff" else "Accept"] = response.get("accept") is True
    else:
        raise SetupError(f"Unsupported Shelly question: {kind}")
    return result


def question_details(event):
    """Present the reviewed package data without exposing the wire protocol."""
    def render(value, depth=0):
        if depth > 8:
            raise SetupError("Package review is nested too deeply")
        if isinstance(value, dict):
            lines = []
            for key, item in value.items():
                if key in ("$kind", "QuestionId", "QuestionText", "Index") or item is None:
                    continue
                label = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", key)
                lines.append(label + ": " + render(item, depth + 1))
            return "\n".join(lines)
        if isinstance(value, list):
            return "\n" + "\n\n".join(render(item, depth + 1) for item in value)
        return str(value)
    return render(event)


def install(argv, send=emit, input_fd=None):
    """Supervise Shelly, keeping its controlling terminal separate from JSON I/O."""
    input_fd = sys.stdin.fileno() if input_fd is None else input_fd
    master, slave = os.openpty()
    # Canonical input permits sudo to read one password. Never allow tty echo.
    attrs = termios.tcgetattr(slave)
    attrs[3] &= ~(termios.ECHO | termios.ECHONL)
    termios.tcsetattr(slave, termios.TCSANOW, attrs)

    def terminal():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    env = dict(os.environ, LC_ALL="C", SHELLY_ELEVATOR="sudo")
    child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=env, preexec_fn=terminal,
                             pass_fds=(slave,), bufsize=0)
    os.close(slave)
    selector = selectors.DefaultSelector()
    for fd, name in ((master, "tty"), (child.stdout.fileno(), "stdout"),
                     (child.stderr.fileno(), "stderr"), (input_fd, "reply")):
        selector.register(fd, selectors.EVENT_READ, name)
    decoder = Frames()
    pending = None
    input_buffer = bytearray()
    tty_buffer = bytearray()
    diagnostics = bytearray()
    outcome = None
    cancel = False
    request_number = 0
    tty_started = None
    try:
        while child.poll() is None or any(k.data in ("stdout", "stderr") for k in selector.get_map().values()):
            if tty_started is not None and time.monotonic() - tty_started > 3:
                raise SetupError("Unsupported elevation prompt; Shelly requires the standard sudo password conversation")
            for key, _ in selector.select(0.2):
                try:
                    data = os.read(key.fd, 8192)
                except OSError:
                    data = b""
                if not data:
                    selector.unregister(key.fd)
                    if key.data == "reply":
                        cancel = True
                        if pending:
                            raise Cancelled("Setup window disconnected during a question")
                    continue
                if key.data == "reply":
                    input_buffer.extend(data)
                    if len(input_buffer) > LIMIT:
                        raise SetupError("Response exceeded size limit")
                    while b"\n" in input_buffer:
                        line, _, rest = input_buffer.partition(b"\n")
                        input_buffer = bytearray(rest)
                        response = json.loads(line)
                        if response.get("cancel"):
                            cancel = True
                            if pending:
                                raise Cancelled("Setup cancelled")
                            send("progress", message="Finishing the active package transaction before stopping…")
                            continue
                        if not pending or response.get("id") != pending[0]:
                            raise SetupError("Stale or unsolicited response")
                        if pending[1] == "password":
                            secret = bytearray(response.pop("password", "").encode())
                            try:
                                if not secret or b"\n" in secret or b"\r" in secret or len(secret) > 4096:
                                    raise SetupError("Invalid password response")
                                if termios.tcgetattr(master)[3] & (termios.ECHO | termios.ECHONL):
                                    raise SetupError("Authentication terminal unexpectedly enabled echo")
                                os.write(master, secret + b"\n")
                            finally:
                                secret[:] = b"\0" * len(secret)
                                line = b""
                                response.clear()
                        else:
                            child.stdin.write(frame(question_answer(pending[1], response)))
                        pending = None
                elif key.data == "tty":
                    # Only sudo's predictable C-locale prompt creates a password
                    # dialog. Arbitrary package output is never treated as one.
                    tty_buffer.extend(data)
                    if tty_started is None:
                        tty_started = time.monotonic()
                    if len(tty_buffer) > 8192:
                        raise SetupError("Unsupported authentication conversation")
                    if re.search(rb"\[sudo\] password for [^\r\n:]+: ?$", tty_buffer):
                        if pending:
                            raise SetupError("Overlapping authentication requests")
                        request_number += 1
                        pending = (str(request_number), "password")
                        send("password", id=pending[0], message="Enter your password to allow Shelly to install packages.")
                        tty_buffer.clear()
                        tty_started = None
                    elif tty_buffer.endswith(b"\n"):
                        tty_buffer.clear()
                        tty_started = None
                elif key.data == "stderr":
                    diagnostics.extend(data)
                    diagnostics[:] = diagnostics[-8192:]
                else:
                    for event in decoder.feed(data):
                        kind = event.get("$kind", "")
                        status = event.get("Status", "")
                        terminal_status = next((v for v in (kind, status, event.get("EventType")) if v in
                            ("TransactionDone", "TransactionFailed", "TransactionCancelled")), None)
                        if terminal_status:
                            outcome = terminal_status
                        if kind == "q.optdeps":
                            child.stdin.write(frame(optional_answer(event)))
                            send("progress", message="Selecting all optional dependencies…")
                        elif kind.startswith("q."):
                            if cancel:
                                raise Cancelled("Setup cancelled before transaction approval")
                            if kind not in ("q.provider", "q.yesno", "q.transaction", "q.pkgbuilddiff"):
                                raise SetupError(f"Unsupported Shelly question: {kind}")
                            request_number += 1
                            pending = (str(request_number), event)
                            send("question", id=pending[0], event=event,
                                 details=question_details(event),
                                 message=event.get("QuestionText") or event.get("Message") or "Review Shelly's package request")
                        else:
                            send("progress", message=str(event.get("ErrorMessage") or event.get("Message") or
                                 event.get("Status") or event.get("PackageName") or "Installing…")[:4096],
                                 percent=event.get("Percentage", event.get("Percent", 0)))
        code = child.wait()
        if cancel or outcome == "TransactionCancelled":
            raise Cancelled("Installation cancelled; installed packages were retained.")
        if code or outcome != "TransactionDone":
            raise SetupError("Shelly did not complete installation: " + diagnostics.decode(errors="replace"))
    finally:
        if child.poll() is None:
            # Used for declined questions/transport failure, not the normal
            # cancellation-during-commit path. Let Shelly unwind its transaction.
            os.killpg(child.pid, signal.SIGINT)
            try:
                child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                # Do not SIGKILL an ALPM commit. Keep supervising until it exits.
                send("progress", message="Waiting for Shelly to release its transaction…")
                child.wait()
        selector.close()
        child.stdin.close()
        child.stdout.close()
        child.stderr.close()
        os.close(master)


def selection():
    path = config_home() / "aqueous/session.toml"
    data = read_bytes(path)
    if data is not None:
        value = tomllib.loads(data.decode())
        if value.get("version") != 1 or value.get("shell") not in SHELLS:
            raise SetupError("Invalid Aqueous session selection")
        return value["shell"]
    # Preserve established profiles without choosing a shell for a fresh user.
    wm = read_bytes(config_home() / "aqueous/wm.toml")
    if wm:
        text = wm.decode()
        found = [s for s, command in (("dms", "dms "), ("noctalia", "noctalia "), ("pearl", "pearlctl ")) if command in text]
        if len(found) == 1 and shutil.which(SHELLS[found[0]][1]):
            return found[0]
    if (state_home() / "welcome-v1").exists():
        found = [s for s in ("dms", "noctalia", "pearl") if shutil.which(SHELLS[s][1])]
        if len(found) == 1:
            return found[0]
    return "none"


def active_selection():
    try:
        value = json.loads(runtime_file().read_text())
        if value.get("display") == os.environ.get("WAYLAND_DISPLAY") and value.get("shell") in SHELLS:
            return value["shell"]
    except (KeyError, OSError, ValueError):
        pass
    return selection()


def in_aqueous():
    return "aqueous" in os.environ.get("XDG_CURRENT_DESKTOP", "").lower().split(":")


def complete():
    atomic(state_home() / "welcome-v1", b"Aqueous welcome completed\n")
    atomic(config_home() / "autostart/org.aqueous.Welcome.desktop",
           b"[Desktop Entry]\nType=Application\nName=Welcome to Aqueous\nHidden=true\n")


class Journal:
    def __init__(self):
        self.path = state_home() / "welcome-operation.json"
        self.value = {"version": 1, "id": uuid.uuid4().hex, "phase": "preparing", "files": []}

    def save(self):
        json_write(self.path, self.value)

    def write(self, path, data):
        before = read_bytes(path)
        entry = {"path": str(path), "before": None if before is None else base64.b64encode(before).decode(),
                 "after": base64.b64encode(data).decode()}
        self.value["files"].append(entry)
        self.save()  # intent precedes mutation
        atomic(path, data)

    def recover(self):
        previous = read_bytes(self.path)
        if not previous:
            return
        value = json.loads(previous)
        if value.get("phase") in ("complete", "recovered"):
            return
        for entry in reversed(value.get("files", [])):
            path = Path(entry["path"])
            # Journals can only restore configuration under this user's root.
            if not path.is_relative_to(config_home()) or ".." in path.parts:
                raise SetupError("Invalid recovery path")
            current = read_bytes(path)
            before = None if entry["before"] is None else base64.b64decode(entry["before"])
            after = base64.b64decode(entry["after"])
            if current == before:
                continue
            if current != after:
                raise SetupError(f"Configuration changed since interrupted setup: {path}. Keep it and review {self.path}.")
            if before is None:
                path.unlink()
            else:
                atomic(path, before)
        canonical = value.get("canonical")
        if canonical:
            current = helper("snapshot")
            raw = current.get("raw_files", {})
            if raw != canonical["before"]:
                if raw != canonical["after"]:
                    raise SetupError("Aqueous configuration changed since interrupted setup; keep it and review " + str(self.path))
                helper("apply", {"protocol": 1, "expected_generation": current["generation"],
                                  "create_user_override": True, "raw_files": canonical["before"]})
        value["phase"] = "recovered"
        json_write(self.path, value)


KNOWN_ACTIONS = {
    "actions.toggle_start_menu": {"noctalia msg panel-toggle launcher", "dms ipc call spotlight toggle", "pearlctl launcher toggle"},
    "actions.screenshot": {"noctalia msg screenshot-region", "dms screenshot region", "grim -g \"$(slurp)\" - | wl-copy"},
    "actions.lock_screen": {"noctalia msg lock", "dms ipc call lock lock", "pearlctl lock"},
}
ACTION_NAMES = {"actions.toggle_start_menu": "launcher", "actions.screenshot": "screenshot", "actions.lock_screen": "lock"}


def configuration_request(snapshot):
    changes = []
    custom_changes = []
    preserved = []
    for field in snapshot.get("fields", []):
        key = field.get("id")
        if key in KNOWN_ACTIONS:
            desired = "aqueous-shell-action " + ACTION_NAMES[key]
            if field.get("value") == desired:
                continue
            if field.get("inherited") or field.get("value") in KNOWN_ACTIONS[key]:
                changes.append({"id": key, "value": desired})
            else:
                preserved.append(key)
    for binding in snapshot.get("custom_keybinds", []):
        command = binding.get("command", "")
        for key, known in KNOWN_ACTIONS.items():
            if command.startswith("spawn:") and command[6:] in known:
                custom_changes.append({"id": binding["id"], "op": "update",
                                       "chord": binding["chord"],
                                       "command": "spawn:aqueous-shell-action " + ACTION_NAMES[key]})
    return {"protocol": 1, "expected_generation": snapshot["generation"],
            "create_user_override": True, "changes": changes,
            "custom_keybind_changes": custom_changes}, preserved


def portal_change():
    """Update a recognized old chooser while preserving the rest of the file."""
    root = config_home() / "xdg-desktop-portal-aqueous"
    path = next((p for p in (root / "Aqueous", root / "config") if p.exists()), root / "config")
    before = read_bytes(path)
    desired = "aqueous-shell-action chooser"
    if before is None:
        return path, f"[screencast]\nchooser_type=dmenu\nchooser_cmd={desired}\n".encode(), None
    text = before.decode()
    parsed = configparser.ConfigParser(interpolation=None)
    parsed.read_string(text)
    old = parsed.get("screencast", "chooser_cmd", fallback="")
    known = {"", "noctalia dmenu -p \"Select a source to share:\"",
             "/usr/lib/aqueous/aqueous-dms-portal-chooser", "/usr/bin/aqueous-shell-action chooser", desired}
    if old not in known:
        return path, None, f"Keep custom portal chooser: {path}"
    # Work only within [screencast], preserving comments and unrelated sections.
    section = re.search(r"(?ms)^\[screencast\][^\n]*\n(.*?)(?=^\[|\Z)", text)
    if section is None:
        text += f"\n[screencast]\nchooser_type=dmenu\nchooser_cmd={desired}\n"
    else:
        body = section[1]
        for key, value in (("chooser_type", "dmenu"), ("chooser_cmd", desired)):
            pattern = rf"(?m)^{key}\s*=.*$"
            if re.search(pattern, body):
                body = re.sub(pattern, f"{key}={value}", body)
            else:
                body += f"{key}={value}\n"
        text = text[:section.start(1)] + body + text[section.end(1):]
    return path, text.encode(), None


def startup_conflicts():
    conflicts = []
    for base in (config_home() / "autostart", config_home() / "systemd/user"):
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.suffix not in (".desktop", ".service") or path.is_symlink() or not path.is_file():
                continue
            if path.stat().st_size > LIMIT:
                continue
            text = path.read_text(errors="replace")
            if "Hidden=true" in text or "aqueous-welcome" in text:
                continue
            only = re.search(r"(?m)^OnlyShowIn=(.*)$", text)
            if only and "Aqueous" not in only[1].split(";"):
                continue
            if re.search(r"^Exec(?:Start)?=.*\b(?:dms|noctalia|pearl)\b", text, re.M):
                conflicts.append(str(path))
    return conflicts


def setup(shell, packages):
    state_home().mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(state_home() / "welcome.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise SetupError("Another setup operation is running") from None
    with os.fdopen(fd, "w"):
        journal = Journal()
        journal.recover()
        conflicts = startup_conflicts()
        if conflicts:
            raise SetupError("Review custom shell startup before switching:\n" + "\n".join(conflicts))
        snapshot = helper("snapshot")
        selection_path = config_home() / "aqueous/session.toml"
        selection_before = read_bytes(selection_path)
        if shell == "pearl" and not PEARL_CAPS.issubset(set(snapshot.get("capabilities", []))):
            raise SetupError("This aqueous-config build lacks Pearl's required configuration capabilities")
        request, preserved = configuration_request(snapshot)
        portal_path, portal_data, portal_note = portal_change()
        portal_before = read_bytes(portal_path)
        candidate = helper("validate", request)
        package = SHELLS[shell][0]
        if package:
            packages.insert(0, ("standard", package))
        packages = list(dict.fromkeys(packages))
        statuses = {backend: installed(backend) for backend, _ in packages}
        # Re-run explicitly selected installed packages as well: Shelly must get
        # an opportunity to offer their still-missing optional dependencies.
        details = [f"{name} ({backend}; {'installed, check optional dependencies' if name in statuses[backend] else 'install'})"
                   for backend, name in packages]
        emit("review", message="\n".join([
            f"Desktop: {shell if shell != 'none' else 'Nothing'} — active next login.",
            "All optional dependencies offered by Shelly will be selected.",
            *details, "Existing shell settings and packages will be kept.",
            "Managed launcher, screenshot and lock commands will follow your active shell.",
            *(f"Keep custom command: {key}" for key in preserved),
            *([portal_note] if portal_note else ["The screen-sharing picker will follow your active desktop."]),
            "Backups and recovery journal: " + str(journal.path),
        ]))
        if not reply().get("accept"):
            raise Cancelled("Setup cancelled before making changes")
        # An already-running pre-upgrade session may not yet have a snapshot.
        # Capture its old choice before canonical commands start using routing.
        if in_aqueous() and os.environ.get("XDG_RUNTIME_DIR") and not runtime_file().exists():
            json_write(runtime_file(), {"shell": selection(), "display": os.environ.get("WAYLAND_DISPLAY")})
        journal.value.update(shell=shell, packages=packages, phase="installing")
        journal.save()
        for backend in ("standard", "aur", "flatpak"):
            names = [name for source, name in packages if source == backend]
            batches = [[name] for name in names] if backend == "flatpak" else ([names] if names else [])
            for batch in batches:
                argv = ["shelly", "install", backend, *batch, "--ui-mode"]
                if backend == "flatpak":
                    argv += ["--user", "--remote", "flathub"]
                install(argv)
                if not set(batch).issubset(installed(backend)):
                    raise SetupError("Shelly exited but selected packages are still missing")
        if SHELLS[shell][1] and not shutil.which(SHELLS[shell][1]):
            raise SetupError("The installed shell executable is missing")
        # Revalidate the reviewed generation after potentially long installs.
        helper("validate", request)
        journal.value["phase"] = "configuring"
        journal.save()
        if read_bytes(selection_path) != selection_before:
            raise SetupError("Desktop selection changed after review; review setup again")
        if read_bytes(portal_path) != portal_before:
            raise SetupError("Portal configuration changed after review; review setup again")
        if portal_data is not None:
            journal.write(portal_path, portal_data)
        if request["changes"] or request["custom_keybind_changes"]:
            journal.value["canonical"] = {"before": snapshot["raw_files"], "after": candidate["raw_files"]}
            journal.save()
            request["backup_dir"] = str(state_home() / "welcome-backups" / journal.value["id"])
            helper("apply", request)
        # Commit desired startup last. Runtime routing keeps the old shell until
        # the next login. No running shell, locker or portal is restarted here.
        journal.write(selection_path, f'version = 1\nshell = "{shell}"\n'.encode())
        journal.value["phase"] = "complete"
        journal.save()
        complete()
        emit("done", message="Setup complete. Log out and back in to use your selected desktop.")


def prepare_session():
    if not in_aqueous() or os.environ.get("AQUEOUS_NESTED") == "1":
        return
    shell = selection()
    if shell != "none" and not shutil.which(SHELLS[shell][1]):
        shell = "none"
        subprocess.Popen(["aqueous-welcome", "--message", "Your selected shell is missing. Run setup to install it or choose another desktop."],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    json_write(runtime_file(), {"shell": shell, "display": os.environ.get("WAYLAND_DISPLAY")})
    if shell == "noctalia":
        destination = config_home() / "noctalia/config.toml"
        source = Path(os.environ.get("AQUEOUS_SHARE_DIR", "/usr/share/aqueous")) / "noctalia/config.toml"
        if not destination.exists() and source.is_file():
            atomic(destination, source.read_bytes())


def condition(shell, external=False):
    if external:
        return 1 if in_aqueous() else 0
    if not in_aqueous() or os.environ.get("AQUEOUS_NESTED") == "1":
        return 1
    return 0 if active_selection() == shell else 1


def action(name):
    shell = active_selection()
    commands = {
        "pearl": {"launcher": ["pearlctl", "launcher", "toggle"], "lock": ["pearlctl", "lock"]},
        "dms": {"launcher": ["dms", "ipc", "call", "spotlight", "toggle"], "lock": ["dms", "ipc", "call", "lock", "lock"]},
        "noctalia": {"launcher": ["noctalia", "msg", "panel-toggle", "launcher"], "lock": ["noctalia", "msg", "lock"]},
        "none": {"launcher": ["aqueous-welcome"], "lock": ["aqueous-welcome", "--message", "No screen locker is configured for this shell-free session."]},
    }
    if name == "screenshot":
        geometry = run(["slurp"]).decode().strip()
        if not geometry:
            return
        image = subprocess.Popen(["grim", "-g", geometry, "-"], stdout=subprocess.PIPE)
        copied = subprocess.run(["wl-copy", "--type", "image/png"], stdin=image.stdout)
        image.stdout.close()
        if image.wait() or copied.returncode:
            raise SetupError("Screenshot failed")
        return
    if name == "chooser":
        command = {"dms": ["/usr/lib/aqueous/aqueous-dms-portal-chooser"],
                   "noctalia": ["noctalia", "dmenu", "-p", "Select a source to share:"]}.get(shell, ["aqueous-welcome", "--choose"])
    else:
        command = commands[shell][name]
    os.execvp(command[0], command)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("setup", "inspect", "prepare-session", "condition", "external-condition", "action"))
    parser.add_argument("value", nargs="?", default="none")
    parser.add_argument("packages", nargs="*")
    args = parser.parse_args()
    if args.command == "setup":
        if args.value not in SHELLS:
            raise SetupError("Unknown desktop")
        packages = []
        for spec in args.packages:
            backend, name = spec.split(":", 1)
            if backend not in ("standard", "aur", "flatpak") or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9@._+\-]*", name):
                raise SetupError("Invalid package identity")
            packages.append((backend, name))
        setup(args.value, packages)
    elif args.command == "inspect":
        selected = selection()
        explicit = (config_home() / "aqueous/session.toml").exists()
        try:
            names = installed("standard")
            status = "; ".join(f"{shell.title()}: {'installed' if package in names else 'not installed'}"
                               for shell, (package, _, _) in SHELLS.items() if package)
        except (OSError, SetupError, ValueError):
            status = "Package status unknown — Shelly is unavailable or could not query packages. Nothing remains available."
        emit("inspection", selected=selected if explicit or selected != "none" else "", message=status)
    elif args.command == "prepare-session":
        prepare_session()
    elif args.command in ("condition", "external-condition"):
        return condition(args.value, args.command == "external-condition")
    else:
        action(args.value)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SetupError, OSError, ValueError, KeyError) as exc:
        if len(sys.argv) > 1 and sys.argv[1] in ("setup", "inspect"):
            emit("error", message=str(exc))
        else:
            print(str(exc), file=sys.stderr)
        sys.exit(1)
