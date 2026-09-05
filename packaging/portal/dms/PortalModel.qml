import QtQuick

QtObject {
    id: root
    property var choices: []
    property string query: ""
    property int currentIndex: 0
    readonly property var filtered: {
        const needle = query.toLocaleLowerCase();
        return choices.map((label, index) => ({label: label, sourceIndex: index}))
            .filter(entry => entry.label.toLocaleLowerCase().includes(needle));
    }
    readonly property int selectedSource: filtered.length && currentIndex >= 0 && currentIndex < filtered.length
        ? filtered[currentIndex].sourceIndex : -1
    onQueryChanged: currentIndex = 0

    function load(request) {
        if (!request || request.version !== 1 || !Array.isArray(request.choices)
            || request.choices.length === 0 || request.choices.length > 4096
            || !request.choices.every(label => typeof label === "string" && label.length > 0
                && !label.includes("\n") && !label.includes("\u0000")))
            return false;
        choices = request.choices.slice();
        query = "";
        currentIndex = 0;
        return true;
    }

    function move(delta) {
        if (filtered.length)
            currentIndex = (currentIndex + delta + filtered.length) % filtered.length;
    }

    function clear() {
        choices = [];
        query = "";
        currentIndex = 0;
    }
}
