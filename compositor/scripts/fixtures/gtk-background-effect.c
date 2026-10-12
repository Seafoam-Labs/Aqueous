// SPDX-License-Identifier: GPL-3.0-only
#include <gtk/gtk.h>
#include <stdio.h>

static gboolean ready(gpointer data) {
    (void)data;
    puts("GTK_BLUR_READY");
    fflush(stdout);
    return G_SOURCE_REMOVE;
}

static void activate(GtkApplication *app, gpointer data) {
    (void)data;
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "Aqueous GTK blur probe");
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    gtk_window_set_default_size(GTK_WINDOW(window), 320, 240);
    GtkCssProvider *css = gtk_css_provider_new();
    const char *style = "window { background: #404040; box-shadow: none; border: none; border-radius: 0; }";
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_css_provider_load_from_string(css, style);
#else
    gtk_css_provider_load_from_data(css, style, -1);
#endif
    gtk_style_context_add_provider_for_display(gtk_widget_get_display(window),
        GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
    gtk_window_present(GTK_WINDOW(window));
    g_timeout_add(300, ready, NULL);
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.aqueous.GtkBlurProbe", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
