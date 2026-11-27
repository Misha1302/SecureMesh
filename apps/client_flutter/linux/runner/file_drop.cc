#include "file_drop.h"

namespace {
void receive(GtkWidget*, GdkDragContext*, gint, gint, GtkSelectionData* data,
             guint, guint, gpointer user_data) {
  bool valid = gtk_selection_data_get_length(data) > 0 &&
               gtk_selection_data_get_length(data) <= 128 * 1024;
  g_auto(GStrv) uris = valid ? gtk_selection_data_get_uris(data) : nullptr;
  valid = uris && uris[0] && g_strv_length(uris) <= 8;
  g_autoptr(FlValue) paths = fl_value_new_list();
  for (guint i = 0; valid && uris[i]; ++i) {
    g_autofree gchar* host = nullptr;
    g_autofree gchar* path = g_filename_from_uri(uris[i], &host, nullptr);
    valid = path && (!host || !*host) && g_utf8_validate(path, -1, nullptr);
    if (valid) fl_value_append_take(paths, fl_value_new_string(path));
  }
  if (valid) {
    fl_method_channel_invoke_method(FL_METHOD_CHANNEL(user_data), "drop", paths,
                                    nullptr, nullptr, nullptr);
  }
  // GTK_DEST_DEFAULT_DROP completes the copy after this handler returns.
}
}  // namespace

void register_file_drop(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto* channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)),
                                        "securemesh/file-drop", FL_METHOD_CODEC(codec));
  GtkTargetEntry uri = {const_cast<gchar*>("text/uri-list"), 0, 0};
  GtkWidget* window = gtk_widget_get_toplevel(GTK_WIDGET(view));
  gtk_drag_dest_set(window, GTK_DEST_DEFAULT_ALL, &uri, 1, GDK_ACTION_COPY);
  g_signal_connect(window, "drag-data-received", G_CALLBACK(receive), channel);
  g_object_set_data_full(G_OBJECT(window), "securemesh-file-drop", channel, g_object_unref);
}
