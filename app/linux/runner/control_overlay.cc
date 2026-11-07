#include "control_overlay.h"

#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <unordered_set>

namespace {
constexpr int kPointerWidth = 40;
constexpr int kPointerHeight = 52;
constexpr int kPointerHotspot = 6;

struct ControlOverlay {
  GtkWidget* pointer = nullptr;
  GtkWidget* keyboard = nullptr;
  GtkWidget* keys = nullptr;
  Display* display = nullptr;
  int xi_opcode = 0;
  guint timer = 0;
  bool active = false;
  bool ready = false;
  bool cancelled = false;
  std::string kind;
  std::string text;
  std::string button;
  std::unordered_set<int> synthetic;
};

void clear(cairo_t* cr) {
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);
  cairo_paint(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
}

gboolean draw_pointer(GtkWidget*, cairo_t* cr, gpointer data) {
  const auto* state = static_cast<ControlOverlay*>(data);
  clear(cr);
  // The arrow tip is the pointer hotspot. Match this path and palette on Android.
  cairo_translate(cr, kPointerHotspot, kPointerHotspot);
  cairo_move_to(cr, 0, 0);
  cairo_line_to(cr, 0, 30);
  cairo_line_to(cr, 8, 23);
  cairo_line_to(cr, 15, 38);
  cairo_line_to(cr, 22, 35);
  cairo_line_to(cr, 14, 20);
  cairo_line_to(cr, 27, 20);
  cairo_close_path(cr);
  // A white edge keeps the cursor visible over both light and dark content.
  cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
  cairo_set_line_width(cr, 4);
  cairo_set_source_rgba(cr, 1, 1, 1, 0.96);
  cairo_stroke_preserve(cr);
  if (state->button == "right") cairo_set_source_rgb(cr, 1, 166.0 / 255, 166.0 / 255);
  else if (state->button == "left") cairo_set_source_rgb(cr, 52.0 / 255, 155.0 / 255, 231.0 / 255);
  else cairo_set_source_rgb(cr, 92.0 / 255, 190.0 / 255, 1);
  cairo_fill_preserve(cr);
  if (state->button == "right") cairo_set_source_rgb(cr, 204.0 / 255, 93.0 / 255, 102.0 / 255);
  else cairo_set_source_rgb(cr, 31.0 / 255, 109.0 / 255, 170.0 / 255);
  cairo_set_line_width(cr, 1.25);
  cairo_stroke(cr);
  return TRUE;
}

gboolean draw_keyboard(GtkWidget*, cairo_t* cr, gpointer) {
  clear(cr);
  cairo_set_source_rgba(cr, 0.74, 0.89, 1.0, 0.98);
  cairo_rectangle(cr, 3, 3, 82, 56);
  cairo_fill_preserve(cr);
  cairo_set_source_rgb(cr, 0.27, 0.61, 0.86);
  cairo_set_line_width(cr, 2);
  cairo_stroke(cr);
  for (int row = 0; row < 3; row++) {
    for (int col = 0; col < 6; col++) {
      cairo_rectangle(cr, 13 + col * 10, 13 + row * 10, 6, 6);
      cairo_fill(cr);
    }
  }
  cairo_rectangle(cr, 24, 45, 40, 5);
  cairo_fill(cr);
  return TRUE;
}

gboolean draw_keys(GtkWidget* widget, cairo_t* cr, gpointer data) {
  auto* state = static_cast<ControlOverlay*>(data);
  clear(cr);
  const int width = gtk_widget_get_allocated_width(widget);
  cairo_set_source_rgba(cr, 0.80, 0.92, 1.0, 0.97);
  cairo_rectangle(cr, 0, 0, width, 44);
  cairo_fill(cr);
  cairo_set_source_rgb(cr, 0.12, 0.31, 0.46);
  PangoLayout* layout = gtk_widget_create_pango_layout(widget, state->text.c_str());
  PangoFontDescription* font = pango_font_description_from_string("Sans 12");
  pango_layout_set_font_description(layout, font);
  pango_layout_set_width(layout, (width - 24) * PANGO_SCALE);
  pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_MIDDLE);
  pango_layout_set_single_paragraph_mode(layout, TRUE);
  cairo_move_to(cr, 12, 12);
  pango_cairo_show_layout(cr, layout);
  pango_font_description_free(font);
  g_object_unref(layout);
  return TRUE;
}

GtkWidget* window(ControlOverlay* state, int width, int height, GCallback draw) {
  GtkWidget* widget = gtk_window_new(GTK_WINDOW_POPUP);
  gtk_window_set_title(GTK_WINDOW(widget), "Woi control indicator");
  gtk_window_set_accept_focus(GTK_WINDOW(widget), FALSE);
  gtk_window_set_focus_on_map(GTK_WINDOW(widget), FALSE);
  gtk_window_set_skip_taskbar_hint(GTK_WINDOW(widget), TRUE);
  gtk_window_set_skip_pager_hint(GTK_WINDOW(widget), TRUE);
  gtk_window_set_keep_above(GTK_WINDOW(widget), TRUE);
  gtk_window_set_resizable(GTK_WINDOW(widget), FALSE);
  gtk_window_set_decorated(GTK_WINDOW(widget), FALSE);
  gtk_widget_set_app_paintable(widget, TRUE);
  GdkScreen* screen = gtk_widget_get_screen(widget);
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  if (visual != nullptr) gtk_widget_set_visual(widget, visual);
  gtk_widget_set_size_request(widget, width, height);
  g_signal_connect(widget, "draw", draw, state);
  gtk_widget_realize(widget);
  // Empty input region: pointer, focus and all user input pass through.
  cairo_region_t* empty = cairo_region_create();
  gdk_window_input_shape_combine_region(gtk_widget_get_window(widget), empty, 0, 0);
  cairo_region_destroy(empty);
  if (draw == G_CALLBACK(draw_pointer)) {
    // Also shape the window to the arrow itself. Without an X compositor,
    // alpha-only popup backgrounds otherwise become an opaque black box.
    cairo_surface_t* surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    cairo_t* cr = cairo_create(surface);
    draw_pointer(widget, cr, state);
    cairo_destroy(cr);
    cairo_region_t* shape = gdk_cairo_region_create_from_surface(surface);
    gdk_window_shape_combine_region(gtk_widget_get_window(widget), shape, 0, 0);
    cairo_region_destroy(shape);
    cairo_surface_destroy(surface);
  }
  return widget;
}

void set_pointer_button(ControlOverlay* state, const std::string& button) {
  state->button = button;
  if (state->pointer != nullptr) gtk_widget_queue_draw(state->pointer);
}

void hide(ControlOverlay* state) {
  if (state->pointer) gtk_widget_hide(state->pointer);
  if (state->keyboard) gtk_widget_hide(state->keyboard);
  if (state->keys) gtk_widget_hide(state->keys);
  state->text.clear();
  state->button.clear();
}

bool start_input_watch(ControlOverlay* state) {
  if (state->display != nullptr) return state->ready;
  state->display = XOpenDisplay(nullptr);
  if (state->display == nullptr) return false;
  int event = 0, error = 0;
  if (!XQueryExtension(state->display, "XInputExtension", &state->xi_opcode, &event, &error)) return false;
  int major = 2, minor = 0;
  if (XIQueryVersion(state->display, &major, &minor) != Success) return false;
  unsigned char bits[XIMaskLen(XI_RawMotion)] = {};
  XISetMask(bits, XI_RawMotion);
  XISetMask(bits, XI_RawButtonPress);
  XISetMask(bits, XI_RawKeyPress);
  XIEventMask mask{XIAllMasterDevices, static_cast<int>(sizeof(bits)), bits};
  if (XISelectEvents(state->display, DefaultRootWindow(state->display), &mask, 1) != Success) return false;
  int count = 0;
  XIDeviceInfo* devices = XIQueryDevice(state->display, XIAllDevices, &count);
  for (int i = 0; devices != nullptr && i < count; i++) {
    if (devices[i].name != nullptr && strstr(devices[i].name, "XTEST") != nullptr)
      state->synthetic.insert(devices[i].deviceid);
  }
  if (devices != nullptr) XIFreeDeviceInfo(devices);
  XFlush(state->display);
  state->ready = true;
  return true;
}

void drain_events(ControlOverlay* state, bool observe) {
  if (state->display == nullptr) return;
  while (XPending(state->display) > 0) {
    XEvent event;
    XNextEvent(state->display, &event);
    if (event.type != GenericEvent || event.xcookie.extension != state->xi_opcode ||
        !XGetEventData(state->display, &event.xcookie)) continue;
    const int type = event.xcookie.evtype;
    if (observe && (type == XI_RawMotion || type == XI_RawButtonPress || type == XI_RawKeyPress)) {
      auto* raw = static_cast<XIRawEvent*>(event.xcookie.data);
      if (state->synthetic.find(raw->sourceid) == state->synthetic.end()) state->cancelled = true;
    }
    XFreeEventData(state->display, &event.xcookie);
  }
}

gboolean tick(gpointer data) {
  auto* state = static_cast<ControlOverlay*>(data);
  drain_events(state, state->active);
  if (!state->active) return G_SOURCE_CONTINUE;

  GdkDisplay* display = gdk_display_get_default();
  GdkSeat* seat = gdk_display_get_default_seat(display);
  GdkDevice* pointer = gdk_seat_get_pointer(seat);
  gint x = 0, y = 0;
  gdk_device_get_position(pointer, nullptr, &x, &y);
  gtk_window_move(GTK_WINDOW(state->pointer), x - kPointerHotspot, y - kPointerHotspot);
  return G_SOURCE_CONTINUE;
}

std::string string_arg(FlValue* args, const char* key) {
  FlValue* value = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(args, key) : nullptr;
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : "";
}

void method(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* state = static_cast<ControlOverlay*>(data);
  const char* name = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  g_autoptr(FlValue) value = nullptr;
  if (strcmp(name, "begin") == 0) {
    if (!start_input_watch(state)) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new("unsupported", "X11 physical-input monitoring is unavailable; input was not sent.", nullptr));
    } else {
      drain_events(state, state->active);
      if (!state->cancelled) {
        state->active = true;
        state->kind = string_arg(fl_method_call_get_args(call), "kind");
        state->text = string_arg(fl_method_call_get_args(call), "keys");
        set_pointer_button(state, "");  // Every warning starts with the neutral light-blue arrow.
        if (!state->pointer) state->pointer = window(state, kPointerWidth, kPointerHeight, G_CALLBACK(draw_pointer));
        if (!state->keyboard) state->keyboard = window(state, 88, 64, G_CALLBACK(draw_keyboard));
        if (!state->keys) state->keys = window(state, 420, 44, G_CALLBACK(draw_keys));
        tick(state);
        gtk_widget_show(state->pointer);
        gtk_widget_queue_draw(state->pointer);
        if (state->kind == "keyboard") {
          GdkDisplay* gd = gdk_display_get_default();
          GdkMonitor* monitor = gdk_display_get_primary_monitor(gd);
          if (monitor == nullptr) monitor = gdk_display_get_monitor(gd, 0);
          GdkRectangle rect{0, 0, 1280, 720};
          if (monitor != nullptr) gdk_monitor_get_geometry(monitor, &rect);
          gtk_window_move(GTK_WINDOW(state->keyboard), rect.x + (rect.width - 88) / 2, rect.y + (rect.height - 64) / 2);
          gtk_window_move(GTK_WINDOW(state->keys), rect.x + rect.width - 440, rect.y + 20);
          gtk_widget_show(state->keyboard);
          gtk_widget_show(state->keys);
          gtk_widget_queue_draw(state->keys);
        }
        if (state->timer == 0) state->timer = g_timeout_add(16, tick, state);
      }
      value = fl_value_new_bool(!state->cancelled);
    }
  } else if (strcmp(name, "interrupted") == 0) {
    drain_events(state, state->active);
    value = fl_value_new_bool(state->cancelled);
  } else if (strcmp(name, "update") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    const auto keys = string_arg(args, "keys");
    if (!keys.empty()) state->text = keys;
    FlValue* button = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(args, "button") : nullptr;
    if (button != nullptr && fl_value_get_type(button) == FL_VALUE_TYPE_STRING) {
      set_pointer_button(state, fl_value_get_string(button));
    }
    if (state->keys != nullptr) gtk_widget_queue_draw(state->keys);
  } else if (strcmp(name, "end") == 0 || strcmp(name, "reset") == 0) {
    drain_events(state, state->active);
    state->active = false;
    hide(state);
    if (state->timer != 0) { g_source_remove(state->timer); state->timer = 0; }
    if (strcmp(name, "reset") == 0) state->cancelled = false;
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  if (response == nullptr) response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call, response, nullptr);
}

void destroy(gpointer data) {
  auto* state = static_cast<ControlOverlay*>(data);
  if (state->timer) g_source_remove(state->timer);
  if (state->pointer) gtk_widget_destroy(state->pointer);
  if (state->keyboard) gtk_widget_destroy(state->keyboard);
  if (state->keys) gtk_widget_destroy(state->keys);
  if (state->display) XCloseDisplay(state->display);
  delete state;
}
}  // namespace

void woi_register_control_overlay(FlPluginRegistrar* registrar, GtkWidget* view) {
  auto* state = new ControlOverlay();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "woi/control", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method, state, destroy);
  g_object_set_data_full(G_OBJECT(view), "woi-control-channel", channel, g_object_unref);
}
