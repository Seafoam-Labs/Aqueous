import QtQuick
import "../controls" as Aq
import qs.Common
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "../components"
import "../services/DisplayModes.js" as Modes

ColumnLayout {
    id: root
    property var controller
    property string selected: ''
    readonly property var monitors: {
        const configured = controller?.model.snapshot.monitors || [];
        const screens = Quickshell.screens;
        const liveOutputs = controller?.model.snapshot.live_outputs || [];
        const rows = configured.map(m => {
            const screen = screens.find(s => s.name === m.name);
            const live = liveOutputs.find(o => o.name === m.name);
            const draft = controller?.model.draft.monitor_changes[m.id] || {};
            const mode = draft.mode || m.mode || Modes.format(live?.modes?.find(v => v.current));
            const dimensions = Modes.parse(mode);
            const rotated = ['90', '270', 'flipped-90', 'flipped-270'].includes(m.transform);
            // QScreen dimensions already include the current transform; the
            // canvas applies the configured/draft transform to base dimensions.
            const baseWidth = rotated ? screen?.height : screen?.width;
            const baseHeight = rotated ? screen?.width : screen?.height;
            return Object.assign({}, m, {
                connected: !!screen || !!live,
                mirror_of: m.mirror_configured ? m.mirror_of : live?.mirror_of || "",
                mirror_status: live?.mirror_status || "",
                mirror_error: live?.mirror_error || "",
                modes: live?.modes || [],
                mode: mode,
                width: dimensions.width ? dimensions.width / (m.scale_configured ? m.scale : live?.scale || 1) : baseWidth || 1920,
                height: dimensions.height ? dimensions.height / (m.scale_configured ? m.scale : live?.scale || 1) : baseHeight || 1080,
                x: m.x ?? screen?.x ?? 0,
                y: m.y ?? screen?.y ?? 0
            }, controller?.model.draft.monitor_changes[m.id] || {});
        });
        const physical = liveOutputs.concat(screens.filter(s => !liveOutputs.some(o => o.name === s.name)));
        for (const screen of physical)
            if (!rows.some(m => m.name === screen.name)) {
                const id = 'live:' + screen.name;
                const live = liveOutputs.find(o => o.name === screen.name);
                const draft = controller?.model.draft.monitor_changes[id] || {};
                const mode = draft.mode || Modes.format(live?.modes?.find(v => v.current));
                const dimensions = Modes.parse(mode);
                rows.push(Object.assign({
                    id: id,
                    name: screen.name,
                    connected: true,
                    mirror_of: live?.mirror_of || "",
                    mirror_status: live?.mirror_status || "",
                    mirror_error: live?.mirror_error || "",
                    modes: live?.modes || [],
                    mode: mode,
                    width: dimensions.width ? dimensions.width / (live?.scale || 1) : screen.width || 1920,
                    height: dimensions.height ? dimensions.height / (live?.scale || 1) : screen.height || 1080,
                    x: screen.x ?? screen.position?.x ?? 0,
                    y: screen.y ?? screen.position?.y ?? 0,
                    transform: live?.transform || 'normal'
                }, controller?.model.draft.monitor_changes[id] || {}));
            }
        return rows;
    }
    readonly property var monitor: monitors.find(m => m.id === selected) || monitors[0] || null
    spacing: 12
    function stage(m, x, y, transform) {
        if (!Number.isFinite(x) || !Number.isFinite(y))
            return;
        controller.model.mutate(d => d.monitor_changes[m.id] = Object.assign({}, d.monitor_changes[m.id] || {}, {
                id: m.id,
                name: m.name,
                x: Math.round(x),
                y: Math.round(y),
                transform: transform || m.transform || 'normal'
            }));
    }
    function stageMode(resolution, refresh) {
        if (!monitor)
            return;
        try {
            const mode = Modes.compose(resolution, refresh);
            stage(monitor, monitor.x, monitor.y, monitor.transform);
            controller.model.mutate(d => d.monitor_changes[monitor.id].mode = mode);
            controller.model.error('monitor-mode-' + monitor.id, '');
        } catch (e) {
            controller.model.error('monitor-mode-' + monitor.id, String(e));
        }
    }
    Label {
        color: Theme.surfaceText
        text: I18n.trFor('aqueousSettings', 'Drag monitors to arrange them. Positions and orientation are saved only on Apply.')
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    MonitorCanvas {
        Layout.fillWidth: true
        monitors: root.monitors.filter(m => !m.mirror_of)
        selected: root.monitor?.id || ''
        onSelectedMonitor: id => root.selected = id
        onMoved: (monitor, x, y) => root.stage(monitor, x, y)
    }
    Aq.ComboBox {
        Layout.fillWidth: true
        model: root.monitors.map(m => m.name)
        currentIndex: root.monitors.indexOf(root.monitor)
        onActivated: root.selected = root.monitors[currentIndex].id
    }
    readonly property var mirrorSources: {
        const names = root.monitors.filter(m => m.connected && m.id !== root.monitor?.id && !m.mirror_of).map(m => m.name);
        const current = root.monitor?.mirror_of;
        if (current && !names.includes(current)) names.push(current);
        return names;
    }
    Aq.ComboBox {
        Layout.fillWidth: true
        enabled: !!root.monitor
        model: [I18n.trFor('aqueousSettings', 'Extended desktop')].concat(root.mirrorSources.map(n => I18n.trFor('aqueousSettings', 'Mirror of') + ' ' + n))
        currentIndex: root.monitor?.mirror_of ? root.mirrorSources.indexOf(root.monitor.mirror_of) + 1 : 0
        onActivated: {
            const m = root.monitor;
            root.stage(m, m.x, m.y, m.transform);
            controller.model.mutate(d => d.monitor_changes[m.id].mirror_of = currentIndex > 0 ? root.mirrorSources[currentIndex - 1] : '');
        }
    }
    Label {
        Layout.fillWidth: true
        visible: !!root.monitor?.mirror_of
        wrapMode: Text.WordWrap
        color: root.monitor?.mirror_error ? Theme.error : Theme.surfaceText
        text: root.monitor?.mirror_error || I18n.trFor('aqueousSettings', 'Mirroring uses SDR, normal orientation and fixed refresh on the destination. The image is fitted automatically.') + ' ' + (root.monitor?.mirror_status || '')
    }
    RowLayout {
        enabled: !!root.monitor && !root.monitor.mirror_of
        Label {
            color: Theme.surfaceText
            text: I18n.trFor('aqueousSettings', 'X')
        }
        Aq.SpinBox {
            from: -100000
            to: 100000
            value: root.monitor?.x || 0
            editable: true
            onValueModified: root.stage(root.monitor, value, root.monitor.y)
        }
        Label {
            color: Theme.surfaceText
            text: I18n.trFor('aqueousSettings', 'Y')
        }
        Aq.SpinBox {
            from: -100000
            to: 100000
            value: root.monitor?.y || 0
            editable: true
            onValueModified: root.stage(root.monitor, root.monitor.x, value)
        }
        Aq.ComboBox {
            Layout.fillWidth: true
            model: ['normal', '90', '180', '270', 'flipped', 'flipped-90', 'flipped-180', 'flipped-270']
            currentIndex: model.indexOf(root.monitor?.transform || 'normal')
            onActivated: root.stage(root.monitor, root.monitor.x, root.monitor.y, currentText)
        }
    }
    Label {
        color: Theme.surfaceText
        text: I18n.trFor('aqueousSettings', 'Resolution and refresh rate')
        font.bold: true
    }
    RowLayout {
        enabled: !!root.monitor
        Label {
            color: Theme.surfaceText
            text: I18n.trFor('aqueousSettings', 'Resolution')
        }
        Aq.ComboBox {
            id: resolution
            Layout.fillWidth: true
            editable: true
            model: Modes.resolutions(root.monitor)
            currentIndex: model.indexOf(Modes.parse(root.monitor?.mode).resolution)
            onActivated: root.stageMode(currentText, '')
            onAccepted: root.stageMode(editText, '')
        }
        Label {
            color: Theme.surfaceText
            text: 'Hz'
        }
        Aq.ComboBox {
            id: refresh
            Layout.fillWidth: true
            editable: true
            model: [I18n.trFor('aqueousSettings', 'Automatic')].concat(Modes.rates(root.monitor, Modes.parse(root.monitor?.mode).resolution))
            currentIndex: Math.max(0, model.indexOf(Modes.parse(root.monitor?.mode).refresh))
            onActivated: root.stageMode(Modes.parse(root.monitor?.mode).resolution, currentIndex ? currentText : '')
            onAccepted: root.stageMode(Modes.parse(root.monitor?.mode).resolution, editText === model[0] ? '' : editText)
        }
    }
    Label {
        color: Theme.surfaceText
        text: root.monitor?.mode_inherited ? I18n.trFor('aqueousSettings', 'Mode inherited from wm.toml; editing creates an outputs.toml override.') : I18n.trFor('aqueousSettings', 'Select an advertised mode, or type a custom WIDTHxHEIGHT and Hz. Automatic lets Aqueous choose the rate for that resolution.')
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    Label {
        text: root.controller?.model.errors['monitor-mode-' + root.monitor?.id] || ''
        visible: text.length > 0
        color: Theme.error
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    SchemaFields {
        Layout.fillWidth: true
        controller: root.controller
        category: 'displays'
    }
}
