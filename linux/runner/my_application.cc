#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <gio/gio.h>
#include <glib.h>
#include <gtk/gtk.h>

#include <cstdio>
#include <fstream>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr int kDefaultW = 1280;
constexpr int kDefaultH = 720;
constexpr int kMinW = 640;
constexpr int kMinH = 480;

// ~/.xchat/window.json 读写(GTK 端直接管,避免 Dart 端异步写盘与窗口闪烁)
std::string XchatHomeDir() {
  const char* home = g_getenv("HOME");
  if (!home || !*home) home = "/tmp";
  return std::string(home) + "/.xchat";
}

std::string WindowPrefsPath() {
  return XchatHomeDir() + "/window.json";
}

bool ReadWindowPrefs(int& w, int& h) {
  std::ifstream f(WindowPrefsPath());
  if (!f.is_open()) return false;
  std::string content((std::istreambuf_iterator<char>(f)),
                      std::istreambuf_iterator<char>());
  // 极简解析:找 "w":NNN,"h":NNN。允许两端有空白 / 其他字符。
  auto find_num = [&](const std::string& key) -> int {
    auto pos = content.find("\"" + key + "\"");
    if (pos == std::string::npos) return -1;
    pos = content.find(':', pos);
    if (pos == std::string::npos) return -1;
    pos++;
    while (pos < content.size() && (content[pos] == ' ' || content[pos] == '\t')) pos++;
    int v = 0;
    bool any = false;
    while (pos < content.size() && content[pos] >= '0' && content[pos] <= '9') {
      v = v * 10 + (content[pos] - '0');
      pos++;
      any = true;
    }
    return any ? v : -1;
  };
  int rw = find_num("w");
  int rh = find_num("h");
  if (rw < kMinW || rw > 8192 || rh < kMinH || rh > 8192) return false;
  w = rw;
  h = rh;
  return true;
}

void WriteWindowPrefs(int w, int h) {
  if (w < kMinW || h < kMinH) return;
  // 确保 ~/.xchat 存在
  g_mkdir_with_parents(XchatHomeDir().c_str(), 0700);
  FILE* fp = fopen(WindowPrefsPath().c_str(), "w");
  if (!fp) return;
  fprintf(fp, "{\"w\":%d,\"h\":%d}\n", w, h);
  fclose(fp);
}

// 防抖写盘:500ms 内多次尺寸变化只写一次。
struct SaveTimer {
  guint source_id = 0;
  int last_w = 0;
  int last_h = 0;
};

gboolean DoSaveWindowPrefs(gpointer data) {
  auto* t = reinterpret_cast<SaveTimer*>(data);
  WriteWindowPrefs(t->last_w, t->last_h);
  t->source_id = 0;
  return FALSE;  // 一次性定时器,返回 FALSE 让 GLib 自动移除
}

void ScheduleSave(SaveTimer* t, int w, int h) {
  t->last_w = w;
  t->last_h = h;
  if (t->source_id != 0) {
    g_source_remove(t->source_id);
    t->source_id = 0;
  }
  t->source_id = g_timeout_add(500, &DoSaveWindowPrefs, t);
}

void FlushSave(SaveTimer* t) {
  if (t->source_id != 0) {
    g_source_remove(t->source_id);
    t->source_id = 0;
  }
  WriteWindowPrefs(t->last_w, t->last_h);
}

// configure-event 在拖动过程中高频触发,这里只更新"待写"值,真正写盘交给定时器。
gboolean OnConfigure(GtkWindow* window, GdkEvent* event, gpointer user_data) {
  auto* t = reinterpret_cast<SaveTimer*>(user_data);
  int w = event->configure.width;
  int h = event->configure.height;
  ScheduleSave(t, w, h);
  return FALSE;
}

// destroy 回调必须是个自由函数:G_CALLBACK 是 function-like 宏,
// 内联 lambda 的逗号会让宏展开失败("too many arguments")。
void OnDestroyFlush(GtkWindow* window, gpointer user_data) {
  auto* t = reinterpret_cast<SaveTimer*>(user_data);
  gint ww = 0, hh = 0;
  gtk_window_get_size(window, &ww, &hh);
  if (ww >= kMinW && hh >= kMinH) {
    t->last_w = ww;
    t->last_h = hh;
  }
  FlushSave(t);
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  SaveTimer save_timer;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

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
    gtk_header_bar_set_title(header_bar, "xchat");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "xchat");
  }

  // 启动尺寸:优先 ~/.xchat/window.json,回落到默认 1280x720。
  int init_w = kDefaultW;
  int init_h = kDefaultH;
  ReadWindowPrefs(init_w, init_h);
  gtk_window_set_default_size(window, init_w, init_h);
  self->save_timer.last_w = init_w;
  self->save_timer.last_h = init_h;
  // 监听窗口尺寸变化 + 销毁时最终落盘。
  g_signal_connect(window, "configure-event", G_CALLBACK(OnConfigure),
                   &self->save_timer);
  g_signal_connect(window, "destroy", G_CALLBACK(OnDestroyFlush),
                   &self->save_timer);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

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
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

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