// OutputControl.qml — Aqueous output-daemon bridge for Noctalia / Quickshell.
//
// Drop this file under /usr/share/aqueous/quickshell/ (PKGBUILD installs
// it there). A user can import it from their Noctalia config to give
// the display panel control of mode/scale/transform/position on
// River-based Aqueous sessions.
//
// Why this exists: Noctalia is a Wayland client and River does not
// implement zwlr_output_management_unstable_v1, so Noctalia has no
// native protocol path to drive outputs. This module talks to
// `aqueous-outputd` over $XDG_RUNTIME_DIR/aqueous/outputd.sock instead;
// the daemon forwards to wlr-randr inside River's `-c` control context.
//
// Usage from a Noctalia surface or panel:
//
//   import "file:///usr/share/aqueous/quickshell" as Aqueous
//
//   Aqueous.OutputControl {
//       id: outputs
//       Component.onCompleted: refresh()
//
//       onOutputsChanged: console.log("outputs:", JSON.stringify(model))
//   }
//
//   // Apply a change:
//   outputs.set([
//       { name: "HDMI-A-1", mode: "1920x1080@60", scale: 1.0,
//         position: [0, 0], enabled: true }
//   ])
//
// Wire format is line-delimited JSON; the daemon's protocol is
// documented in Aqueous.OutputDaemon/Program.cs.

import QtQuick
import Quickshell.Io

Item {
    id: root

    /// Latest output snapshot from the daemon (array of objects).
    property var model: []

    /// True when the daemon socket is reachable.
    property bool available: false

    /// Last error string from a failed request, or "".
    property string lastError: ""

    signal outputsChanged()
    signal applyResult(bool ok, string error)

    // Resolve the socket path. XDG_RUNTIME_DIR is always set inside a
    // Wayland session; fall back to /run/user/$UID for safety.
    readonly property string socketPath: {
        const xdg = Quickshell.env("XDG_RUNTIME_DIR");
        if (xdg && xdg.length > 0) return xdg + "/aqueous/outputd.sock";
        return "/run/user/" + Quickshell.env("UID") + "/aqueous/outputd.sock";
    }

    Socket {
        id: sock
        path: root.socketPath
        connected: false

        onConnectionStateChanged: {
            root.available = (connectionState === Socket.Connected);
        }

        onTextChanged: {
            // The daemon writes one JSON object per line. Quickshell's
            // Socket buffers; split and parse line-by-line.
            const lines = text.split("\n");
            for (let i = 0; i < lines.length; i++) {
                const ln = lines[i].trim();
                if (ln.length === 0) continue;
                try {
                    const obj = JSON.parse(ln);
                    root._dispatch(obj);
                } catch (e) {
                    root.lastError = "parse: " + e;
                }
            }
        }
    }

    function _dispatch(obj) {
        if ("event" in obj) {
            // Streaming event from a subscribe connection.
            if (obj.event === "output-changed" && obj.data && obj.data.outputs) {
                root.model = obj.data.outputs;
                root.outputsChanged();
            }
            return;
        }
        // Reply.
        if (obj.ok === true) {
            if ("outputs" in obj) {
                root.model = obj.outputs;
                root.outputsChanged();
            }
            root.applyResult(true, "");
        } else {
            root.lastError = obj.error || "unknown error";
            root.applyResult(false, root.lastError);
        }
    }

    function _send(req) {
        if (!sock.connected) sock.connected = true;
        sock.write(JSON.stringify(req) + "\n");
    }

    /// Refresh the output model.
    function refresh() { _send({ op: "list" }); }

    /// Apply a list of changes atomically.
    /// changes: [{ name|edid, mode?, scale?, transform?, position?, enabled?, adaptive_sync? }]
    function set(changes) { _send({ op: "set", changes: changes }); }

    /// Apply a named [[display.profile]] from wm.toml.
    function applyProfile(name) { _send({ op: "apply_profile", name: name }); }

    /// Persist a profile under outputs.toml.
    function saveProfile(name, outputs) {
        _send({ op: "save_profile", name: name, outputs: outputs });
    }

    /// Open a streaming subscription. Subsequent events arrive on
    /// outputsChanged (and applyResult for set/apply_profile broadcasts).
    function subscribe() { _send({ op: "subscribe" }); }
}
