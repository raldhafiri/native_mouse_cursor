// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

#include "native_mouse_cursor_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <gdiplus.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#pragma comment(lib, "gdiplus.lib")

namespace native_mouse_cursor {

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

// Look up [key] in [map] or return null.
const EncodableValue* ValueOrNull(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

double GetDouble(const EncodableMap& map, const char* key, double fallback) {
  const auto* v = ValueOrNull(map, key);
  if (v == nullptr) return fallback;
  if (std::holds_alternative<double>(*v)) return std::get<double>(*v);
  if (std::holds_alternative<int>(*v)) return std::get<int>(*v);
  if (std::holds_alternative<int64_t>(*v)) {
    return static_cast<double>(std::get<int64_t>(*v));
  }
  return fallback;
}

// Decode PNG [bytes] into an HCURSOR with the given hotspot (device pixels).
HCURSOR CursorFromPng(const std::vector<uint8_t>& bytes, int hot_x, int hot_y) {
  HGLOBAL global = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (global == nullptr) return nullptr;
  void* mem = GlobalLock(global);
  memcpy(mem, bytes.data(), bytes.size());
  GlobalUnlock(global);

  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(global, TRUE, &stream) != S_OK) {
    GlobalFree(global);
    return nullptr;
  }

  HCURSOR cursor = nullptr;
  {
    Gdiplus::Bitmap bitmap(stream);
    if (bitmap.GetLastStatus() == Gdiplus::Ok) {
      HBITMAP hbitmap = nullptr;
      bitmap.GetHBITMAP(Gdiplus::Color(0, 0, 0, 0), &hbitmap);
      if (hbitmap != nullptr) {
        HBITMAP mask =
            CreateBitmap(bitmap.GetWidth(), bitmap.GetHeight(), 1, 1, nullptr);
        ICONINFO info = {};
        info.fIcon = FALSE;  // FALSE = cursor (uses hotspot)
        info.xHotspot = static_cast<DWORD>(hot_x);
        info.yHotspot = static_cast<DWORD>(hot_y);
        info.hbmMask = mask;
        info.hbmColor = hbitmap;
        cursor = reinterpret_cast<HCURSOR>(CreateIconIndirect(&info));
        DeleteObject(hbitmap);
        DeleteObject(mask);
      }
    }
  }
  stream->Release();  // also frees the HGLOBAL (TRUE above)
  return cursor;
}

}  // namespace

// static
void NativeMouseCursorPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "native_mouse_cursor",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<NativeMouseCursorPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

NativeMouseCursorPlugin::NativeMouseCursorPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr);
}

NativeMouseCursorPlugin::~NativeMouseCursorPlugin() {
  for (auto& entry : cursors_) {
    if (entry.second != nullptr) DestroyCursor(entry.second);
  }
  if (gdiplus_token_ != 0) Gdiplus::GdiplusShutdown(gdiplus_token_);
}

void NativeMouseCursorPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* args = std::get_if<EncodableMap>(method_call.arguments());
  const std::string& method = method_call.method_name();

  if (method == "isSupported") {
    // HCURSOR handles arbitrary bitmap cursors natively.
    result->Success(EncodableValue(true));
    return;
  }

  if (method == "createCursor" && args != nullptr) {
    const auto* key_v = ValueOrNull(*args, "key");
    const auto* buf_v = ValueOrNull(*args, "buffer");
    if (key_v == nullptr || buf_v == nullptr ||
        !std::holds_alternative<std::vector<uint8_t>>(*buf_v)) {
      result->Error("bad_args", "createCursor");
      return;
    }
    const std::string key = std::get<std::string>(*key_v);
    const auto& bytes = std::get<std::vector<uint8_t>>(*buf_v);
    const double dpr = GetDouble(*args, "devicePixelRatio", 1.0);
    const double scale = dpr > 0 ? dpr : 1.0;
    const int hot_x = static_cast<int>(GetDouble(*args, "hotX", 0) / scale);
    const int hot_y = static_cast<int>(GetDouble(*args, "hotY", 0) / scale);

    HCURSOR cursor = CursorFromPng(bytes, hot_x, hot_y);
    if (cursor == nullptr) {
      result->Error("decode", "bad png");
      return;
    }
    auto it = cursors_.find(key);
    if (it != cursors_.end()) {
      DestroyCursor(it->second);
      it->second = cursor;
    } else {
      cursors_[key] = cursor;
    }
    result->Success();
  } else if (method == "setCursor" && args != nullptr) {
    const auto* key_v = ValueOrNull(*args, "key");
    if (key_v != nullptr) {
      auto it = cursors_.find(std::get<std::string>(*key_v));
      if (it != cursors_.end()) {
        // Make it the active cursor AND the window-class cursor so Windows
        // keeps drawing it on subsequent WM_SETCURSOR (mouse moves).
        SetCursor(it->second);
        HWND hwnd = registrar_->GetView()
                        ? registrar_->GetView()->GetNativeWindow()
                        : nullptr;
        if (hwnd != nullptr) {
          SetClassLongPtr(hwnd, GCLP_HCURSOR,
                          reinterpret_cast<LONG_PTR>(it->second));
        }
      }
    }
    result->Success();
  } else if (method == "deleteCursor" && args != nullptr) {
    const auto* key_v = ValueOrNull(*args, "key");
    if (key_v != nullptr) {
      auto it = cursors_.find(std::get<std::string>(*key_v));
      if (it != cursors_.end()) {
        DestroyCursor(it->second);
        cursors_.erase(it);
      }
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace native_mouse_cursor
