.pragma library

function copy(value) { return JSON.parse(JSON.stringify(value)); }
function empty() {
    return {changes: {}, raw_files: {}, monitor_changes: {}, snap_zone_changes: {}, custom_keybind_changes: {}, window_rule_changes: [], snap_layouts: null, default_snap_layout: '', normalize_stacking: false, sync_cursor: false, sync_typography: false};
}
function dirty(d) {
    return Object.keys(d.changes).length + Object.keys(d.raw_files).length + Object.keys(d.monitor_changes).length + Object.keys(d.snap_zone_changes).length + Object.keys(d.custom_keybind_changes).length + d.window_rule_changes.length + (d.snap_layouts !== null ? 1 : 0) + (d.normalize_stacking ? 1 : 0) + (d.sync_cursor ? 1 : 0) + (d.sync_typography ? 1 : 0);
}
function field(snapshot, id) { return (snapshot.fields || []).find(f => f.id === id); }
function value(snapshot, draft, id) { return id in draft.changes ? draft.changes[id] : field(snapshot, id)?.value; }
function typedFiles(snapshot, d) {
    const files = Object.keys(d.changes).map(id => field(snapshot, id).file);
    if (Object.keys(d.monitor_changes).length) files.push('outputs');
    if (Object.keys(d.custom_keybind_changes).length) files.push('wm');
    if (d.window_rule_changes.length) files.push('rules');
    if (d.snap_layouts !== null || d.normalize_stacking || Object.keys(d.snap_zone_changes).length) files.push('layout');
    return files;
}
function request(snapshot, d, backupDir) {
    if (!snapshot.generation) throw new Error('Load configuration before applying.');
    for (const file of typedFiles(snapshot, d)) {
        if (file in d.raw_files) throw new Error('Both raw and typed edits affect ' + file + '. Discard one set before continuing.');
    }
    const r = {protocol: 1, expected_generation: snapshot.generation, backup_dir: backupDir, create_user_override: true, raw_files: copy(d.raw_files)};
    r.changes = Object.keys(d.changes).sort().map(id => ({id: id, value: d.changes[id]}));
    r.snap_zone_changes = Object.values(d.snap_zone_changes);
    r.monitor_changes = Object.values(d.monitor_changes);
    r.custom_keybind_changes = Object.values(d.custom_keybind_changes);
    r.window_rule_changes = copy(d.window_rule_changes);
    if (d.snap_layouts !== null) { r.snap_layouts = copy(d.snap_layouts); r.default_snap_layout = d.default_snap_layout; }
    if (d.normalize_stacking) r.normalize_stacking = true;
    if (d.sync_typography) r.sync_typography = true;
    if (d.sync_cursor) r.sync_cursor = true;
    return r;
}
function versionAtLeast(version, minimum) {
    const a = String(version).split(/[.+-]/).slice(0,3).map(Number);
    const b = minimum.split('.').map(Number);
    if (a.length !== 3 || a.some(v => !Number.isFinite(v))) return false;
    for (let i = 0; i < 3; i++) { if (a[i] !== b[i]) return a[i] > b[i]; }
    return true;
}
function compatible(response) { return response.protocol === 1 && versionAtLeast(response.helper_version || response.version, '0.7.0'); }
