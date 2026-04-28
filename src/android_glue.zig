// Minimal Zig declarations for the NDK's android_native_app_glue runtime.
// Only the fields we read are mirrored from the C header — the trailing
// private members (pthread_*, queues) are intentionally omitted because we
// only ever access android_app through pointers handed to us by the glue.

const vk = @import("vulkan");

pub const ANativeWindow = opaque {};
pub const AInputQueue = opaque {};
pub const AInputEvent = opaque {};
pub const AConfiguration = opaque {};
pub const ANativeActivity = opaque {};
pub const ALooper = opaque {};

pub const ARect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const android_poll_source = extern struct {
    id: i32,
    app: ?*android_app,
    process: ?*const fn (app: ?*android_app, source: ?*android_poll_source) callconv(.c) void,
};

pub const android_app = extern struct {
    userData: ?*anyopaque,
    onAppCmd: ?*const fn (app: ?*android_app, cmd: i32) callconv(.c) void,
    onInputEvent: ?*const fn (app: ?*android_app, event: ?*AInputEvent) callconv(.c) i32,
    activity: ?*ANativeActivity,
    config: ?*AConfiguration,
    savedState: ?*anyopaque,
    savedStateSize: usize,
    looper: ?*ALooper,
    inputQueue: ?*AInputQueue,
    window: ?*ANativeWindow,
    contentRect: ARect,
    activityState: c_int,
    destroyRequested: c_int,
    // Private glue members (mutex/cond/thread/poll sources/...) follow here in
    // C; we deliberately do not mirror them — we never sizeof or copy this
    // struct, only dereference pointers handed to us.
};

pub const APP_CMD_INPUT_CHANGED: i32 = 0;
pub const APP_CMD_INIT_WINDOW: i32 = 1;
pub const APP_CMD_TERM_WINDOW: i32 = 2;
pub const APP_CMD_WINDOW_RESIZED: i32 = 3;
pub const APP_CMD_WINDOW_REDRAW_NEEDED: i32 = 4;
pub const APP_CMD_CONTENT_RECT_CHANGED: i32 = 5;
pub const APP_CMD_GAINED_FOCUS: i32 = 6;
pub const APP_CMD_LOST_FOCUS: i32 = 7;
pub const APP_CMD_CONFIG_CHANGED: i32 = 8;
pub const APP_CMD_LOW_MEMORY: i32 = 9;
pub const APP_CMD_START: i32 = 10;
pub const APP_CMD_RESUME: i32 = 11;
pub const APP_CMD_SAVE_STATE: i32 = 12;
pub const APP_CMD_PAUSE: i32 = 13;
pub const APP_CMD_STOP: i32 = 14;
pub const APP_CMD_DESTROY: i32 = 15;

pub const LOOPER_ID_MAIN: c_int = 1;
pub const LOOPER_ID_INPUT: c_int = 2;

pub extern fn ALooper_pollOnce(
    timeoutMillis: c_int,
    outFd: ?*c_int,
    outEvents: ?*c_int,
    outData: ?*?*anyopaque,
) c_int;

pub extern fn ANativeWindow_getWidth(window: *ANativeWindow) i32;
pub extern fn ANativeWindow_getHeight(window: *ANativeWindow) i32;

pub extern fn vkGetInstanceProcAddr(
    instance: vk.Instance,
    name: [*:0]const u8,
) vk.PfnVoidFunction;
