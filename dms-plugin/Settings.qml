import QtQuick
import qs.Common
import qs.Modules.Plugins

PluginSettings {
    pluginId: "aqueousSettings"
    StringSetting {
        settingKey: "helperPath"
        label: I18n.trFor("aqueousSettings", "Configuration helper")
        description: I18n.trFor("aqueousSettings", "Executable path to aqueous-config 0.7.0 or newer.")
        defaultValue: "aqueous-config"
    }
}
