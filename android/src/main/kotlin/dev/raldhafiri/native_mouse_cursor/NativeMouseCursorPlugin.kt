// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

package dev.raldhafiri.native_mouse_cursor

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.view.PointerIcon
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Custom mouse/stylus cursors for Android tablets with a pointing device.
 *
 * Uses [PointerIcon.create] (API 24+) and sets it on the FlutterView — Android
 * resolves the pointer icon from the view directly under the pointer (the
 * FlutterView), so setting it on an ancestor (decorView) is overridden. Hover
 * from a connected mouse/trackpad/pen then shows the bitmap.
 */
class NativeMouseCursorPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private val cursors = HashMap<String, PointerIcon>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "native_mouse_cursor")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        if (call.method == "isSupported") {
            // PointerIcon needs API 24; below that the overlay fallback is used.
            result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.N)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.success(null) // PointerIcon needs API 24; no-op otherwise.
            return
        }
        when (call.method) {
            "createCursor" -> {
                val key = call.argument<String>("key")
                val buffer = call.argument<ByteArray>("buffer")
                val hotX = (call.argument<Number>("hotX") ?: 0).toFloat()
                val hotY = (call.argument<Number>("hotY") ?: 0).toFloat()
                if (key == null || buffer == null) {
                    result.error("bad_args", "createCursor", null)
                    return
                }
                val bitmap: Bitmap? =
                    BitmapFactory.decodeByteArray(buffer, 0, buffer.size)
                if (bitmap == null) {
                    result.error("decode", "bad png", null)
                    return
                }
                // Hotspot is in the bitmap's pixels (which is the device-pixel
                // bitmap we were handed), matching PointerIcon's expectation.
                cursors[key] = PointerIcon.create(bitmap, hotX, hotY)
                result.success(null)
            }
            "setCursor" -> {
                val key = call.argument<String>("key")
                val icon = cursors[key]
                val view = flutterView()
                if (icon != null && view != null) {
                    view.pointerIcon = icon
                }
                result.success(null)
            }
            "deleteCursor" -> {
                cursors.remove(call.argument<String>("key"))
                result.success(null)
            }
            "setPointerHidden" -> {
                // Used by the painted overlay: hide the system pointer (a null
                // icon) so the in-app cursor replaces it instead of doubling it.
                val hidden = call.argument<Boolean>("hidden") ?: false
                val view = flutterView()
                val act = activity
                if (view != null && act != null) {
                    view.pointerIcon = PointerIcon.getSystemIcon(
                        act,
                        if (hidden) PointerIcon.TYPE_NULL else PointerIcon.TYPE_ARROW,
                    )
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * The FlutterView (the view under the pointer whose `pointerIcon` Android
     * actually resolves). Falls back to the decorView if not found.
     */
    private fun flutterView(): View? {
        val root = activity?.window?.decorView ?: return null
        return findFlutterView(root) ?: root
    }

    private fun findFlutterView(view: View): View? {
        if (view.javaClass.name.contains("FlutterView")) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findFlutterView(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        cursors.clear()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}
