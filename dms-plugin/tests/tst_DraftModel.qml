import QtQuick
import QtTest
import "../services"
import "../services/Draft.js" as Draft
import "../services/DisplayModes.js" as Modes

TestCase {
    name: 'AqueousDraftModel'
    DraftModel {
        id: model
    }
    function makeSnapshot() {
        return {
            generation: 'abc',
            fields: [
                {
                    id: 'gap',
                    file: 'layout',
                    value: 8
                },
                {
                    id: 'font',
                    file: 'appearance',
                    value: 'Sans'
                }
            ],
            raw_files: {
                layout: '# comment\n[layout]\ngap = 8\n'
            },
            custom_keybinds: [
                {
                    id: 'key:1',
                    chord: 'Super+A',
                    command: 'spawn:a'
                }
            ],
            window_rules: [
                {
                    id: 'rule:1',
                    values: {
                        app_id: 'a',
                        unknown: 'keep'
                    }
                },
                {
                    id: 'rule:2',
                    values: {
                        app_id: 'b'
                    }
                }
            ],
            snap_layouts: []
        };
    }
    function init() {
        model.accept(makeSnapshot());
    }
    function test_typedRoundTrip() {
        model.change('gap', 12);
        compare(model.snapshot.fields[0].value, 8);
        compare(model.request('/tmp/backups').changes[0].value, 12);
        compare(model.request('/tmp/backups').expected_generation, 'abc');
        model.change('gap', 8);
        compare(model.count, 0);
    }
    function test_conflictingRawTyped() {
        model.change('gap', 10);
        model.raw('layout', '[layout]\ngap = 20\n');
        let failed = false;
        try {
            model.request('/tmp');
        } catch (e) {
            failed = String(e).includes('raw and typed');
        }
        verify(failed);
        compare(model.count, 2);
    }
    function test_emptyCollectionsAreArrays() {
        const r = model.request('/tmp');
        verify(Array.isArray(r.changes));
        verify(Array.isArray(r.monitor_changes));
        model.editLayouts(d => {
            d.snap_layouts = [];
            d.default_snap_layout = '';
        });
        verify(Array.isArray(model.request('/tmp').snap_layouts));
    }
    function test_bindings() {
        model.keybind('new:1', 'Super+B', 'spawn:b');
        model.keybind('new:1', 'Super+C', 'spawn:c');
        compare(model.keybinds().length, 2);
        compare(model.request('/tmp').custom_keybind_changes[0].op, 'add');
        model.keybind('new:1', '', '', true);
        compare(model.count, 0);
        model.keybind('key:1', '', '', true);
        compare(model.keybinds().length, 0);
    }
    function test_ruleEditsMerge() {
        model.rule({
            id: 'new-rule:1',
            op: 'add',
            values: {
                app_id: 'x'
            }
        });
        model.rule({
            id: 'new-rule:1',
            op: 'update',
            values: {
                focus: false
            }
        });
        const ops = model.request('/tmp').window_rule_changes;
        compare(ops.length, 1);
        compare(ops[0].op, 'add');
        compare(ops[0].values.focus, false);
        model.rule({
            id: 'new-rule:1',
            op: 'delete'
        });
        compare(model.count, 0);
        model.rule({
            id: 'rule:1',
            op: 'update',
            values: {
                layout: 'stacking'
            }
        });
        compare(model.rules()[0].values.unknown, 'keep');
    }
    function test_ruleMoveIsolation() {
        model.rule({
            id: 'rule:2',
            op: 'move',
            direction: -1
        });
        compare(model.rules()[0].id, 'rule:2');
        let rejected = false;
        try {
            model.rule({
                id: 'rule:1',
                op: 'delete'
            });
        } catch (e) {
            rejected = true;
        }
        verify(rejected);
    }
    function test_invalidInputBlocksRequest() {
        model.error('gap', 'Invalid gap');
        verify(model.hasErrors);
        let rejected = false;
        try {
            model.request('/tmp');
        } catch (e) {
            rejected = true;
        }
        verify(rejected);
        model.error('gap', '');
        verify(!model.hasErrors);
    }
    function test_compatibility() {
        verify(!Draft.compatible({
            protocol: 1,
            version: '0.6.0'
        }));
        verify(Draft.compatible({
            protocol: 1,
            version: '0.7.0'
        }));
        verify(!Draft.compatible({
            protocol: 2,
            version: '0.7.0'
        }));
        verify(!Draft.compatible({
            protocol: 1,
            version: 'broken'
        }));
    }
    function test_displayModes() {
        const monitor = {
            mode: '2560x1440@59.94',
            modes: [
                {
                    width: 2560,
                    height: 1440,
                    refresh: 59.94
                },
                {
                    width: 2560,
                    height: 1440,
                    refresh: 143.999
                },
                {
                    width: 1920,
                    height: 1080,
                    refresh: 60
                }
            ]
        };
        compare(Modes.resolutions(monitor), ['2560x1440', '1920x1080']);
        compare(Modes.rates(monitor, '2560x1440'), ['143.999', '59.94']);
        compare(Modes.rates(monitor, '1920x1080'), ['60']);
        compare(Modes.compose('2560x1440', '59.94'), '2560x1440@59.94');
        compare(Modes.compose('2560x1440', ''), '2560x1440');
        compare(Modes.resolutions({
            mode: '3840x2160@120',
            modes: []
        }), ['3840x2160']);
        let rejected = false;
        try {
            Modes.compose('0x1080', '60');
        } catch (e) {
            rejected = true;
        }
        verify(rejected);
        model.mutate(d => d.monitor_changes['live:DP-1'] = {
                id: 'live:DP-1',
                name: 'DP-1',
                x: 0,
                y: 0,
                transform: 'normal',
                mode: '2560x1440@59.94'
            });
        compare(model.request('/tmp').monitor_changes[0].mode, '2560x1440@59.94');
    }
}
