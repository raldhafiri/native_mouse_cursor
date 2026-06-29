// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT
//
// Pointer warp / lock subsystem for the Linux plugin (separate translation unit
// from the cursor + GObject boilerplate in native_mouse_cursor_plugin.cc).
//
// It backs the package's "infinite / relative drag":
//   • X11      — warpPointer via the runtime-resolved XWarpPointer (teleport).
//   • Wayland  — warpPointer via wp_pointer_warp_v1 (staging) when the compositor
//                advertises it (GNOME 49+, Plasma 6.5+, Hyprland 0.51+, …) — a
//                visible wrapping cursor like the other platforms. Otherwise
//                lockPointer / unlockPointer / drainPointerLockDelta via
//                pointer-constraints-v1 + relative-pointer-v1 (lock + relative
//                motion), the long-standing fallback.
//   • else     — graceful no-ops (the Dart side falls back to a clamped drag).
//
// All native symbols (libX11 / libwayland-client) are resolved at RUNTIME via
// dlsym from the libs GDK already loaded — nothing is linked at build time, so
// the host executable never drags those system libs (and their newer GLIBC
// symbols) onto its link line. See the .cc for the gory details.

#ifndef NMC_POINTER_H_
#define NMC_POINTER_H_

#include <flutter_linux/flutter_linux.h>

// Opaque per-plugin pointer state (Wayland proxies + accumulated motion). One is
// created per plugin instance and freed on dispose.
typedef struct _NmcPointer NmcPointer;

// Create / destroy the pointer subsystem for a plugin. [registrar] is borrowed
// (used to reach the GdkWindow); the caller keeps owning it.
NmcPointer* nmc_pointer_new(FlPluginRegistrar* registrar);
void nmc_pointer_free(NmcPointer* p);

// ── method-channel handlers (return an owned FlMethodResponse) ───────────────

// canWarpPointer → bool. True under X11, or Wayland when wp_pointer_warp_v1 is
// available (compositor + a current focus/serial); false otherwise.
FlMethodResponse* nmc_pointer_can_warp(NmcPointer* p);

// warpPointer{x,y} → null. Teleports the OS pointer (X11 via XWarpPointer;
// Wayland via wp_pointer_warp_v1; no-op elsewhere).
FlMethodResponse* nmc_pointer_warp(NmcPointer* p, FlValue* args);

// lockPointer → bool. Wayland (no warp protocol): lock + start relative-motion
// stream. Elsewhere (incl. X11, and Wayland-with-warp, which warp) returns false.
FlMethodResponse* nmc_pointer_lock(NmcPointer* p);

// unlockPointer → null. Wayland: release the lock + relative pointer.
FlMethodResponse* nmc_pointer_unlock(NmcPointer* p);

// drainPointerLockDelta → {dx, dy}. Wayland: the accumulated relative motion
// (logical px) since the last call, then reset.
FlMethodResponse* nmc_pointer_drain(NmcPointer* p);

#endif  // NMC_POINTER_H_
