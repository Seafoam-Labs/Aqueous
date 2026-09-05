import QtQuick
import Quickshell.Io
import "Draft.js" as Draft

Item {
    id: root
    property string helperPath: "aqueous-config"
    property bool busy: false
    property string operation: ""
    property int timeoutMs: 30000
    property var activeProcess: null
    signal completed(string operation, var response)
    signal failed(string operation, string code, string message)

    function run(mode, request) {
        if (busy)
            return false;
        const input = request ? JSON.stringify(request) : '';
        const process = processFactory.createObject(root, {
            command: [helperPath, mode, '--shell', 'dms'].concat(input ? ['--request', '-'] : []),
            input: input,
            stdinEnabled: input.length > 0
        });
        operation = mode;
        activeProcess = process;
        busy = true;
        watchdog.restart();
        process.running = true;
        return true;
    }
    function release() {
        watchdog.stop();
        const previous = activeProcess;
        activeProcess = null;
        busy = false;
        if (previous) {
            previous.running = false;
            Qt.callLater(() => previous.destroy());
        }
    }
    function fail(code, message) {
        const mode = operation;
        release();
        failed(mode, code, message);
    }
    function finish(process, exitCode, exitStatus, output, errors) {
        if (process !== activeProcess)
            return;
        let response;
        try {
            response = JSON.parse(output);
        } catch (e) {
            fail('invalid_response', errors || 'Helper returned invalid JSON. Reload before retrying an uncertain Apply.');
            return;
        }
        if (exitCode !== 0 || exitStatus !== 0 || !response.ok) {
            fail(response.code || 'process_failed', response.message || errors || 'Helper failed.');
            return;
        }
        if (!Draft.compatible(response)) {
            fail('incompatible_helper', 'Aqueous Settings requires aqueous-config 0.7.0 or newer with protocol 1.');
            return;
        }
        const mode = operation;
        release();
        completed(mode, response);
    }
    Component {
        id: processFactory
        Process {
            id: process
            property string input: ''
            property bool hasStarted: false
            stdout: StdioCollector {
                id: output
            }
            stderr: StdioCollector {
                id: errors
            }
            onStarted: {
                hasStarted = true;
                if (input) {
                    write(input);
                    stdinEnabled = false;
                }
            }
            onExited: (exitCode, exitStatus) => root.finish(process, exitCode, exitStatus, output.text, errors.text)
        }
    }
    Timer {
        id: watchdog
        interval: root.timeoutMs
        onTriggered: root.fail(root.activeProcess?.hasStarted ? 'timeout' : 'launch_failed', root.activeProcess?.hasStarted ? 'Helper did not finish. Reload to inspect current configuration before retrying Apply.' : 'Cannot launch ' + root.helperPath + '. Check the executable path in plugin settings.')
    }
}
