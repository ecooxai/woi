#include <X11/Xlib.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "my_application.h"

// NVIDIA PRIME variables inherited from a shell (__GLX_VENDOR_LIBRARY_NAME=
// nvidia, __NV_PRIME_RENDER_OFFLOAD=1) next to __EGL_VENDOR_LIBRARY_FILENAMES
// pinned to Mesa: Flutter renders with Mesa EGL, and GTK only uses GLX to draw
// the finished frame (one textured quad). On an X server without DRI3
// (Xephyr, Xvfb, VNC) EGL is llvmpipe and the NVIDIA GLX driver adds ~40 MB
// RSS/PSS (libnvidia-glcore/-gpucomp, /dev/nvidiactl) plus a cross-driver
// copy per frame. libGLX loads the named vendor in its constructor, before
// main(), so the only fix is to re-exec once with GLX pinned to Mesa. The
// inherited values travel in WOI_ORIG_* and are restored after GTK has set up
// GL (restore_gl_env), so child processes still see them.
// WOI_KEEP_GL_ENV=1 disables this.
static bool x_server_has_dri3() {
  Display* d = XOpenDisplay(nullptr);
  if (d == nullptr) return true;  // let GTK report the error
  int op = 0, ev = 0, err = 0;
  bool dri3 = XQueryExtension(d, "DRI3", &op, &ev, &err);
  XCloseDisplay(d);
  return dri3;
}

static void reexec_with_mesa_glx(char** argv) {
  const char* keep = getenv("WOI_KEEP_GL_ENV");
  if (keep != nullptr && strcmp(keep, "1") == 0) return;
  if (getenv("WOI_ORIG_GLX_VENDOR") != nullptr) return;  // already re-executed
  const char* glx = getenv("__GLX_VENDOR_LIBRARY_NAME");
  const char* egl = getenv("__EGL_VENDOR_LIBRARY_FILENAMES");
  if (glx == nullptr || egl == nullptr || strcmp(glx, "mesa") == 0) return;
  if (strstr(egl, glx) != nullptr || strstr(egl, "mesa") == nullptr) return;
  if (getenv("WAYLAND_DISPLAY") != nullptr) {
    const char* backend = getenv("GDK_BACKEND");
    if (backend == nullptr || strcmp(backend, "x11") != 0) return;
  }
  if (x_server_has_dri3()) return;
  const char* prime_env = getenv("__NV_PRIME_RENDER_OFFLOAD");
  char* prime = prime_env != nullptr ? strdup(prime_env) : nullptr;
  setenv("WOI_ORIG_GLX_VENDOR", glx, 1);
  setenv("WOI_ORIG_NV_PRIME", prime != nullptr ? prime : "", 1);
  setenv("__GLX_VENDOR_LIBRARY_NAME", "mesa", 1);
  unsetenv("__NV_PRIME_RENDER_OFFLOAD");
  setenv("WOI_SOFTWARE_GL", "1", 1);
  // argv[0] keeps the process name (symlinked QA binaries); /proc/self/exe
  // is the fallback.
  if (strchr(argv[0], '/') != nullptr) execv(argv[0], argv);
  execv("/proc/self/exe", argv);
  // exec failed: carry on with the inherited environment.
  setenv("__GLX_VENDOR_LIBRARY_NAME", getenv("WOI_ORIG_GLX_VENDOR"), 1);
  if (prime != nullptr) setenv("__NV_PRIME_RENDER_OFFLOAD", prime, 1);
  unsetenv("WOI_ORIG_GLX_VENDOR");
  unsetenv("WOI_ORIG_NV_PRIME");
  free(prime);
}

int main(int argc, char** argv) {
  reexec_with_mesa_glx(argv);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
