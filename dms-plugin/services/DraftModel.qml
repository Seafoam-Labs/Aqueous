import QtQuick
import "Draft.js" as Draft

QtObject {
    id: root
    property var snapshot: ({
            fields: [],
            files: {},
            raw_files: {}
        })
    property var draft: Draft.empty()
    property var errors: ({})
    readonly property int count: Draft.dirty(draft)
    readonly property bool hasErrors: Object.keys(errors).length > 0
    function accept(data) {
        snapshot = data;
        draft = Draft.empty();
        errors = {};
    }
    function value(id) {
        return Draft.value(snapshot, draft, id);
    }
    function error(key, message) {
        const next = Object.assign({}, errors);
        if (message)
            next[key] = message;
        else
            delete next[key];
        errors = next;
    }
    function change(id, value) {
        const next = Draft.copy(draft);
        const original = Draft.field(snapshot, id);
        if (JSON.stringify(value) === JSON.stringify(original?.value))
            delete next.changes[id];
        else
            next.changes[id] = value;
        draft = next;
    }
    function raw(file, text) {
        const next = Draft.copy(draft);
        if (text === snapshot.raw_files[file])
            delete next.raw_files[file];
        else
            next.raw_files[file] = text;
        draft = next;
    }
    function mutate(callback) {
        const next = Draft.copy(draft);
        callback(next);
        draft = next;
    }
    function request(backupDir) {
        if (hasErrors)
            throw new Error(Object.values(errors).join('\n'));
        return Draft.request(snapshot, draft, backupDir);
    }
    function keybind(id, chord, command, remove) {
        mutate(d => {
            if (remove && id.startsWith('new:'))
                delete d.custom_keybind_changes[id];
            else
                d.custom_keybind_changes[id] = {
                    id: id,
                    op: remove ? 'delete' : id.startsWith('new:') ? 'add' : 'update',
                    chord: chord,
                    command: command
                };
        });
    }
    function keybinds() {
        const changes = draft.custom_keybind_changes;
        return (snapshot.custom_keybinds || []).map(k => changes[k.id] || k).concat(Object.values(changes).filter(k => k.op === 'add')).filter(k => k.op !== 'delete');
    }
    function addBinding(command) {
        keybind('new:' + Date.now(), '', command || 'spawn:');
    }
    function rule(operation) {
        const pending = draft.window_rule_changes;
        if (operation.op === 'move' && pending.length)
            throw new Error('Apply or discard rule edits before moving a rule.');
        if (pending.some(o => o.op === 'move'))
            throw new Error('Apply or discard the staged rule move first.');
        mutate(d => {
            const i = d.window_rule_changes.findIndex(o => o.id === operation.id);
            if (i < 0)
                d.window_rule_changes.push(operation);
            else if (operation.op === 'delete') {
                if (d.window_rule_changes[i].op === 'add')
                    d.window_rule_changes.splice(i, 1);
                else
                    d.window_rule_changes[i] = operation;
            } else
                d.window_rule_changes[i].values = Object.assign({}, d.window_rule_changes[i].values, operation.values);
        });
    }
    function rules() {
        let rows = Draft.copy(snapshot.window_rules || []);
        for (const op of draft.window_rule_changes) {
            const i = rows.findIndex(r => r.id === op.id);
            if (op.op === 'add')
                rows.push({
                    id: op.id,
                    values: op.values
                });
            else if (i >= 0 && op.op === 'delete')
                rows.splice(i, 1);
            else if (i >= 0 && op.op === 'update')
                rows[i].values = Object.assign(rows[i].values, op.values);
            else if (i >= 0 && op.op === 'move') {
                const j = Math.max(0, Math.min(rows.length - 1, i + op.direction));
                rows.splice(j, 0, rows.splice(i, 1)[0]);
            }
        }
        return rows;
    }
    function layouts() {
        return draft.snap_layouts !== null ? draft.snap_layouts : snapshot.snap_layouts || [];
    }
    function editLayouts(callback) {
        mutate(d => {
            if (d.snap_layouts === null) {
                d.snap_layouts = Draft.copy(snapshot.snap_layouts || []);
                d.default_snap_layout = snapshot.default_snap_layout || '';
            }
            callback(d);
        });
    }
}
