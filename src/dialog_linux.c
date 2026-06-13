#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>

static int gtk_ready = 0;

void dialog_pump_events(void);

static void ensure_gtk(void) {
    if (!gtk_ready) {
        gtk_ready = gtk_init_check(NULL, NULL);
    }
}

static GtkFileFilter *build_file_filter(const char *filter_name, const char *filter_ext) {
    GtkFileFilter *filter = gtk_file_filter_new();
    if (filter_name) {
        gtk_file_filter_set_name(filter, filter_name);
    }

    if (!filter_ext || filter_ext[0] == '\0') {
        gtk_file_filter_add_pattern(filter, "*");
        return filter;
    }

    char *exts = strdup(filter_ext);
    if (!exts) return filter;

    char *save = NULL;
    for (char *part = strtok_r(exts, ",", &save); part; part = strtok_r(NULL, ",", &save)) {
        while (*part == ' ' || *part == '\t') part++;
        size_t len = strlen(part);
        while (len > 0 && (part[len - 1] == ' ' || part[len - 1] == '\t')) {
            part[--len] = '\0';
        }
        if (len == 0) continue;

        char pattern[256];
        snprintf(pattern, sizeof(pattern), "*.%s", part);
        gtk_file_filter_add_pattern(filter, pattern);
    }

    free(exts);
    return filter;
}

static char *pick_path(GtkFileChooser *chooser) {
    dialog_pump_events();
    const int response = gtk_dialog_run(GTK_DIALOG(chooser));
    dialog_pump_events();
    if (response != GTK_RESPONSE_ACCEPT) {
        return NULL;
    }
    char *filename = gtk_file_chooser_get_filename(chooser);
    if (!filename) return NULL;
    char *dup = strdup(filename);
    g_free(filename);
    return dup;
}

const char *dialog_pick_open_file(const char *title, const char *filter_name, const char *filter_ext) {
    ensure_gtk();
    if (!gtk_ready) return NULL;

    GtkWidget *dialog = gtk_file_chooser_dialog_new(
        title ? title : "Select file",
        NULL,
        GTK_FILE_CHOOSER_ACTION_OPEN,
        "_Cancel", GTK_RESPONSE_CANCEL,
        "_Open", GTK_RESPONSE_ACCEPT,
        NULL);
    gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(dialog), FALSE);

    GtkFileFilter *filter = build_file_filter(filter_name, filter_ext);
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), filter);
    gtk_file_chooser_set_filter(GTK_FILE_CHOOSER(dialog), filter);

    char *path = pick_path(GTK_FILE_CHOOSER(dialog));
    gtk_widget_destroy(dialog);
    return path;
}

const char *dialog_pick_open_directory(const char *title) {
    ensure_gtk();
    if (!gtk_ready) return NULL;

    GtkWidget *dialog = gtk_file_chooser_dialog_new(
        title ? title : "Select folder",
        NULL,
        GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        "_Cancel", GTK_RESPONSE_CANCEL,
        "_Open", GTK_RESPONSE_ACCEPT,
        NULL);
    gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(dialog), FALSE);

    char *path = pick_path(GTK_FILE_CHOOSER(dialog));
    gtk_widget_destroy(dialog);
    return path;
}

const char *dialog_pick_save_file(const char *title, const char *default_name) {
    ensure_gtk();
    if (!gtk_ready) return NULL;

    GtkWidget *dialog = gtk_file_chooser_dialog_new(
        title ? title : "Save file",
        NULL,
        GTK_FILE_CHOOSER_ACTION_SAVE,
        "_Cancel", GTK_RESPONSE_CANCEL,
        "_Save", GTK_RESPONSE_ACCEPT,
        NULL);
    gtk_file_chooser_set_do_overwrite_confirmation(GTK_FILE_CHOOSER(dialog), TRUE);
    if (default_name) {
        gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(dialog), default_name);
    }

    char *path = pick_path(GTK_FILE_CHOOSER(dialog));
    gtk_widget_destroy(dialog);
    return path;
}

void dialog_free_path(const char *path) {
    if (path) free((void *)path);
}

void dialog_pump_events(void) {
    ensure_gtk();
    if (!gtk_ready) return;
    while (gtk_events_pending()) gtk_main_iteration();
}
