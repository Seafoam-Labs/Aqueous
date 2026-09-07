// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only
// No network content or user profile: reproduce close-to-tray using one
// persistent BrowserWindow, controlled through stdin like window-remap.c.
const { app, BrowserWindow } = require('electron');
const name = 'aqueous.remap-target';
app.setName(name);
let quitting = false;
app.on('before-quit', () => { quitting = true; });
app.whenReady().then(async () => {
    const window = new BrowserWindow({
        width: 320, height: 240, title: name,
        backgroundColor: '#e03070', frame: false,
    });
    window.on('close', event => {
        if (!quitting) {
            event.preventDefault();
            window.hide();
        }
    });
    for (const event of ['show', 'hide', 'resize', 'focus']) {
        window.on(event, () => console.log(event, JSON.stringify(window.getBounds())));
    }
    await window.loadURL('data:text/html,' + encodeURIComponent(
        `<title>${name}</title><style>html,body{margin:0;width:100%;height:100%;background:#e03070}</style>`));
    console.log('WINDOW', window.id);
    process.stdin.on('data', data => {
        for (const command of data.toString()) {
            if (command === 'h') window.close();
            if (command === 's') window.show();
            if (command === 'q') app.quit();
        }
    });
    process.stdin.on('end', () => app.quit());
});
