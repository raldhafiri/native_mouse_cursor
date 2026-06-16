// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

public class NativeMouseCursorPlugin: NSObject, FlutterPlugin {
  private var cursors = [String: NSCursor]()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "native_mouse_cursor", binaryMessenger: registrar.messenger)
    let instance = NativeMouseCursorPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(true)  // NSCursor handles arbitrary bitmap cursors natively.

    case "createCursor":
      guard let args = call.arguments as? [String: Any],
        let key = args["key"] as? String,
        let data = (args["buffer"] as? FlutterStandardTypedData)?.data,
        let hotX = (args["hotX"] as? NSNumber)?.doubleValue,
        let hotY = (args["hotY"] as? NSNumber)?.doubleValue,
        let dpr = (args["devicePixelRatio"] as? NSNumber)?.doubleValue,
        let image = NSImage(data: data)
      else {
        result(FlutterError(code: "bad_args", message: "createCursor", details: nil))
        return
      }
      // The bitmap is in device pixels; present it at logical POINTS (÷dpr) so
      // the OS renders it crisp at the native scale.
      let pxW = image.size.width
      let pxH = image.size.height
      let scale = dpr > 0 ? dpr : 1.0
      image.size = NSSize(width: pxW / scale, height: pxH / scale)
      let hot = NSPoint(x: hotX / scale, y: hotY / scale)
      cursors[key] = NSCursor(image: image, hotSpot: hot)
      result(nil)

    case "setCursor":
      guard let args = call.arguments as? [String: Any],
        let key = args["key"] as? String,
        let cursor = cursors[key]
      else {
        result(nil)
        return
      }
      cursor.set()
      result(nil)

    case "deleteCursor":
      if let args = call.arguments as? [String: Any],
        let key = args["key"] as? String {
        cursors.removeValue(forKey: key)
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
