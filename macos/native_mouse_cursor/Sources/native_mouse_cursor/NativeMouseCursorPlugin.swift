// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

public class NativeMouseCursorPlugin: NSObject, FlutterPlugin {
  private var cursors = [String: NSCursor]()
  // The plugin registrar — kept so pointer warping can reach the host view to
  // convert Flutter-logical coords → screen coords.
  private weak var registrar: FlutterPluginRegistrar?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "native_mouse_cursor", binaryMessenger: registrar.messenger)
    let instance = NativeMouseCursorPlugin()
    instance.registrar = registrar
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

    case "canWarpPointer":
      result(true)  // CGWarpMouseCursorPosition — no entitlement needed.

    case "warpPointer":
      guard let args = call.arguments as? [String: Any],
        let x = (args["x"] as? NSNumber)?.doubleValue,
        let y = (args["y"] as? NSNumber)?.doubleValue,
        let view = registrar?.view
      else {
        result(nil)
        return
      }
      // Flutter (top-left, y-down) → AppKit view → window → AppKit screen
      // (bottom-left, y-up) → CG global (top-left, y-down).
      //
      // The incoming y is top-down. We must express it in the VIEW's own coord
      // space before converting up the chain: a non-flipped NSView has a
      // bottom-left origin (so flip: bounds.height - y), but a FLIPPED view
      // (FlutterView can be flipped) already has a top-left origin (use y as-is).
      // Always subtracting bounds.height on a flipped view double-flips it → a
      // fixed Y offset (the ~256 px jump). Respect view.isFlipped instead.
      let viewY = view.isFlipped ? y : (view.bounds.height - y)
      let viewPoint = NSPoint(x: x, y: viewY)
      let windowPoint = view.convert(viewPoint, to: nil)
      let screenPoint = view.window?.convertPoint(toScreen: windowPoint)
        ?? windowPoint
      // The AppKit→CG Y flip is around the GLOBAL coordinate origin, which is the
      // top-left of the menu-bar screen — i.e. the screen whose frame origin is
      // (0, 0), NOT simply `NSScreen.screens.first` (the system may list another
      // display first → a fixed Y offset, e.g. the ~256 px jump). Find that
      // anchor screen explicitly; fall back to the window's / main screen.
      let anchor = NSScreen.screens.first(where: { $0.frame.origin == .zero })
        ?? view.window?.screen
        ?? NSScreen.main
      let anchorHeight = anchor?.frame.height ?? screenPoint.y
      let cg = CGPoint(x: screenPoint.x, y: anchorHeight - screenPoint.y)
      CGWarpMouseCursorPosition(cg)
      // Re-link the hardware mouse to the cursor immediately (CGWarp briefly
      // dissociates them), so the very next move isn't swallowed.
      CGAssociateMouseAndMouseCursorPosition(1)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
