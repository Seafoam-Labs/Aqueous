import QtQuick
import qs.Common

Item {
    id: root
    property string state: "unknown"
    property string message: ""
    // DMS Theme.fontSizeMedium is 14 logical pixels. Convert points at 96 DPI;
    // this aligns the normal text tier, not every independently scaled widget.
    function inspect(spec) {
        if (!spec)
            return;
        const scale = spec.size_pt * 96 / 72 / 14;
        const synced = SettingsData.fontFamily === spec.family && SettingsData.fontWeight === spec.weight && Math.abs(SettingsData.fontScale - scale) < 0.001;
        state = synced ? 'partial' : 'out-of-sync';
        message = synced ? 'Family, weight and normal text size synchronized. DMS does not preserve exact face, slant or width; bars may have their own scale.' : 'DMS typography differs from Aqueous.';
    }
    Connections {
        target: SettingsData.settingsFile
        function onSaveFailed(error) {
            root.state = 'failed';
            root.message = 'DMS settings could not be saved. Retry after resolving the settings file error.';
        }
    }
    function apply(spec) {
        try {
            if (!SettingsData._hasLoaded || SettingsData._parseError || SettingsData._isReadOnly)
                throw new Error('DMS settings are not writable.');
            SettingsData.set('fontFamily', spec.family);
            SettingsData.set('fontWeight', spec.weight);
            SettingsData.set('fontScale', spec.size_pt * 96 / 72 / 14);
            inspect(spec);
        } catch (e) {
            state = 'failed';
            message = String(e);
        }
    }
}
