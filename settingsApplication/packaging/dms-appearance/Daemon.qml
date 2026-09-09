import QtQuick
import Quickshell.Io
import qs.Common

Item {
    id: root
    property string pluginId: "aqueousSettingsAppearance"
    property var pluginService: null
    property string state: "idle"
    property var expected: null
    property string message: ""
    property int requestId: 0
    function matches(actual) {
        return expected && actual.fontFamily === expected.family
            && actual.fontWeight === expected.weight
            && Math.abs(actual.fontScale - expected.scale) < 0.001;
    }
    Connections {
        target: SettingsData.settingsFile
        function onSaveFailed(error) {
            if (root.state === "pending") {
                root.state = "failed";
                root.message = String(error);
            }
        }
    }
    FileView {
        id: persisted
        path: SettingsData.settingsFile.path
        blockLoading: false
        onLoaded: {
            if (root.state !== "pending") return;
            try {
                const actual = JSON.parse(text());
                if (root.matches(actual) && root.matches(SettingsData)) root.state = "saved";
            } catch (e) { root.message = String(e); }
        }
        onLoadFailed: error => {
            if (root.state === "pending") { root.state = "failed"; root.message = String(error); }
        }
    }
    Timer {
        id: deadline
        interval: 5000
        onTriggered: {
            if (root.state === "pending") { root.state = "failed"; root.message = "DMS save was not confirmed."; }
        }
    }
    IpcHandler {
        target: "aqueousSettingsAppearance"
        function apply(request: string): string {
            if (root.state === "pending") return JSON.stringify({ok: false, message: "A synchronization is already pending."});
            try {
                const spec = JSON.parse(request);
                if (!SettingsData._hasLoaded || SettingsData._parseError || SettingsData._isReadOnly)
                    throw new Error("DMS settings are not writable.");
                if (typeof spec.family !== "string" || !spec.family.length || spec.family.length > 256
                    || !Number.isInteger(spec.weight) || spec.weight < 1 || spec.weight > 1000
                    || !Number.isInteger(spec.size_pt) || spec.size_pt < 6 || spec.size_pt > 30)
                    throw new Error("Invalid typography request.");
                root.requestId += 1;
                deadline.restart();
                root.expected = {family: spec.family, weight: spec.weight, scale: spec.size_pt * 96 / 72 / 14};
                root.state = "pending";
                root.message = "";
                SettingsData.set("fontFamily", root.expected.family);
                SettingsData.set("fontWeight", root.expected.weight);
                SettingsData.set("fontScale", root.expected.scale);
                persisted.reload();
                return JSON.stringify({ok: true, requestId: root.requestId});
            } catch (e) {
                root.state = "failed"; root.message = String(e);
                return JSON.stringify({ok: false, message: root.message});
            }
        }
        function status(): string {
            if (root.state === "pending") persisted.reload();
            return JSON.stringify({ok: root.state !== "failed", state: root.state, message: root.message, requestId: root.requestId});
        }
    }
}
