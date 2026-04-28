const builtin = @import("builtin");
const std = @import("std");

pub const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

pub const vk = @import("vulkan");
pub const math = @import("math.zig");

pub const CommandContext = @import("command_context.zig").CommandContext;
pub const Host = @import("host.zig").Host;
pub const HostEvent = @import("host.zig").HostEvent;
pub const HostEventKind = @import("host.zig").HostEventKind;
pub const ImageResource = @import("image_resource.zig").ImageResource;
pub const Manager = @import("manager.zig").Manager;
pub const DeviceOptions = @import("manager.zig").DeviceOptions;
pub const InitOptions = @import("manager.zig").InitOptions;
pub const InstanceProcAddr = @import("manager.zig").InstanceProcAddr;
pub const Queue = @import("manager.zig").Queue;
pub const SurfaceFactory = @import("manager.zig").SurfaceFactory;
pub const Frame = @import("session.zig").Frame;
pub const Orientation = @import("session.zig").Orientation;
pub const Session = @import("session.zig").Session;
pub const SessionOptions = @import("session.zig").SessionOptions;
pub const SwapImage = @import("swapchain.zig").SwapImage;
pub const Swapchain = @import("swapchain.zig").Swapchain;
pub const SwapchainOptions = @import("swapchain.zig").SwapchainOptions;
pub const TextureOptions = @import("image_resource.zig").TextureOptions;
pub const checkDeviceExtensions = @import("manager.zig").checkDeviceExtensions;
pub const createTextureFromEncoded = @import("image_resource.zig").createTextureFromEncoded;
pub const createTextureFromFile = @import("image_resource.zig").createTextureFromFile;
pub const createTextureFromRgba = @import("image_resource.zig").createTextureFromRgba;
pub const newExtentSize = @import("manager.zig").newExtentSize;
pub const requireInstanceApiVersion = @import("manager.zig").requireInstanceApiVersion;
pub const setDebug = @import("manager.zig").setDebug;
pub const setValidations = @import("manager.zig").setValidations;

// Platform-specific exports — empty stubs on the other platform so users get
// a clean "field not found" rather than a missing import.
pub const glfw = if (is_android) struct {
    /// Monotonic seconds since the first call — mirrors glfw.getTime() semantics
    /// closely enough for time-based animations on Android where GLFW is absent.
    pub fn getTime() f64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        const Holder = struct {
            var start_sec: ?isize = null;
        };
        if (Holder.start_sec == null) Holder.start_sec = ts.sec;
        return @as(f64, @floatFromInt(ts.sec - Holder.start_sec.?)) +
            @as(f64, @floatFromInt(ts.nsec)) / 1e9;
    }
} else @import("glfw");
pub const DesktopHost = if (is_android) struct {} else @import("host_desktop.zig").DesktopHost;
pub const AndroidHost = if (is_android) @import("host_android.zig").AndroidHost else struct {};
pub const native_app_glue = if (is_android) @import("android_glue.zig") else struct {};

test {
    _ = CommandContext;
    _ = Host;
    _ = Manager;
    _ = Session;
    if (!is_android) _ = DesktopHost;
    if (is_android) _ = AndroidHost;
}
