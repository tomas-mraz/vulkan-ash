// Android Host implementation for vulkan-ash.
//
// PLACEHOLDER — implementation pending.
//
// Responsibilities (mirrors host_android.go in vulkan-ash-go):
//   - Wrap the NDK android_native_app_glue `android_app` lifecycle.
//   - Translate APP_CMD_* (init/term window, gained/lost focus,
//     pause/resume, window resized, destroy) into Host events:
//       surface_available / surface_lost / surface_invalidated
//       paused / resumed / close
//   - Provide vkCreateAndroidSurfaceKHR via createSurface().
//   - Track ANativeWindow_getWidth/Height for currentExtent().
//   - Drive ALooper_pollOnce in pump() / wait() — no goroutines in Zig,
//     so the demux is synchronous on the main thread.
//
// Implements the Host vtable from host.zig.
