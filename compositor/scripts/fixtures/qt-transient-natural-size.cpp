// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <QApplication>
#include <QDialog>
#include <QLabel>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QGuiApplication::setDesktopFileName("aqueous-qt-transient-test");

    QWidget parent;
    parent.setWindowTitle("aqueous-qt-parent");
    parent.resize(640, 480);
    parent.show();

    QDialog dialog(&parent);
    dialog.setWindowTitle("aqueous-qt-dialog");
    auto *layout = new QVBoxLayout(&dialog);
    auto *label = new QLabel("A naturally sized Qt portal-style dialog", &dialog);
    label->setMinimumSize(360, 120);
    layout->addWidget(label);

    // Let Qt complete the parent's first Wayland configure before creating the
    // transient, matching the ordering used by portal and OBS dialogs.
    QTimer::singleShot(100, &dialog, [&dialog] {
        dialog.adjustSize();
        dialog.show();
    });
    QTimer::singleShot(30000, &app, &QCoreApplication::quit);

    return app.exec();
}
