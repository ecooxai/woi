// Native integration harness: used only by qa/control_overlay_native.py on private displays.
#include "../../app/linux/runner/control_overlay.cc"
#include <cstdio>
#include <cstdlib>

static ControlOverlay state;
static GtkWidget* entry;
static int clicks = 0;

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  GtkWidget* target = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(target), "Woi native overlay target");
  gtk_window_set_default_size(GTK_WINDOW(target), 900, 620);
  GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 20);
  gtk_container_add(GTK_CONTAINER(target), box);
  entry = gtk_entry_new();
  gtk_box_pack_start(GTK_BOX(box), entry, FALSE, FALSE, 30);
  GtkWidget* button = gtk_button_new_with_label("Overlay click-through target");
  gtk_widget_set_size_request(button, 400, 120);
  gtk_box_pack_start(GTK_BOX(box), button, TRUE, TRUE, 0);
  g_signal_connect(button, "clicked", G_CALLBACK(+[](GtkButton*, gpointer) { clicks++; }), nullptr);
  gtk_widget_show_all(target);
  gtk_widget_grab_focus(entry);
  if (!start_input_watch(&state)) { puts("NATIVE_UNAVAILABLE"); return 2; }
  state.pointer = window(&state, 48, 48, G_CALLBACK(draw_pointer));
  state.keyboard = window(&state, 88, 64, G_CALLBACK(draw_keyboard));
  state.keys = window(&state, 420, 44, G_CALLBACK(draw_keys));
  state.text = "synthetic test keys";
  gtk_window_move(GTK_WINDOW(state.keyboard), 400, 280);
  gtk_window_move(GTK_WINDOW(state.keys), 500, 10);
  gtk_widget_show(state.pointer);
  gtk_widget_show(state.keyboard);
  gtk_widget_show(state.keys);
  state.active = true;
  state.timer = g_timeout_add(16, tick, &state);
  g_timeout_add(100, +[](gpointer) -> gboolean {
    static bool emitted = false;
    if (state.cancelled && !emitted) { puts("CANCELLED"); fflush(stdout); emitted = true; }
    return G_SOURCE_CONTINUE;
  }, nullptr);
  g_timeout_add_seconds(8, +[](gpointer) -> gboolean { gtk_main_quit(); return G_SOURCE_REMOVE; }, nullptr);
  puts("READY"); fflush(stdout);
  gtk_main();
  printf("RESULT cancelled=%d clicks=%d text=%s\n", state.cancelled, clicks, gtk_entry_get_text(GTK_ENTRY(entry)));
  return 0;
}
