#include "include/native_mouse_cursor/native_mouse_cursor_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "native_mouse_cursor_plugin.h"

void NativeMouseCursorPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  native_mouse_cursor::NativeMouseCursorPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
