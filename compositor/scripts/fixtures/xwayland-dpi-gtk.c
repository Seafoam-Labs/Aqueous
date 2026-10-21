// SPDX-License-Identifier: GPL-3.0-only
#include <gtk/gtk.h>
#include <stdio.h>
int main(int argc, char **argv) {
    gtk_init(&argc, &argv);
    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_default_size(GTK_WINDOW(window), 200, 100);
    GtkWidget *button = gtk_button_new_with_label("Scaling probe");
    gtk_container_add(GTK_CONTAINER(window), button);
    gtk_widget_show_all(window);
    while (gtk_events_pending()) gtk_main_iteration();
    GdkWindow *surface = gtk_widget_get_window(window);
    int scale = gdk_window_get_scale_factor(surface);
    printf("{\"scale\":%d,\"font_dpi\":%.8f,\"logical_width\":%d,\"buffer_width\":%d}\n",
        scale, gdk_screen_get_resolution(gtk_widget_get_screen(window)),
        gdk_window_get_width(surface), gdk_window_get_width(surface) * scale);
    gtk_widget_destroy(window);
}
