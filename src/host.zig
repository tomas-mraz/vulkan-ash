const vk = @import("vulkan");
const Manager = @import("manager.zig").Manager;

pub const HostEventKind = enum {
    surface_available,
    surface_lost,
    surface_invalidated,
    paused,
    resumed,
    close,
};

pub const HostEvent = struct {
    kind: HostEventKind,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
};

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque) anyerror!void,
        initVulkan: *const fn (ptr: *anyopaque) anyerror!void,
        instanceProcAddr: *const fn (ptr: *anyopaque) @import("manager.zig").InstanceProcAddr,
        instanceExtensions: *const fn (ptr: *anyopaque) []const [*:0]const u8,
        createSurface: *const fn (ptr: *anyopaque, instance: @import("manager.zig").Instance) anyerror!vk.SurfaceKHR,
        currentExtent: *const fn (ptr: *anyopaque) ?vk.Extent2D,
        nextEvent: *const fn (ptr: *anyopaque) ?HostEvent,
        wait: *const fn (ptr: *anyopaque) void,
        pump: *const fn (ptr: *anyopaque) void,
        shutdown: *const fn (ptr: *anyopaque) void,
    };

    pub fn start(self: Host) !void {
        try self.vtable.start(self.ptr);
    }

    pub fn initVulkan(self: Host) !void {
        try self.vtable.initVulkan(self.ptr);
    }

    pub fn instanceProcAddr(self: Host) @import("manager.zig").InstanceProcAddr {
        return self.vtable.instanceProcAddr(self.ptr);
    }

    pub fn instanceExtensions(self: Host) []const [*:0]const u8 {
        return self.vtable.instanceExtensions(self.ptr);
    }

    pub fn createSurface(self: Host, instance: @import("manager.zig").Instance) !vk.SurfaceKHR {
        return try self.vtable.createSurface(self.ptr, instance);
    }

    pub fn currentExtent(self: Host) ?vk.Extent2D {
        return self.vtable.currentExtent(self.ptr);
    }

    pub fn nextEvent(self: Host) ?HostEvent {
        return self.vtable.nextEvent(self.ptr);
    }

    pub fn wait(self: Host) void {
        self.vtable.wait(self.ptr);
    }

    pub fn pump(self: Host) void {
        self.vtable.pump(self.ptr);
    }

    pub fn shutdown(self: Host) void {
        self.vtable.shutdown(self.ptr);
    }
};
