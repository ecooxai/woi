// Native integration harness: used only by qa/control_overlay_native.py on private displays.
#include "../../app/linux/runner/control_overlay.cc"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <utility>

static ControlOverlay state;
static GtkWidget* entry;
static int clicks = 0;

static bool verify_arrow_palette() {
  const auto* directory = std::getenv("WOI_CONTROL_TEST_OUT");
  for (const auto& sample : {std::pair<const char*, uint32_t>{"", 0x5cbeff},
                             {"left", 0x349be7}, {"right", 0xffa6a6}}) {
    cairo_surface_t* surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, kPointerWidth, kPointerHeight);
    cairo_t* cr = cairo_create(surface);
    state.button = sample.first;
    draw_pointer(nullptr, cr, &state);
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    auto pixel = [surface](int x, int y) {
      return reinterpret_cast<uint32_t*>(cairo_image_surface_get_data(surface) +
        y * cairo_image_surface_get_stride(surface))[x];
    };
    // The triangular head and diagonal stem share the button color. Pixels
    // behind and above the hotspot remain transparent (a circle would fail).
    bool good = (pixel(kPointerHotspot + 4, kPointerHotspot + 12) & 0xffffff) == sample.second &&
                (pixel(kPointerHotspot + 16, kPointerHotspot + 32) & 0xffffff) == sample.second &&
                pixel(kPointerHotspot - 4, kPointerHotspot + 12) == 0 &&
                pixel(kPointerHotspot + 26, kPointerHotspot + 5) == 0;
    if (directory != nullptr) {
      const std::string path = std::string(directory) + "/cursor-" +
        (state.button.empty() ? "neutral" : state.button) + ".png";
      good = good && cairo_surface_write_to_png(surface, path.c_str()) == CAIRO_STATUS_SUCCESS;
    }
    cairo_surface_destroy(surface);
    if (!good) { puts("ARROW_RENDER_FAILED"); return false; }
  }
  state.button.clear();
  return true;
}

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  if (!verify_arrow_palette()) return 3;
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
  state.pointer = window(&state, kPointerWidth, kPointerHeight, G_CALLBACK(draw_pointer));
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
  // Test-only metadata input exercises the same native color setter used by
  // the Flutter channel, immediately before the wrapper injects each click.
  GIOChannel* input = g_io_channel_unix_new(fileno(stdin));
  g_io_add_watch(input, G_IO_IN, +[](GIOChannel* source, GIOCondition, gpointer) -> gboolean {
    gchar* line = nullptr;
    const auto status = g_io_channel_read_line(source, &line, nullptr, nullptr, nullptr);
    if (status == G_IO_STATUS_NORMAL) {
      const std::string button = g_strstrip(line);
      if (button == "left" || button == "right" || button == "none") {
        set_pointer_button(&state, button == "none" ? "" : button);
        printf("BUTTON %s\n", button.c_str()); fflush(stdout);
      }
    }
    g_free(line);
    return status == G_IO_STATUS_EOF || status == G_IO_STATUS_ERROR ? G_SOURCE_REMOVE : G_SOURCE_CONTINUE;
  }, nullptr);
  puts("READY"); fflush(stdout);
  gtk_main();
  g_io_channel_unref(input);
  printf("RESULT arrow_palette=1 hotspot=1 cancelled=%d clicks=%d text=%s\n", state.cancelled, clicks, gtk_entry_get_text(GTK_ENTRY(entry)));
  return 0;
}
