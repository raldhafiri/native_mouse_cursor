// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

#include "include/native_mouse_cursor/native_mouse_cursor_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>
#include <string>
#include <unordered_map>

// Pointer warp (X11) / lock (Wayland) subsystem lives in its own translation
// unit so this file stays focused on cursor rendering + GObject boilerplate.
#include "nmc_pointer.h"

#define NATIVE_MOUSE_CURSOR_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), native_mouse_cursor_plugin_get_type(), \
                              NativeMouseCursorPlugin))

struct _NativeMouseCursorPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar;
  std::unordered_map<std::string, GdkCursor*>* cache;
  NmcPointer* pointer;  // X11 warp / Wayland lock subsystem
};

G_DEFINE_TYPE(NativeMouseCursorPlugin, native_mouse_cursor_plugin,
              g_object_get_type())

static GdkWindow* get_gdk_window(NativeMouseCursorPlugin* self) {
  if (self->registrar == nullptr) return nullptr;
  FlView* view = fl_plugin_registrar_get_view(self->registrar);
  if (view == nullptr) return nullptr;
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  return gtk_widget_get_window(toplevel);
}

// The standard codec sends Dart ints as INT and doubles as FLOAT; hotX/hotY
// arrive as ints, devicePixelRatio as a float. Read either as a double.
static double value_to_double(FlValue* v, double fallback) {
  if (v == nullptr) return fallback;
  switch (fl_value_get_type(v)) {
    case FL_VALUE_TYPE_INT:
      return static_cast<double>(fl_value_get_int(v));
    case FL_VALUE_TYPE_FLOAT:
      return fl_value_get_float(v);
    default:
      return fallback;
  }
}

static FlMethodResponse* create_cursor(NativeMouseCursorPlugin* self,
                                       FlValue* args) {
  FlValue* key_v = fl_value_lookup_string(args, "key");
  FlValue* buf_v = fl_value_lookup_string(args, "buffer");
  FlValue* hot_x_v = fl_value_lookup_string(args, "hotX");
  FlValue* hot_y_v = fl_value_lookup_string(args, "hotY");
  FlValue* dpr_v = fl_value_lookup_string(args, "devicePixelRatio");
  if (key_v == nullptr || buf_v == nullptr) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("bad_args", "createCursor", nullptr));
  }
  std::string key = fl_value_get_string(key_v);
  const uint8_t* bytes = fl_value_get_uint8_list(buf_v);
  size_t length = fl_value_get_length(buf_v);
  double dpr = value_to_double(dpr_v, 1.0);
  if (dpr <= 0) dpr = 1.0;

  g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
  gdk_pixbuf_loader_write(loader, bytes, length, nullptr);
  gdk_pixbuf_loader_close(loader, nullptr);
  GdkPixbuf* raw = gdk_pixbuf_loader_get_pixbuf(loader);
  if (raw == nullptr) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("decode", "bad png", nullptr));
  }
  GdkPixbuf* pixbuf = gdk_pixbuf_copy(raw);

  GdkDisplay* display = gdk_display_get_default();
  // The bitmap is in device pixels. Present it at LOGICAL size via a cairo
  // surface tagged with the display scale, so GDK doesn't draw it double-size
  // on HiDPI; the hotspot is then in logical coords too.
  int scale = static_cast<int>(dpr + 0.5);
  if (scale < 1) scale = 1;
  double hot_x = value_to_double(hot_x_v, 0) / dpr;
  double hot_y = value_to_double(hot_y_v, 0) / dpr;
  cairo_surface_t* surface =
      gdk_cairo_surface_create_from_pixbuf(pixbuf, scale, nullptr);
  GdkCursor* cursor =
      gdk_cursor_new_from_surface(display, surface, hot_x, hot_y);
  cairo_surface_destroy(surface);
  g_object_unref(pixbuf);

  auto it = self->cache->find(key);
  if (it != self->cache->end()) {
    g_object_unref(it->second);
    it->second = cursor;
  } else {
    self->cache->insert(std::make_pair(key, cursor));
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* set_cursor(NativeMouseCursorPlugin* self,
                                    FlValue* args) {
  FlValue* key_v = fl_value_lookup_string(args, "key");
  if (key_v != nullptr) {
    std::string key = fl_value_get_string(key_v);
    auto it = self->cache->find(key);
    GdkWindow* window = get_gdk_window(self);
    if (it != self->cache->end() && window != nullptr) {
      gdk_window_set_cursor(window, it->second);
    }
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* delete_cursor(NativeMouseCursorPlugin* self,
                                       FlValue* args) {
  FlValue* key_v = fl_value_lookup_string(args, "key");
  if (key_v != nullptr) {
    std::string key = fl_value_get_string(key_v);
    auto it = self->cache->find(key);
    if (it != self->cache->end()) {
      g_object_unref(it->second);
      self->cache->erase(it);
    }
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void native_mouse_cursor_plugin_handle_method_call(
    NativeMouseCursorPlugin* self, FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "isSupported") == 0) {
    // GdkCursor handles arbitrary bitmap cursors natively.
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(true)));
  } else if (strcmp(method, "createCursor") == 0) {
    response = create_cursor(self, args);
  } else if (strcmp(method, "setCursor") == 0) {
    response = set_cursor(self, args);
  } else if (strcmp(method, "deleteCursor") == 0) {
    response = delete_cursor(self, args);
  } else if (strcmp(method, "canWarpPointer") == 0) {
    response = nmc_pointer_can_warp(self->pointer);
  } else if (strcmp(method, "warpPointer") == 0) {
    response = nmc_pointer_warp(self->pointer, args);
  } else if (strcmp(method, "lockPointer") == 0) {
    response = nmc_pointer_lock(self->pointer);
  } else if (strcmp(method, "unlockPointer") == 0) {
    response = nmc_pointer_unlock(self->pointer);
  } else if (strcmp(method, "drainPointerLockDelta") == 0) {
    response = nmc_pointer_drain(self->pointer);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void native_mouse_cursor_plugin_dispose(GObject* object) {
  NativeMouseCursorPlugin* self = NATIVE_MOUSE_CURSOR_PLUGIN(object);
  if (self->cache != nullptr) {
    for (auto& entry : *self->cache) {
      g_object_unref(entry.second);
    }
    delete self->cache;
    self->cache = nullptr;
  }
  if (self->pointer != nullptr) {
    nmc_pointer_free(self->pointer);
    self->pointer = nullptr;
  }
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(native_mouse_cursor_plugin_parent_class)->dispose(object);
}

static void native_mouse_cursor_plugin_class_init(
    NativeMouseCursorPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = native_mouse_cursor_plugin_dispose;
}

static void native_mouse_cursor_plugin_init(NativeMouseCursorPlugin* self) {
  self->cache = new std::unordered_map<std::string, GdkCursor*>();
  self->pointer = nullptr;  // created in register (needs the registrar)
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  NativeMouseCursorPlugin* plugin = NATIVE_MOUSE_CURSOR_PLUGIN(user_data);
  native_mouse_cursor_plugin_handle_method_call(plugin, method_call);
}

void native_mouse_cursor_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  NativeMouseCursorPlugin* plugin = NATIVE_MOUSE_CURSOR_PLUGIN(
      g_object_new(native_mouse_cursor_plugin_get_type(), nullptr));
  // Keep a ref — the registrar is needed later (setCursor / pointer) to reach
  // the view.
  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));
  plugin->pointer = nmc_pointer_new(plugin->registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "native_mouse_cursor", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
