// Zig binding for NDK's android_native_app_glue.
//
// PLACEHOLDER — implementation pending.
//
// Re-exports the C struct `android_app` and APP_CMD_* constants from
// $ANDROID_NDK_HOME/sources/android/native_app_glue/android_native_app_glue.h
// via @cImport, plus a typed wrapper that hides the void* userData casts.
//
// Build wiring: vulkan-ash/build.zig must, when target is *-linux-android,
//   - addCSourceFile("$ANDROID_NDK_HOME/sources/android/native_app_glue/android_native_app_glue.c")
//   - addIncludePath("$ANDROID_NDK_HOME/sources/android/native_app_glue")
//   - linkSystemLibrary("android"), linkSystemLibrary("log")
//
// The shared library exposes the symbol expected by NativeActivity:
//   pub export fn ANativeActivity_onCreate(...) — supplied by the linked
//   android_native_app_glue.c, so the application only needs to define
//   `android_main(*android_app)`.
