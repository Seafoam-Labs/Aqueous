import QtQuick
import qs.Common
import "services/Draft.js" as Draft

QtObject {
    function check(done) {
        const preferences = SettingsData.getPluginSettingsForPlugin('aqueousSettings');
        Proc.runCommand('aqueousSettings.startup', [preferences.helperPath || 'aqueous-config', 'version'], (stdout, exitCode) => {
            try {
                const response = JSON.parse(stdout);
                if (exitCode === 0 && response.ok && Draft.compatible(response)) {
                    done(null);
                    return;
                }
            } catch (e) {}
            done({
                title: 'Aqueous configuration helper is unavailable',
                details: 'Install aqueous-config 0.7.0 or newer, check the helper path in plugin settings, and re-enable the plugin.'
            });
        });
    }
}
