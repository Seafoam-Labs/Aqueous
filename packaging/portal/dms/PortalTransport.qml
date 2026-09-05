import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root
    property string token: ""
    property bool replied: false
    readonly property bool busy: token.length > 0
    signal requestReceived(var request)
    signal ended

    function open(requestToken) {
        if (busy)
            return "busy";
        if (!/^[0-9a-f]{32}$/.test(requestToken) || !Quickshell.env("XDG_RUNTIME_DIR"))
            return "invalid request";
        token = requestToken;
        replied = false;
        connection.active = true;
        deadline.restart();
        return "opened";
    }

    function finish(index) {
        if (!busy || replied)
            return;
        replied = true;
        if (connection.item && connection.item.connected) {
            connection.item.write(JSON.stringify({index: index}) + "\n");
            connection.item.flush();
            // Keep the socket alive until the bridge consumes the response.
            deadline.restart();
        } else {
            reset();
        }
    }

    function reset() {
        deadline.stop();
        connection.active = false;
        token = "";
        replied = false;
        ended();
    }

    Timer {
        id: deadline
        interval: 5000
        onTriggered: root.reset()
    }
    Loader {
        id: connection
        active: false
        onLoaded: item.connected = true
        sourceComponent: Socket {
            path: Quickshell.env("XDG_RUNTIME_DIR") + "/aqueous-portal/" + root.token + ".sock"
            onConnectionStateChanged: {
                if (!connected)
                    Qt.callLater(root.reset);
            }
            onError: error => {
                console.warn("aqueousPortal: socket error", error);
                Qt.callLater(root.reset);
            }
            parser: SplitParser {
                onRead: data => {
                    if (root.replied)
                        return;
                    deadline.stop();
                    try {
                        root.requestReceived(JSON.parse(data));
                    } catch (e) {
                        console.warn("aqueousPortal: invalid request", e);
                        root.finish(null);
                    }
                }
            }
        }
    }
}
