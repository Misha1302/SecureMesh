#include <gtk/gtk.h>
#include <stdio.h>

static gboolean finish(gpointer unused) {
  (void)unused;
  gtk_main_quit();
  return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
  gtk_init(&argc, &argv);
  if (argc != 2) return 2;
  gchar *text = NULL;
  if (!g_file_get_contents(argv[1], &text, NULL, NULL)) return 3;
  GtkClipboard *clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  gtk_clipboard_set_text(clipboard, text, -1);
  puts("ready"); fflush(stdout);
  g_timeout_add(2000, finish, NULL);
  gtk_main();
  gtk_clipboard_clear(clipboard);
  g_free(text);
  return 0;
}
