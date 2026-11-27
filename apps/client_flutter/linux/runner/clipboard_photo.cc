#include "clipboard_photo.h"

#include <gtk/gtk.h>

namespace {
constexpr gint kMaxBytes = 4 * 1024 * 1024;

void got_contents(GtkClipboard* clipboard, GtkSelectionData* data, gpointer user_data) {
  FlMethodCall* call = FL_METHOD_CALL(user_data);
  const gint length = gtk_selection_data_get_length(data);
  if (length <= 0 && gtk_selection_data_get_target(data) == gdk_atom_intern_static_string("image/png")) {
    gtk_clipboard_request_contents(clipboard, gdk_atom_intern_static_string("image/jpeg"),
                                   got_contents, call);
    return;
  }
  if (length > kMaxBytes) {
    fl_method_call_respond_error(call, "size", nullptr, nullptr, nullptr);
  } else if (length > 0) {
    g_autoptr(FlValue) bytes = fl_value_new_uint8_list(gtk_selection_data_get_data(data), length);
    fl_method_call_respond_success(call, bytes, nullptr);
  } else {
    fl_method_call_respond_success(call, nullptr, nullptr);
  }
  g_object_unref(call);
}

void read_clipboard(FlMethodChannel*, FlMethodCall* call, gpointer) {
  if (g_strcmp0(fl_method_call_get_name(call), "read") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  gtk_clipboard_request_contents(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD),
                                 gdk_atom_intern_static_string("image/png"),
                                 got_contents, g_object_ref(call));
}
}  // namespace

void register_clipboard_photo(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "securemesh/clipboard-photo", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, read_clipboard, nullptr, nullptr);
  g_object_set_data_full(G_OBJECT(view), "securemesh-clipboard-photo", channel, g_object_unref);
}
