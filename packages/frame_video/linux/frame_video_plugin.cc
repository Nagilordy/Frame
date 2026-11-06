// Frame's video surface on Linux (X11).
//
// open():  creates a borderless, black X11 window ("the surface") exactly under Frame's window,
//          the same size and place, and returns its X window id. libmpv draws the video into it
//          (its "wid") with its own renderer (gpu-next). Frame's window is see-through where
//          Flutter draws nothing (the runner gives it an RGBA visual and a clear background), so
//          the video shows through and Frame's controls sit on top.
//          The surface skips the taskbar and pager and never takes focus. Each time Frame moves,
//          resizes, is raised or minimised, the surface follows: same place, stacked right
//          under Frame (asked of the window manager, so it works with KWin, Mutter, gamescope).
// close(): destroys the surface.
// Under Wayland there are no X window ids: open() answers null and Frame uses its usual player.

#include "include/frame_video/frame_video_plugin.h"

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <gdk/gdkx.h>
#include <gtk/gtk.h>

#include <cstring>

namespace {

GtkWindow* g_window = nullptr;
Display* g_display = nullptr;
Window g_surface = 0;
gulong g_handlers[4] = {0, 0, 0, 0};

Window FrameXid() {
  GdkWindow* gw = g_window ? gtk_widget_get_window(GTK_WIDGET(g_window)) : nullptr;
  return gw ? gdk_x11_window_get_xid(gw) : 0;
}

// Same place and size as Frame's window contents, stacked just under Frame.
void Place() {
  if (!g_surface || !g_window) return;
  GdkDisplay* trap_display = gtk_widget_get_display(GTK_WIDGET(g_window));
  gdk_x11_display_error_trap_push(trap_display);
  GdkWindow* gw = gtk_widget_get_window(GTK_WIDGET(g_window));
  if (!gw) return;
  int x = 0, y = 0;
  gdk_window_get_origin(gw, &x, &y);
  const int scale = gdk_window_get_scale_factor(gw);
  const int w = gdk_window_get_width(gw) * scale;
  const int h = gdk_window_get_height(gw) * scale;
  const bool hidden = (gdk_window_get_state(gw) & GDK_WINDOW_STATE_ICONIFIED) || !gtk_widget_get_visible(GTK_WIDGET(g_window));
  if (hidden) {
    XUnmapWindow(g_display, g_surface);
  } else {
    XMoveResizeWindow(g_display, g_surface, x * scale, y * scale, w > 0 ? w : 1, h > 0 ? h : 1);
    XMapWindow(g_display, g_surface);
    XWindowChanges changes;
    changes.sibling = FrameXid();
    changes.stack_mode = Below;
    if (changes.sibling) {
      XReconfigureWMWindow(g_display, g_surface, DefaultScreen(g_display), CWSibling | CWStackMode, &changes);
    }
  }
  XFlush(g_display);
  const gint error = gdk_x11_display_error_trap_pop(trap_display);
  if (error) g_message("frame_video: placing the surface gave X error %d (ignored)", error);
}

gboolean OnFrameEvent(GtkWidget*, GdkEvent*, gpointer) {
  Place();
  return FALSE;  // let GTK and Flutter handle the event as usual
}

void SetAtomList(Window w, const char* property, const char* const* values, int count) {
  Atom atoms[4];
  for (int i = 0; i < count && i < 4; i++) atoms[i] = XInternAtom(g_display, values[i], False);
  XChangeProperty(g_display, w, XInternAtom(g_display, property, False), XA_ATOM, 32, PropModeReplace,
                  reinterpret_cast<unsigned char*>(atoms), count);
}

Window Open(GtkWindow* window) {
  if (g_surface) return g_surface;
  GdkDisplay* gd = gtk_widget_get_display(GTK_WIDGET(window));
  if (!GDK_IS_X11_DISPLAY(gd)) {
    g_message("frame_video: not an X11 display, no surface");
    return 0;  // Wayland: no surface, the usual player is used
  }
  g_message("frame_video: creating the surface");
  gdk_x11_display_error_trap_push(gd);
  g_window = window;
  g_display = gdk_x11_display_get_xdisplay(gd);
  const int screen = DefaultScreen(g_display);
  g_surface = XCreateSimpleWindow(g_display, RootWindow(g_display, screen), 0, 0, 16, 16, 0,
                                  BlackPixel(g_display, screen), BlackPixel(g_display, screen));
  if (!g_surface) {
    gdk_x11_display_error_trap_pop_ignored(gd);
    g_message("frame_video: XCreateSimpleWindow failed");
    return 0;
  }

  XStoreName(g_display, g_surface, "Frame video");
  // Never takes focus.
  XWMHints hints;
  std::memset(&hints, 0, sizeof(hints));
  hints.flags = InputHint;
  hints.input = False;
  XSetWMHints(g_display, g_surface, &hints);
  // No border or title bar (Motif hints, understood by every window manager).
  struct {
    unsigned long flags, functions, decorations;
    long input_mode;
    unsigned long status;
  } motif = {2, 0, 0, 0, 0};
  Atom motif_atom = XInternAtom(g_display, "_MOTIF_WM_HINTS", False);
  XChangeProperty(g_display, g_surface, motif_atom, motif_atom, 32, PropModeReplace,
                  reinterpret_cast<unsigned char*>(&motif), 5);
  // Not in the taskbar, the pager or Alt+Tab.
  const char* const state[] = {"_NET_WM_STATE_SKIP_TASKBAR", "_NET_WM_STATE_SKIP_PAGER"};
  SetAtomList(g_surface, "_NET_WM_STATE", state, 2);
  const char* const type[] = {"_NET_WM_WINDOW_TYPE_UTILITY"};
  SetAtomList(g_surface, "_NET_WM_WINDOW_TYPE", type, 1);
  XSync(g_display, False);
  const gint error = gdk_x11_display_error_trap_pop(gd);
  if (error) g_message("frame_video: setting up the surface gave X error %d", error);
  g_message("frame_video: surface 0x%lx created, following Frame's window", g_surface);

  GtkWidget* w = GTK_WIDGET(window);
  g_handlers[0] = g_signal_connect(w, "configure-event", G_CALLBACK(OnFrameEvent), nullptr);
  g_handlers[1] = g_signal_connect(w, "window-state-event", G_CALLBACK(OnFrameEvent), nullptr);
  g_handlers[2] = g_signal_connect(w, "focus-in-event", G_CALLBACK(OnFrameEvent), nullptr);
  g_handlers[3] = g_signal_connect(w, "map-event", G_CALLBACK(OnFrameEvent), nullptr);
  Place();
  g_message("frame_video: surface placed");
  return g_surface;
}

void Close() {
  if (g_window) {
    for (gulong& id : g_handlers) {
      if (id) g_signal_handler_disconnect(g_window, id);
      id = 0;
    }
  }
  if (g_surface && g_display) {
    XDestroyWindow(g_display, g_surface);
    XFlush(g_display);
  }
  g_surface = 0;
}

FlPluginRegistrar* g_registrar = nullptr;

void OnMethodCall(FlMethodChannel* channel, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "open") == 0) {
    g_message("frame_video: open asked");
    FlView* view = g_registrar ? fl_plugin_registrar_get_view(g_registrar) : nullptr;
    GtkWidget* top = view ? gtk_widget_get_toplevel(GTK_WIDGET(view)) : nullptr;
    Window surface = (top && GTK_IS_WINDOW(top)) ? Open(GTK_WINDOW(top)) : 0;
    g_autoptr(FlValue) result = surface ? fl_value_new_int(static_cast<int64_t>(surface)) : fl_value_new_null();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "close") == 0) {
    Close();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void frame_video_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  // Keep our own reference: the app's plugin registration releases its reference right after
  // this call, and the registrar is needed later (when a video opens) to find Frame's window.
  g_registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "frame/video",
                                                   FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, OnMethodCall, nullptr, nullptr);
  // The channel lives as long as the app (one per process), so it's intentionally not freed.
}
