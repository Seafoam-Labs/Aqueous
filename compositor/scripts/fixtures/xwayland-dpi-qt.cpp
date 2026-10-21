// SPDX-License-Identifier: GPL-3.0-only
#include <QApplication>
#include <QPushButton>
#include <QScreen>
#include <QWidget>
#include <cstdio>
int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QWidget window;
    window.resize(200, 100);
    QPushButton button("Scaling probe", &window);
    button.adjustSize();
    window.show();
    app.processEvents();
    QPixmap pixels = window.grab();
    std::printf("{\"dpr\":%.8f,\"logical_width\":%d,\"buffer_width\":%d,\"button_width\":%d}\n",
        window.devicePixelRatioF(), window.width(), pixels.width(), button.width());
}
