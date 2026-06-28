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
    // The PNG is a DEVICE-pixel bitmap and hotX/hotY arrive in DEVICE pixels.
    // CreateIconIndirect builds the HCURSOR from that full device-pixel bitmap
    // at its native size (no logical resize on Windows, unlike macOS/Linux which
    // tag the surface with the scale), so the hotspot must stay in DEVICE pixels
    // — dividing by the DPR here put the click point ~(dpr-1)× the hotspot off
    // (e.g. 8px on a 2× display). Pass it through unscaled.
    const int hot_x = static_cast<int>(GetDouble(*args, "hotX", 0) + 0.5);
    const int hot_y = static_cast<int>(GetDouble(*args, "hotY", 0) + 0.5);

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
  } else if (method == "canWarpPointer") {
    result->Success(EncodableValue(true));  // SetCursorPos is always available.
  } else if (method == "warpPointer" && args != nullptr) {
    // x/y AND viewportW/viewportH arrive in Flutter-LOGICAL window coords
    // (top-left, y-down), the same space as MediaQuery / globalPosition.
    //
    // Strategy: map by RATIO across the window's real PHYSICAL client rect (no
    // dpi/96 math, which overshoots at fractional scales like 250%). The two
    // things that previously broke this at 250%:
    //   (1) GetNativeWindow() is the CHILD content HWND that fills the client
    //       area and IS Flutter's logical (0,0) origin — so use it directly, do
    //       NOT GetAncestor() up to the top-level window (whose client rect is
    //       offset by the title bar → the cursor lands wrong / jumps).
    //   (2) The method-channel thread may have a DIFFERENT DPI-awareness context
    //       than the window. If so, GetClientRect/ClientToScreen return
    //       DPI-virtualized (logical) coords while SetCursorPos always takes
    //       PHYSICAL — at 250% that desync flings the cursor to the screen
    //       corner ("jumps to top"). Pin the thread to per-monitor-aware-v2 for
    //       these calls so every coordinate is physical and consistent.
    flutter::FlutterView* view = registrar_->GetView();
    HWND hwnd = view ? view->GetNativeWindow() : nullptr;
    // Fall back to the foreground window if the view HWND isn't available (the
    // app is focused during a drag, so this is our window).
    if (hwnd == nullptr) hwnd = GetForegroundWindow();
    if (hwnd != nullptr) {
      // Pin DPI awareness for the duration of the geometry + warp so all coords
      // are physical pixels (restored right after). SetThreadDpiAwarenessContext
      // is Windows 10 1607+; if unavailable the call simply no-ops.
      DPI_AWARENESS_CONTEXT prevDpi = SetThreadDpiAwarenessContext(
          DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

      const double lx = GetDouble(*args, "x", 0);
      const double ly = GetDouble(*args, "y", 0);
      const double vw = GetDouble(*args, "viewportW", 0);
      const double vh = GetDouble(*args, "viewportH", 0);

      RECT client = {};
      if (GetClientRect(hwnd, &client)) {
        POINT topLeft = {client.left, client.top};
        POINT botRight = {client.right, client.bottom};
        ClientToScreen(hwnd, &topLeft);
        ClientToScreen(hwnd, &botRight);
        const double pw = static_cast<double>(botRight.x - topLeft.x);
        const double ph = static_cast<double>(botRight.y - topLeft.y);

        double fx;
        double fy;
        if (vw > 0 && vh > 0) {
          fx = lx / vw;  // fraction across the viewport (0..1)
          fy = ly / vh;
        } else {
          // No viewport sent: assume logical == physical (best effort).
          fx = pw > 0 ? lx / pw : 0;
          fy = ph > 0 ? ly / ph : 0;
        }
        // Clamp inside the client rect so the cursor can never escape the window
        // or land on a different monitor, whatever the inputs.
        if (fx < 0) fx = 0; else if (fx > 1) fx = 1;
        if (fy < 0) fy = 0; else if (fy > 1) fy = 1;

        const int sx = topLeft.x + static_cast<int>(fx * pw + 0.5);
        const int sy = topLeft.y + static_cast<int>(fy * ph + 0.5);
        SetCursorPos(sx, sy);
      }

      if (prevDpi != nullptr) SetThreadDpiAwarenessContext(prevDpi);
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace native_mouse_cursor
