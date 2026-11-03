#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

#include "desktop_multi_window/desktop_multi_window_plugin.h"

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

// Secondary windows are created by desktop_multi_window with an empty title
// and no background colour. "woi/window" lets the viewer engine set its title.
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
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// Registers "woi/window" (setTitle, present) on the engine of [registry].
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

static void secondary_window_created(FlPluginRegistry* registry) {
  fl_register_plugins(registry);

  FlView* view = register_window_channel(registry);
  if (view == nullptr) return;

  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#05070D");
  fl_view_set_background_color(view, &background_color);

  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  if (GTK_IS_WINDOW(toplevel)) {
    gtk_window_set_title(GTK_WINDOW(toplevel), "Woi");
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
