import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import "services"

Item {
    id: root
    property string pluginId: "aqueousSettings"
    property var pluginService: null
    property string outputName: ""
    property string status: ""
    property string errorCode: ""
    property string page: "overview"
    property string search: ""
    property alias model: drafts
    property alias client: client
    property alias appearance: appearance
    readonly property string backupDir: (Quickshell.env('XDG_STATE_HOME') || Quickshell.env('HOME') + '/.local/state') + '/aqueous/dms-plugin/backups'
    readonly property var preferences: SettingsData.getPluginSettingsForPlugin(pluginId)
    DraftModel {
        id: drafts
    }
    DmsAppearanceAdapter {
        id: appearance
    }
    ConfigClient {
        id: client
        helperPath: root.preferences.helperPath || 'aqueous-config'
        onCompleted: (operation, response) => {
            root.errorCode = '';
            if (operation === 'version') {
                root.load();
                return;
            }
            if (operation !== 'validate')
                drafts.accept(response);
            if (operation === 'apply' && response.desktop_typography?.applied)
                appearance.apply(response.desktop_typography);
            else if (operation !== 'validate')
                appearance.inspect(response.desktop_typography);
            root.status = operation === 'validate' ? 'Validation passed; drafts retained.' : operation === 'apply' ? 'Saved. Aqueous will hot-reload the configuration.' : 'Configuration loaded.';
            if (response.desktop_typography?.failed_count || response.desktop_cursor?.failed_count)
                root.status += ' Some appearance targets failed; see Appearance.';
        }
        onFailed: (operation, code, message) => {
            root.errorCode = code;
            root.status = code === 'external_change' ? 'Configuration changed outside this panel. Drafts are retained. Review them before reloading.' : message;
        }
    }
    function load() {
        client.run('snapshot');
    }
    function submit(operation) {
        try {
            client.run(operation, drafts.request(backupDir));
        } catch (e) {
            status = String(e);
        }
    }
    function show(output) {
        if (output)
            outputName = output;
        const screen = Quickshell.screens.find(s => s.name === outputName) || Quickshell.screens[0];
        if (screen) {
            outputName = screen.name;
            standalone.screen = screen;
            standalone.implicitWidth = Math.min(860, screen.width - 32);
            standalone.implicitHeight = Math.min(720, screen.height - 60);
        }
        standalone.visible = true;
        if (!drafts.snapshot.generation && !client.busy)
            client.run('version');
    }
    Component.onCompleted: client.run('version')
    IpcHandler {
        target: "aqueousSettings"
        function open(): string {
            root.show('');
            return 'opened';
        }
        function toggle(): string {
            if (standalone.visible)
                standalone.visible = false;
            else
                root.show('');
            return 'toggled';
        }
        function close(): string {
            standalone.visible = false;
            return 'closed; drafts retained';
        }
    }
    FloatingWindow {
        id: standalone
        visible: false
        title: 'Aqueous Settings'
        implicitWidth: 860
        implicitHeight: 720
        color: Theme.surface
        AqueousPanel {
            anchors.fill: parent
            controller: root
            onCloseRequested: standalone.visible = false
        }
    }
}
