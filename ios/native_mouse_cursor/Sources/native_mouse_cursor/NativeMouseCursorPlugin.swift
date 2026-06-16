// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import Flutter
import UIKit

/// iOS / iPadOS.
///
/// iPadOS draws and manages the pointer itself — there is no API to replace it
/// with an arbitrary bitmap cursor (and no reliable way to hide it), so
/// `isSupported` returns `false` and the cursor calls are graceful no-ops. The
/// system pointer is used; cross-platform code keeps working unchanged.
public class NativeMouseCursorPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "native_mouse_cursor", binaryMessenger: registrar.messenger())
    let instance = NativeMouseCursorPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(false)  // No arbitrary bitmap cursor on iOS/iPadOS.
    case "createCursor", "setCursor", "deleteCursor":
      result(nil)  // No-op: the system pointer is used.
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
