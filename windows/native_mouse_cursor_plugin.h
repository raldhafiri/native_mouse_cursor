// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

#ifndef FLUTTER_PLUGIN_NATIVE_MOUSE_CURSOR_PLUGIN_H_
#define FLUTTER_PLUGIN_NATIVE_MOUSE_CURSOR_PLUGIN_H_

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <map>
#include <memory>
#include <string>

namespace native_mouse_cursor {

class NativeMouseCursorPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit NativeMouseCursorPlugin(flutter::PluginRegistrarWindows *registrar);

  virtual ~NativeMouseCursorPlugin();

  // Disallow copy and assign.
  NativeMouseCursorPlugin(const NativeMouseCursorPlugin&) = delete;
  NativeMouseCursorPlugin& operator=(const NativeMouseCursorPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  flutter::PluginRegistrarWindows *registrar_;
  std::map<std::string, HCURSOR> cursors_;
  ULONG_PTR gdiplus_token_ = 0;
};

}  // namespace native_mouse_cursor

#endif  // FLUTTER_PLUGIN_NATIVE_MOUSE_CURSOR_PLUGIN_H_
