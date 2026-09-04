// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <gtk/gtk.h>
#include <stdio.h>

static gboolean report_titlebar(gpointer data) {
    GtkWindow *window = GTK_WINDOW(data);
    GtkWidget *widget = GTK_WIDGET(window);
    const gboolean client_decorated =
        gtk_widget_has_css_class(widget, "csd") ||
        gtk_widget_has_css_class(widget, "solid-csd");
    puts(client_decorated ? "present" : "absent");
    fflush(stdout);
    g_application_quit(g_application_get_default());
    return G_SOURCE_REMOVE;
}

static void activate(GtkApplication *application, gpointer data) {
    GtkWidget *window = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(window), "Aqueous GTK decoration probe");
    gtk_window_set_default_size(GTK_WINDOW(window), 320, 200);
    if (GPOINTER_TO_INT(data) != 0)
        gtk_window_set_titlebar(GTK_WINDOW(window), gtk_header_bar_new());
    gtk_window_present(GTK_WINDOW(window));
    g_idle_add(report_titlebar, window);
}

int main(int argc, char **argv) {
    const gboolean custom_titlebar = argc > 1;
    GtkApplication *application = gtk_application_new(
        "org.aqueous.GtkServerDecorationProbe", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(application, "activate", G_CALLBACK(activate),
                     GINT_TO_POINTER(custom_titlebar));
    const int status = g_application_run(G_APPLICATION(application), 1, argv);
    g_object_unref(application);
    return status;
}
