import QtQuick
import QtTest
import "../portal/dms"

TestCase {
    name: "PortalModel"
    PortalModel { id: selection }
    function test_identityAndFilter() {
        verify(selection.load({version: 1, choices: ["Monitor: DP-1 display", "Window: same (1)", "Window: same (2)"]}));
        selection.query = "SAME";
        compare(selection.filtered.length, 2);
        compare(selection.selectedSource, 1);
        selection.move(1);
        compare(selection.selectedSource, 2);
        selection.move(1);
        compare(selection.selectedSource, 1);
        selection.move(-1);
        compare(selection.selectedSource, 2);
        selection.query = "missing";
        compare(selection.selectedSource, -1);
        selection.clear();
        compare(selection.choices.length, 0);
    }
    function test_invalidRequests() {
        verify(!selection.load(null));
        verify(!selection.load({version: 2, choices: ["Monitor: DP-1"]}));
        verify(!selection.load({version: 1, choices: []}));
        verify(!selection.load({version: 1, choices: [null]}));
        verify(!selection.load({version: 1, choices: ["line\nbreak"]}));
        verify(selection.load({version: 1, choices: ["Window: Résumé <b> & $(value) (1)"]}));
        compare(selection.filtered[0].label, "Window: Résumé <b> & $(value) (1)");
    }
}
