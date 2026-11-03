#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "fvp/fvp_plugin.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// GTK3 on X11 renders with GLX and leaves the window's GLX paint context
// current on the main thread after every frame. Each FlView compiles its
// compositor shaders with eglMakeCurrent() while it is being realized; under
// libglvnd that fails while a GLX context is current on the same thread
// ("Failed to setup compositor shaders, unable to make OpenGL context
// current"), so every secondary window (desktop_multi_window media viewer)
// came up black. The main window only worked because it is realized before
// the first GTK paint. Drop the current GL context right before any FlView is
// realized; GDK makes its context current again whenever it paints. The hook
// is on "parent-set": GtkContainer emits it before it realizes the child,
// whereas "realize" hooks only run after the class handler has already set up
// OpenGL.
static gboolean clear_gl_before_view_realize(GSignalInvocationHint* hint,
                                             guint n_params,
                                             const GValue* params,
                                             gpointer data) {
  if (n_params > 0 && G_VALUE_HOLDS_OBJECT(&params[0])) {
    GObject* object = G_OBJECT(g_value_get_object(&params[0]));
    if (object != nullptr && FL_IS_VIEW(object)) {
      gdk_gl_context_clear_current();
    }
  }
  return TRUE;  // keep the hook installed
}

#ifdef GDK_WINDOWING_X11
// When a viewer's X window is destroyed from outside (xkill-style tools,
// `xdotool windowclose`), the engine's GL teardown afterwards gets a GLX
// BadAccess/BadDrawable for the dead drawable, and GDK's default X error
// handler exits the whole app. GLX errors are logged and ignored; every other
// error goes to GDK's handler.
static XErrorHandler gdk_x_error_handler = nullptr;
static int glx_major_opcode = -1;

static int woi_x_error(Display* display, XErrorEvent* event) {
  if (glx_major_opcode >= 0 && event->request_code == glx_major_opcode) {
    g_warning("Ignoring X error %d from GLX request %d.%d", event->error_code,
              event->request_code, event->minor_code);
    return 0;
  }
  return gdk_x_error_handler != nullptr ? gdk_x_error_handler(display, event)
                                        : 0;
}

static void install_x_error_handler() {
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr || !GDK_IS_X11_DISPLAY(display)) return;
  Display* xdisplay = gdk_x11_display_get_xdisplay(display);
  int event_base = 0, error_base = 0;
  if (!XQueryExtension(xdisplay, "GLX", &glx_major_opcode, &event_base,
                       &error_base)) {
    glx_major_opcode = -1;
    return;
  }
  gdk_x_error_handler = XSetErrorHandler(woi_x_error);
}
#endif

// Secondary windows are created by desktop_multi_window with an empty title
// and no background colour. "woi/window" lets the viewer engine set its title
// and toggle fullscreen (video).
static void window_method_cb(FlMethodChannel* channel, FlMethodCall* call,
                             gpointer user_data) {
  GtkWidget* view = GTK_WIDGET(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(call), "setTitle") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    const gchar* title = args != nullptr &&
                                 fl_value_get_type(args) == FL_VALUE_TYPE_STRING
                             ? fl_value_get_string(args)
                             : "Woi";
    GtkWidget* toplevel = gtk_widget_get_toplevel(view);
    if (GTK_IS_WINDOW(toplevel)) {
      gtk_window_set_title(GTK_WINDOW(toplevel), title);
      GtkWidget* bar = gtk_window_get_titlebar(GTK_WINDOW(toplevel));
      if (bar != nullptr && GTK_IS_HEADER_BAR(bar)) {
        gtk_header_bar_set_title(GTK_HEADER_BAR(bar), title);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(fl_method_call_get_name(call), "present") == 0) {
    // Raise and focus this window (approval dialogs); returns the X11 window
    // id so the caller can fall back to xdotool if the WM ignores the hint.
    GtkWidget* toplevel = gtk_widget_get_toplevel(view);
    int64_t xid = 0;
    if (GTK_IS_WINDOW(toplevel)) {
      guint32 ts = GDK_CURRENT_TIME;
#ifdef GDK_WINDOWING_X11
      GdkWindow* gdk_window = gtk_widget_get_window(toplevel);
      if (gdk_window != nullptr && GDK_IS_X11_WINDOW(gdk_window)) {
        ts = gdk_x11_get_server_time(gdk_window);
        xid = static_cast<int64_t>(gdk_x11_window_get_xid(gdk_window));
      }
#endif
      gtk_window_deiconify(GTK_WINDOW(toplevel));
      gtk_window_present_with_time(GTK_WINDOW(toplevel), ts);
    }
    g_autoptr(FlValue) result = fl_value_new_int(xid);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(fl_method_call_get_name(call), "close") == 0) {
    // Graceful close (delete-event, then destroy), as the WM close button
    // does. The viewer uses it for Esc.
    GtkWidget* toplevel = gtk_widget_get_toplevel(view);
    if (GTK_IS_WINDOW(toplevel)) gtk_window_close(GTK_WINDOW(toplevel));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(fl_method_call_get_name(call), "setFullscreen") == 0) {
    // In-app video viewer: F / double-click toggles, Esc leaves.
    FlValue* args = fl_method_call_get_args(call);
    const gboolean on = args != nullptr &&
                        fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
                        fl_value_get_bool(args);
    GtkWidget* toplevel = gtk_widget_get_toplevel(view);
    if (GTK_IS_WINDOW(toplevel)) {
      if (on) {
        gtk_window_fullscreen(GTK_WINDOW(toplevel));
      } else {
        gtk_window_unfullscreen(GTK_WINDOW(toplevel));
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// Registers "woi/window" (setTitle, present, close) on the engine of [registry].
static FlView* register_window_channel(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "WoiWindow");
  FlView* view = fl_plugin_registrar_get_view(registrar);
  if (view == nullptr) return nullptr;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "woi/window",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, window_method_cb, view,
                                            nullptr);
  // The channel lives as long as the view.
  g_object_set_data_full(G_OBJECT(view), "woi-window-channel", channel,
                         g_object_unref);
  return view;
}

// Viewer windows only need the window and video plugins. flutter_webrtc must
// not be registered here: its Linux registrar is a function-local static bound
// to the first (main) view, so registering it again installs a fresh, empty
// FlutterWebRTC instance on the MAIN engine's "FlutterWebRTC.Method" channel.
// After the first viewer opened, every gpt-live call (speaker mute on
// barge-in, stats, hang-up) went to that empty instance and silently failed.
static void register_viewer_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) multi_window =
      fl_plugin_registry_get_registrar_for_plugin(registry,
                                                  "DesktopMultiWindowPlugin");
  desktop_multi_window_plugin_register_with_registrar(multi_window);
  g_autoptr(FlPluginRegistrar) fvp =
      fl_plugin_registry_get_registrar_for_plugin(registry, "FvpPlugin");
  fvp_plugin_register_with_registrar(fvp);
}

static void secondary_window_created(FlPluginRegistry* registry) {
  register_viewer_plugins(registry);

  FlView* view = register_window_channel(registry);
  if (view == nullptr) return;

  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#05070D");
  fl_view_set_background_color(view, &background_color);

  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  if (GTK_IS_WINDOW(toplevel)) {
    gtk_window_set_title(GTK_WINDOW(toplevel), "Woi");
  }
  // Closing a viewer only hides it. Destroying a secondary FlView breaks GL
  // for the main window: its next paint segfaults in gdk_cairo_draw_from_gl.
  // The Dart side reuses the hidden viewer for the next file and is told
  // "hidden" so it can stop playback.
  if (GTK_IS_WINDOW(toplevel)) {
    g_signal_connect(toplevel, "delete-event",
                     G_CALLBACK(+[](GtkWidget* window, GdkEvent*,
                                    gpointer data) -> gboolean {
                       gtk_widget_hide(window);
                       auto* channel = FL_METHOD_CHANNEL(g_object_get_data(
                           G_OBJECT(data), "woi-window-channel"));
                       if (channel != nullptr) {
                         fl_method_channel_invoke_method(channel, "hidden",
                                                         nullptr, nullptr,
                                                         nullptr, nullptr);
                       }
                       return TRUE;
                     }),
                     view);
  }
  // Raise the viewer once Flutter has drawn into it.
  g_signal_connect(view, "first-frame", G_CALLBACK(+[](FlView* v, gpointer) {
                     GtkWidget* top = gtk_widget_get_toplevel(GTK_WIDGET(v));
                     gtk_widget_show(top);
                     if (GTK_IS_WINDOW(top)) gtk_window_present(GTK_WINDOW(top));
                   }),
                   nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Woi");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Woi");
  }

  gtk_window_set_default_size(window, 1360, 860);
  GdkGeometry hints;
  hints.min_width = 360;
  hints.min_height = 560;
  gtk_window_set_geometry_hints(window, nullptr, &hints, GDK_HINT_MIN_SIZE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);
  // WOI_RENDERER=skia: Skia over OpenGL instead of Impeller (perf experiments).
  if (g_strcmp0(g_getenv("WOI_RENDERER"), "skia") == 0) {
    fl_dart_project_set_enable_impeller(project, FALSE);
  }

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#05070D");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  register_window_channel(FL_PLUGIN_REGISTRY(view));
#ifdef GDK_WINDOWING_X11
  install_x_error_handler();
#endif

  // Every secondary window (media viewer) runs its own engine and needs the
  // plugins registered as well.
  desktop_multi_window_plugin_set_window_created_callback(
      secondary_window_created);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // The widget class must be initialized before its signals can be looked up.
  g_type_class_unref(g_type_class_ref(GTK_TYPE_WIDGET));
  g_signal_add_emission_hook(g_signal_lookup("parent-set", GTK_TYPE_WIDGET), 0,
                             clear_gl_before_view_realize, nullptr, nullptr);

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
