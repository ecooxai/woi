#include "clipboard_files.h"

#include <gio/gio.h>
#include <glib/gstdio.h>
#include <cstring>
#include <string>
#include <vector>

namespace {
constexpr gsize kImageBytes = 12 * 1024 * 1024;
constexpr gint64 kImagePixels = 32LL * 1024 * 1024;
constexpr gsize kFileBytes = 20 * 1024 * 1024;
constexpr gsize kTotalBytes = 32 * 1024 * 1024;

void success(FlMethodCall* call, FlValue* value) {
  g_autoptr(FlMethodResponse) reply = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call, reply, nullptr);
}
void failure(FlMethodCall* call, const char* message) {
  g_autoptr(FlMethodResponse) reply = FL_METHOD_RESPONSE(fl_method_error_response_new("clipboard_files", message, nullptr));
  fl_method_call_respond(call, reply, nullptr);
}

struct ClipboardState {
  guint64 revision = 1;
  guint64 passive_revision = 0;
  bool notifications = false;
  GtkWidget* observed_top = nullptr;
};
ClipboardState* clipboard_state(GtkWidget* view) {
  return static_cast<ClipboardState*>(g_object_get_data(G_OBJECT(view), "woi-clipboard-state"));
}
void invalidate_clipboard(GtkWidget* view) {
  auto* state = clipboard_state(view);
  state->revision++;
  state->passive_revision = 0;
}
void clipboard_changed(GtkClipboard*, GdkEventOwnerChange*, gpointer view) {
  auto* widget = GTK_WIDGET(view);
  invalidate_clipboard(widget);
  // Wake Dart immediately rather than waiting for its low-frequency fallback
  // poll. Only a generation number crosses this event channel; content is read
  // by the existing bounded asynchronous reader and remains app-owned.
  auto* channel = static_cast<FlMethodChannel*>(g_object_get_data(G_OBJECT(widget), "woi/clipboard"));
  if (channel != nullptr) {
    g_autoptr(FlValue) revision = fl_value_new_int(clipboard_state(widget)->revision);
    fl_method_channel_invoke_method(channel, "changed", revision, nullptr, nullptr, nullptr);
  }
}
gboolean clipboard_focus_changed(GtkWidget*, GdkEventFocus*, gpointer view) {
  invalidate_clipboard(GTK_WIDGET(view));
  return FALSE;
}
void clipboard_visibility_changed(GtkWidget* view, gpointer) { invalidate_clipboard(view); }
void clipboard_hierarchy_changed(GtkWidget* view, GtkWidget*, gpointer) {
  auto* state = clipboard_state(view);
  GtkWidget* top = gtk_widget_get_toplevel(view);
  if (!GTK_IS_WINDOW(top)) { state->observed_top = nullptr; return; }
  if (state->observed_top == top) return;
  state->observed_top = top;
  invalidate_clipboard(view);
  g_signal_connect_object(top, "focus-in-event", G_CALLBACK(clipboard_focus_changed), view, G_CONNECT_DEFAULT);
  g_signal_connect_object(top, "focus-out-event", G_CALLBACK(clipboard_focus_changed), view, G_CONNECT_DEFAULT);
}

struct ReadRequest {
  FlMethodCall* call;
  FlValue* content;
  std::string error;
  GtkWidget* view;
  guint64 revision;
  bool passive;
  int retries = 0;
};
void read_image(GtkClipboard* clipboard, GdkPixbuf* image, gpointer user_data);
void read_text(GtkClipboard* clipboard, const gchar* text, gpointer user_data) {
  auto* request = static_cast<ReadRequest*>(user_data);
  auto* state = clipboard_state(request->view);
  // Image and text requests are asynchronous. Never combine different clipboard
  // owners into one entry; retry a changing clipboard once, then ask the user to retry.
  if (state->revision != request->revision) {
    if (request->retries++ == 0) {
      request->revision = state->revision;
      request->error.clear();
      fl_value_unref(request->content);
      request->content = fl_value_new_map();
      gtk_clipboard_request_image(clipboard, read_image, request);
      return;
    }
    request->error = "The clipboard changed during the read. Try Paste again";
  }
  if (text != nullptr && g_utf8_strlen(text, -1) > 100000) request->error = "Clipboard text exceeds the 100000 character limit";
  if (request->error.empty()) {
    if (text != nullptr) fl_value_set_string_take(request->content, "text", fl_value_new_string(text));
    if (request->passive && state->notifications) state->passive_revision = request->revision;
    success(request->call, request->content);
  } else {
    failure(request->call, request->error.c_str());
  }
  fl_value_unref(request->content);
  g_object_unref(request->call);
  g_object_unref(request->view);
  delete request;
}
void read_image(GtkClipboard* clipboard, GdkPixbuf* image, gpointer user_data) {
  auto* request = static_cast<ReadRequest*>(user_data);
  if (image != nullptr) {
    const gint64 pixels = static_cast<gint64>(gdk_pixbuf_get_width(image)) * gdk_pixbuf_get_height(image);
    gchar* bytes = nullptr;
    gsize length = 0;
    g_autoptr(GError) error = nullptr;
    if (pixels <= 0 || pixels > kImagePixels) {
      request->error = "Clipboard images must be 32 megapixels or smaller";
    } else if (!gdk_pixbuf_save_to_buffer(image, &bytes, &length, "png", &error, nullptr)) {
      request->error = "The clipboard image could not be read";
    } else if (length > kImageBytes) {
      request->error = "Clipboard images must be 12 MB or smaller";
    } else {
      g_autoptr(FlValue) value = fl_value_new_map();
      fl_value_set_string_take(value, "bytes", fl_value_new_uint8_list(reinterpret_cast<const uint8_t*>(bytes), length));
      fl_value_set_string_take(value, "mimeType", fl_value_new_string("image/png"));
      fl_value_set_string_take(value, "name", fl_value_new_string("clipboard.png"));
      fl_value_set_string_take(request->content, "image", fl_value_ref(value));
    }
    g_free(bytes);
  }
  gtk_clipboard_request_text(clipboard, read_text, request);
}

struct CopyImage {
  std::vector<guint8> bytes;
  std::string text;
  bool has_text = false;
};
void supply_clipboard(GtkClipboard*, GtkSelectionData* selection, guint info, gpointer user_data) {
  auto* image = static_cast<CopyImage*>(user_data);
  if (info == 1) gtk_selection_data_set_text(selection, image->text.c_str(), image->text.size());
  else gtk_selection_data_set(selection, gdk_atom_intern_static_string("image/png"), 8, image->bytes.data(), image->bytes.size());
}
void clear_clipboard(GtkClipboard*, gpointer user_data) { delete static_cast<CopyImage*>(user_data); }
void constrain_image(GdkPixbufLoader* loader, gint width, gint height, gpointer user_data) {
  auto* oversized = static_cast<bool*>(user_data);
  if (width <= 0 || height <= 0 || static_cast<gint64>(width) * height > kImagePixels) {
    *oversized = true;
    gdk_pixbuf_loader_set_size(loader, 1, 1);
  }
}
void write_image(FlMethodCall* call, GtkClipboard* clipboard) {
  FlValue* args = fl_method_call_get_args(call);
  FlValue* image = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(args, "image") : nullptr;
  FlValue* raw = image != nullptr && fl_value_get_type(image) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(image, "bytes") : nullptr;
  if (raw == nullptr || fl_value_get_type(raw) != FL_VALUE_TYPE_UINT8_LIST || fl_value_get_length(raw) == 0 || fl_value_get_length(raw) > kImageBytes) {
    failure(call, "Clipboard images must contain valid bytes and be 12 MB or smaller"); return;
  }
  g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
  bool oversized = false;
  g_signal_connect(loader, "size-prepared", G_CALLBACK(constrain_image), &oversized);
  g_autoptr(GError) error = nullptr;
  const bool loaded = gdk_pixbuf_loader_write(loader, fl_value_get_uint8_list(raw), fl_value_get_length(raw), &error);
  const bool closed = gdk_pixbuf_loader_close(loader, error == nullptr ? &error : nullptr);
  GdkPixbuf* pixbuf = gdk_pixbuf_loader_get_pixbuf(loader);
  if (!loaded || !closed || oversized || pixbuf == nullptr) {
    failure(call, "The clipboard image is invalid or larger than 32 megapixels"); return;
  }
  gchar* png = nullptr;
  gsize length = 0;
  if (!gdk_pixbuf_save_to_buffer(pixbuf, &png, &length, "png", &error, nullptr) || length > kImageBytes) {
    g_free(png); failure(call, "The clipboard image could not be prepared within 12 MB"); return;
  }
  auto* copy = new CopyImage();
  copy->bytes.assign(reinterpret_cast<guint8*>(png), reinterpret_cast<guint8*>(png) + length);
  g_free(png);
  FlValue* text = fl_value_lookup_string(args, "text");
  if (text != nullptr && fl_value_get_type(text) == FL_VALUE_TYPE_STRING) {
    copy->text = fl_value_get_string(text);
    copy->has_text = true;
  }
  GtkTargetEntry targets[] = {
    {const_cast<gchar*>("image/png"), 0, 0},
    {const_cast<gchar*>("UTF8_STRING"), 0, 1},
    {const_cast<gchar*>("text/plain;charset=utf-8"), 0, 1},
    {const_cast<gchar*>("text/plain"), 0, 1},
  };
  if (!gtk_clipboard_set_with_data(clipboard, targets, copy->has_text ? 4 : 1, supply_clipboard, clear_clipboard, copy)) {
    delete copy; failure(call, "Linux did not accept the image copy"); return;
  }
  gtk_clipboard_set_can_store(clipboard, nullptr, 0);
  g_autoptr(FlValue) ok = fl_value_new_bool(TRUE);
  success(call, ok);
}

struct PickRequest {
  FlMethodCall* call;
  std::vector<std::string> paths;
  FlValue* result = nullptr;
  std::string error;
};
void load_files(GTask* task, gpointer, gpointer task_data, GCancellable*) {
  auto* request = static_cast<PickRequest*>(task_data);
  request->result = fl_value_new_list();
  gsize total = 0;
  for (const auto& path : request->paths) {
    GStatBuf info;
    if (g_stat(path.c_str(), &info) != 0 || !S_ISREG(info.st_mode)) { request->error = "The selected file is unavailable"; break; }
    if (info.st_size > static_cast<gint64>(kFileBytes)) { request->error = "Each attachment must be 20 MB or smaller"; break; }
    gchar* bytes = nullptr;
    gsize length = 0;
    g_autoptr(GError) error = nullptr;
    if (!g_file_get_contents(path.c_str(), &bytes, &length, &error)) { request->error = "The selected file could not be read"; break; }
    total += length;
    if (length > kFileBytes || total > kTotalBytes) { g_free(bytes); request->error = "Attachments must total 32 MB or less"; break; }
    g_autofree gchar* name = g_path_get_basename(path.c_str());
    g_autofree gchar* content_type = g_content_type_guess(name, reinterpret_cast<const guchar*>(bytes), length, nullptr);
    g_autofree gchar* mime = g_content_type_get_mime_type(content_type);
    g_autoptr(FlValue) value = fl_value_new_map();
    fl_value_set_string_take(value, "name", fl_value_new_string(name));
    fl_value_set_string_take(value, "mimeType", fl_value_new_string(mime != nullptr ? mime : "application/octet-stream"));
    fl_value_set_string_take(value, "bytes", fl_value_new_uint8_list(reinterpret_cast<const uint8_t*>(bytes), length));
    fl_value_append_take(request->result, fl_value_ref(value));
    g_free(bytes);
  }
  g_task_return_boolean(task, TRUE);
}
void files_loaded(GObject*, GAsyncResult* result, gpointer) {
  auto* request = static_cast<PickRequest*>(g_task_get_task_data(G_TASK(result)));
  if (request->error.empty()) success(request->call, request->result);
  else failure(request->call, request->error.c_str());
  fl_value_unref(request->result);
  g_object_unref(request->call);
  delete request;
}
void picker_response(GtkNativeDialog* dialog, gint response, gpointer user_data) {
  auto* request = static_cast<PickRequest*>(user_data);
  if (response == GTK_RESPONSE_ACCEPT) {
    GSList* paths = gtk_file_chooser_get_filenames(GTK_FILE_CHOOSER(dialog));
    for (GSList* item = paths; item != nullptr; item = item->next) request->paths.emplace_back(static_cast<gchar*>(item->data));
    g_slist_free_full(paths, g_free);
  }
  gtk_native_dialog_destroy(dialog);
  g_object_unref(dialog);
  if (request->paths.size() > 8) {
    failure(request->call, "Choose up to 8 files at a time");
    g_object_unref(request->call); delete request; return;
  }
  if (request->paths.empty()) {
    g_autoptr(FlValue) empty = fl_value_new_list();
    success(request->call, empty);
    g_object_unref(request->call); delete request; return;
  }
  g_autoptr(GTask) task = g_task_new(nullptr, nullptr, files_loaded, nullptr);
  g_task_set_task_data(task, request, nullptr);
  g_task_run_in_thread(task, load_files);
}
void method(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  const gchar* name = fl_method_call_get_name(call);
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  if (g_strcmp0(name, "read") == 0) {
    auto* view = GTK_WIDGET(user_data);
    auto* state = clipboard_state(view);
    FlValue* args = fl_method_call_get_args(call);
    FlValue* allow_focus = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(args, "allowFocus") : nullptr;
    const bool passive = allow_focus != nullptr && fl_value_get_type(allow_focus) == FL_VALUE_TYPE_BOOL && !fl_value_get_bool(allow_focus);
    // Only passive history polling may skip an unchanged generation. Manual
    // Paste/Refresh always requests current native data, even after a cache hit.
    if (passive && state->notifications && state->passive_revision == state->revision) {
      success(call, nullptr);
      return;
    }
    auto* request = new ReadRequest{FL_METHOD_CALL(g_object_ref(call)), fl_value_new_map(), {}, GTK_WIDGET(g_object_ref(view)), state->revision, passive};
    gtk_clipboard_request_image(clipboard, read_image, request);
  } else if (g_strcmp0(name, "write") == 0) {
    write_image(call, clipboard);
  } else if (g_strcmp0(name, "pickFiles") == 0) {
    GtkWidget* top = gtk_widget_get_toplevel(GTK_WIDGET(user_data));
    GtkFileChooserNative* chooser = gtk_file_chooser_native_new("Attach files", GTK_IS_WINDOW(top) ? GTK_WINDOW(top) : nullptr, GTK_FILE_CHOOSER_ACTION_OPEN, "Attach", "Cancel");
    gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(chooser), TRUE);
    auto* request = new PickRequest{FL_METHOD_CALL(g_object_ref(call)), {}, nullptr, {}};
    g_signal_connect(chooser, "response", G_CALLBACK(picker_response), request);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(chooser));
  } else {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
}
}  // namespace

void woi_register_clipboard_files(FlPluginRegistrar* registrar, GtkWidget* view) {
  auto* state = new ClipboardState();
  state->notifications = gdk_display_supports_selection_notification(gtk_widget_get_display(view));
  g_object_set_data_full(G_OBJECT(view), "woi-clipboard-state", state, [](gpointer value) { delete static_cast<ClipboardState*>(value); });
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  g_signal_connect_object(clipboard, "owner-change", G_CALLBACK(clipboard_changed), view, G_CONNECT_DEFAULT);
  g_signal_connect(view, "hierarchy-changed", G_CALLBACK(clipboard_hierarchy_changed), nullptr);
  g_signal_connect(view, "map", G_CALLBACK(clipboard_visibility_changed), nullptr);
  g_signal_connect(view, "unmap", G_CALLBACK(clipboard_visibility_changed), nullptr);
  clipboard_hierarchy_changed(view, nullptr, nullptr);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  for (const gchar* name : {"woi/clipboard", "woi/files"}) {
    FlMethodChannel* channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), name, FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(channel, method, view, nullptr);
    g_object_set_data_full(G_OBJECT(view), name, channel, g_object_unref);
  }
}
