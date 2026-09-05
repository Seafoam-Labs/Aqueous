import QtQuick
import "../controls" as Aq
import qs.Common
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

ColumnLayout {
    id: root
    property var controller
    property int selected: 0
    readonly property var layouts: controller?.model.layouts() || []
    readonly property var layout: layouts[selected] || null
    spacing: 12
    function edit(callback) {
        controller.model.editLayouts(d => {
            if (d.snap_layouts[selected])
                callback(d.snap_layouts[selected], d);
        });
    }
    function add(migrate) {
        controller.model.editLayouts(d => {
            const id = 'layout' + Date.now();
            const zones = migrate ? (controller.model.snapshot.snap_zones || []).filter(z => z.complete).map(z => ({
                        id: z.id,
                        name: z.id.toUpperCase(),
                        x: z.x,
                        y: z.y,
                        width: z.width,
                        height: z.height
                    })) : [
                {
                    id: 'main',
                    name: 'Main',
                    x: 0,
                    y: 0,
                    width: 1,
                    height: 1
                }
            ];
            d.snap_layouts.push({
                id: id,
                name: 'New layout',
                padding: 0,
                zones: zones
            });
            if (!d.default_snap_layout)
                d.default_snap_layout = id;
        });
        selected = layouts.length - 1;
    }
    function preset(kind) {
        edit(l => {
            const n = kind === 'thirds' ? 3 : kind === 'quarters' ? 4 : 2;
            l.zones = Array.from({
                length: n
            }, (_, i) => ({
                        id: 'zone' + (i + 1),
                        name: 'Zone ' + (i + 1),
                        x: kind === 'quarters' ? (i % 2) / 2 : i / n,
                        y: kind === 'quarters' ? Math.floor(i / 2) / 2 : 0,
                        width: kind === 'quarters' ? 0.5 : 1 / n,
                        height: kind === 'quarters' ? 0.5 : 1
                    }));
        });
    }
    Label {
        text: I18n.trFor('aqueousSettings', 'Named stacking snap layouts')
        font.bold: true
    }
    RowLayout {
        Aq.ComboBox {
            Layout.fillWidth: true
            model: root.layouts.map(l => l.name || l.id)
            currentIndex: root.selected
            onActivated: root.selected = currentIndex
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Add layout')
            enabled: root.layouts.length < 8
            onClicked: root.add(false)
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Migrate A–D')
            enabled: root.layouts.length < 8
            onClicked: root.add(true)
        }
    }
    RowLayout {
        visible: !!root.layout
        Aq.TextField {
            Layout.fillWidth: true
            text: root.layout?.id || ''
            placeholderText: I18n.trFor('aqueousSettings', 'Layout ID')
            onTextEdited: root.edit((l, d) => {
                if (d.default_snap_layout === l.id)
                    d.default_snap_layout = text;
                l.id = text;
            })
        }
        Aq.TextField {
            Layout.fillWidth: true
            text: root.layout?.name || ''
            placeholderText: I18n.trFor('aqueousSettings', 'Name')
            onTextEdited: root.edit(l => l.name = text)
        }
        Aq.SpinBox {
            from: 0
            to: 1024
            value: root.layout?.padding || 0
            editable: true
            onValueModified: root.edit(l => l.padding = value)
        }
    }
    Flow {
        Layout.fillWidth: true
        spacing: 6
        visible: !!root.layout
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Make default')
            onClicked: root.controller.model.editLayouts(d => d.default_snap_layout = root.layout.id)
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Bind layout')
            onClicked: root.controller.model.addBinding('builtin:set_snap_layout:' + root.layout.id)
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Bind cycle')
            onClicked: root.controller.model.addBinding('builtin:cycle_snap_layout')
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Remove layout')
            onClicked: {
                root.controller.model.editLayouts(d => {
                    const removed = d.snap_layouts.splice(root.selected, 1)[0];
                    if (d.default_snap_layout === removed.id)
                        d.default_snap_layout = d.snap_layouts[0]?.id || '';
                });
                root.selected = Math.max(0, root.selected - 1);
            }
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Halves')
            onClicked: root.preset('halves')
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Thirds')
            onClicked: root.preset('thirds')
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Quarters')
            onClicked: root.preset('quarters')
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Add zone')
            enabled: (root.layout?.zones.length || 0) < 16
            onClicked: root.edit(l => l.zones.push({
                    id: 'zone' + Date.now(),
                    name: 'New zone',
                    x: 0,
                    y: 0,
                    width: 0.5,
                    height: 0.5
                }))
        }
    }
    Label {
        text: 'Default: ' + (root.controller?.model.draft.snap_layouts !== null ? root.controller?.model.draft.default_snap_layout || '' : root.controller?.model.snapshot.default_snap_layout || '')
    }
    Repeater {
        model: root.layout?.zones.length || 0
        ColumnLayout {
            id: zoneRow
            required property int index
            readonly property var zone: root.layout.zones[index]
            Layout.fillWidth: true
            RowLayout {
                Aq.TextField {
                    Layout.fillWidth: true
                    text: zoneRow.zone?.id || ''
                    placeholderText: I18n.trFor('aqueousSettings', 'Zone ID')
                    onTextEdited: root.edit(l => l.zones[zoneRow.index].id = text)
                }
                Aq.TextField {
                    Layout.fillWidth: true
                    text: zoneRow.zone?.name || ''
                    placeholderText: I18n.trFor('aqueousSettings', 'Name')
                    onTextEdited: root.edit(l => l.zones[zoneRow.index].name = text)
                }
                Aq.Button {
                    text: I18n.trFor('aqueousSettings', 'Bind zone')
                    onClicked: root.controller.model.addBinding('builtin:snap_zone:' + root.layout.id + '/' + zoneRow.zone.id)
                }
                Aq.Button {
                    text: I18n.trFor('aqueousSettings', '×')
                    onClicked: root.edit(l => l.zones.splice(zoneRow.index, 1))
                }
            }
            RowLayout {
                Repeater {
                    model: ['x', 'y', 'width', 'height']
                    Aq.TextField {
                        required property string modelData
                        Layout.fillWidth: true
                        text: String(zoneRow.zone?.[modelData] ?? 0)
                        placeholderText: modelData + ' (0–1)'
                        onTextEdited: {
                            // Preserve invalid input in the request; the helper reports validation.
                            const number = Number(text);
                            root.edit(l => l.zones[zoneRow.index][modelData] = text.trim() && Number.isFinite(number) ? number : text);
                        }
                    }
                }
            }
        }
    }
    Aq.Button {
        text: I18n.trFor('aqueousSettings', 'Normalize legacy Stacking aliases on Apply')
        onClicked: root.controller.model.mutate(d => d.normalize_stacking = true)
    }
    LegacyZones {
        Layout.fillWidth: true
        controller: root.controller
    }
    SchemaFields {
        Layout.fillWidth: true
        controller: root.controller
        category: 'layouts'
    }
}
