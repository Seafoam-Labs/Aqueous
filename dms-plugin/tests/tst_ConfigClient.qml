import QtQuick
import Quickshell
import "../services"

ShellRoot {
    id: test
    property int step: 0
    property int completions: 0
    function check(condition, message) {
        if (!condition) {
            console.error('AQUEOUS_CLIENT_FAIL', message);
            Qt.quit();
            return false;
        }
        return true;
    }
    function next() {
        step++;
        Qt.callLater(() => {
            client.timeoutMs = step === 4 || step === 6 ? 50 : 5000;
            const modes = ['apply', 'malformed', 'failure', 'old', 'delay', 'snapshot', 'snapshot'];
            if (step === 6)
                client.helperPath = '/definitely/missing/aqueous-config';
            if (step > 6) {
                console.log('AQUEOUS_CLIENT_PASS');
                Qt.quit();
                return;
            }
            client.run(modes[step]);
        });
    }
    ConfigClient {
        id: client
        helperPath: Qt.resolvedUrl('fake-helper.py').toString().replace('file://', '')
        onCompleted: (operation, response) => {
            if (test.step === 0) {
                if (!test.check(response.request.raw_files.wm === 'quotes " $() ` ;\n', 'stdin content'))
                    return;
                if (!test.check(Array.isArray(response.request.changes), 'empty array'))
                    return;
            } else if (!test.check(test.step === 5, 'unexpected or stale completion'))
                return;
            test.completions++;
            test.next();
        }
        onFailed: (operation, code, message) => {
            const expected = {
                1: 'invalid_response',
                2: 'external_change',
                3: 'incompatible_helper',
                4: 'timeout',
                6: 'launch_failed'
            };
            if (!test.check(code === expected[test.step], test.step + ': ' + code))
                return;
            test.next();
        }
    }
    Component.onCompleted: {
        client.run('apply', {
            protocol: 1,
            changes: [],
            raw_files: {
                wm: 'quotes " $() ` ;\n'
            }
        });
        check(!client.run('snapshot'), 'serialize requests');
    }
    Timer {
        interval: 15000
        running: true
        onTriggered: {
            console.error('AQUEOUS_CLIENT_FAIL overall timeout');
            Qt.quit();
        }
    }
}
