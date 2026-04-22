const std = @import("std");
const glfw = @import("glfw");
const vk = @import("vulkan");

const Host = @import("host.zig").Host;
const HostEvent = @import("host.zig").HostEvent;
const HostEventKind = @import("host.zig").HostEventKind;
const Instance = @import("manager.zig").Instance;
const InstanceProcAddr = @import("manager.zig").InstanceProcAddr;

const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;

pub const DesktopHost = struct {
    allocator: Allocator,
    width: u32,
    height: u32,
    title: [:0]const u8,
    window: ?glfw.Window = null,
    events: ArrayListUnmanaged(HostEvent) = .empty,
    closed: bool = false,
    glfw_initialized: bool = false,

    pub fn init(allocator: Allocator, width: u32, height: u32, title: [:0]const u8) DesktopHost {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .title = title,
        };
    }

    pub fn asHost(self: *DesktopHost) Host {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn start(self: *DesktopHost) !void {
        if (self.window != null) {
            return;
        }

        if (!glfw.init(.{})) {
            return error.GlfwInitFailed;
        }
        self.glfw_initialized = true;
        errdefer {
            glfw.terminate();
            self.glfw_initialized = false;
        }

        const window = glfw.Window.create(self.width, self.height, self.title, null, null, .{
            .client_api = .no_api,
            .resizable = true,
        }) orelse return error.WindowCreationFailed;
        errdefer window.destroy();

        self.window = window;
        self.closed = false;

        window.setUserPointer(self);
        window.setIconifyCallback(iconifyCallback);
        window.setFramebufferSizeCallback(framebufferSizeCallback);

        try self.pushEvent(.{
            .kind = .surface_available,
            .extent = self.currentExtentUnchecked(),
        });
    }

    pub fn initVulkan(self: *DesktopHost) !void {
        _ = self;
        if (!glfw.vulkanSupported()) {
            return error.VulkanNotSupported;
        }
    }

    pub fn instanceProcAddr(self: *DesktopHost) InstanceProcAddr {
        _ = self;
        return getGlfwInstanceProcAddr;
    }

    pub fn instanceExtensions(self: *DesktopHost) []const [*:0]const u8 {
        if (self.window == null) {
            return &.{};
        }
        return glfw.getRequiredInstanceExtensions() orelse &.{};
    }

    pub fn createSurface(self: *DesktopHost, instance: Instance) !vk.SurfaceKHR {
        const window = self.window orelse return error.NoWindow;

        var surface: vk.SurfaceKHR = undefined;
        const result: vk.Result = @enumFromInt(glfw.createWindowSurface(instance.handle, window, null, &surface));
        if (result != .success) {
            return error.SurfaceInitFailed;
        }
        return surface;
    }

    pub fn currentExtent(self: *DesktopHost) ?vk.Extent2D {
        if (self.window == null) {
            return null;
        }
        return self.currentExtentUnchecked();
    }

    pub fn nextEvent(self: *DesktopHost) ?HostEvent {
        if (self.events.items.len == 0) {
            return null;
        }
        return self.events.orderedRemove(0);
    }

    pub fn wait(self: *DesktopHost) void {
        if (self.window == null or self.closed) {
            return;
        }
        if (self.events.items.len > 0) {
            return;
        }
        glfw.waitEvents();
        self.pushCloseEvent() catch {};
    }

    pub fn pump(self: *DesktopHost) void {
        if (self.window == null or self.closed) {
            return;
        }
        glfw.pollEvents();
        self.pushCloseEvent() catch {};
    }

    pub fn shutdown(self: *DesktopHost) void {
        if (self.window) |window| {
            window.setFramebufferSizeCallback(null);
            window.setIconifyCallback(null);
            window.setUserPointer(null);
            window.destroy();
            self.window = null;
        }
        if (self.glfw_initialized) {
            glfw.terminate();
            self.glfw_initialized = false;
        }
        self.events.deinit(self.allocator);
        self.events = .empty;
        self.closed = true;
    }

    fn currentExtentUnchecked(self: *DesktopHost) vk.Extent2D {
        const window = self.window.?;
        const size = window.getFramebufferSize();
        return .{
            .width = size.width,
            .height = size.height,
        };
    }

    fn pushEvent(self: *DesktopHost, event: HostEvent) !void {
        if (self.events.items.len >= 16) {
            return;
        }
        try self.events.append(self.allocator, event);
    }

    fn pushCloseEvent(self: *DesktopHost) !void {
        const window = self.window orelse return;
        if (!window.shouldClose() or self.closed) {
            return;
        }
        self.closed = true;
        try self.pushEvent(.{ .kind = .close });
    }

    fn fromWindow(window: glfw.Window) ?*DesktopHost {
        return window.getUserPointer(DesktopHost);
    }

    fn iconifyCallback(window: glfw.Window, iconified: bool) void {
        const self = fromWindow(window) orelse return;
        self.pushEvent(.{
            .kind = if (iconified) .paused else .resumed,
        }) catch {};
    }

    fn framebufferSizeCallback(window: glfw.Window, width: u32, height: u32) void {
        const self = fromWindow(window) orelse return;
        if (width == 0 or height == 0) {
            return;
        }
        self.pushEvent(.{
            .kind = .surface_invalidated,
            .extent = .{ .width = width, .height = height },
        }) catch {};
    }

    fn getGlfwInstanceProcAddr(instance: vk.Instance, proc_name: [*:0]const u8) vk.PfnVoidFunction {
        return @ptrCast(glfw.getInstanceProcAddress(
            if (instance == .null_handle) null else @ptrFromInt(@intFromEnum(instance)),
            proc_name,
        ));
    }

    fn hostStart(ptr: *anyopaque) anyerror!void {
        try cast(ptr).start();
    }

    fn hostInitVulkan(ptr: *anyopaque) anyerror!void {
        try cast(ptr).initVulkan();
    }

    fn hostInstanceProcAddr(ptr: *anyopaque) InstanceProcAddr {
        return cast(ptr).instanceProcAddr();
    }

    fn hostInstanceExtensions(ptr: *anyopaque) []const [*:0]const u8 {
        return cast(ptr).instanceExtensions();
    }

    fn hostCreateSurface(ptr: *anyopaque, instance: Instance) anyerror!vk.SurfaceKHR {
        return try cast(ptr).createSurface(instance);
    }

    fn hostCurrentExtent(ptr: *anyopaque) ?vk.Extent2D {
        return cast(ptr).currentExtent();
    }

    fn hostNextEvent(ptr: *anyopaque) ?HostEvent {
        return cast(ptr).nextEvent();
    }

    fn hostWait(ptr: *anyopaque) void {
        cast(ptr).wait();
    }

    fn hostPump(ptr: *anyopaque) void {
        cast(ptr).pump();
    }

    fn hostShutdown(ptr: *anyopaque) void {
        cast(ptr).shutdown();
    }

    fn cast(ptr: *anyopaque) *DesktopHost {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable: Host.VTable = .{
        .start = hostStart,
        .initVulkan = hostInitVulkan,
        .instanceProcAddr = hostInstanceProcAddr,
        .instanceExtensions = hostInstanceExtensions,
        .createSurface = hostCreateSurface,
        .currentExtent = hostCurrentExtent,
        .nextEvent = hostNextEvent,
        .wait = hostWait,
        .pump = hostPump,
        .shutdown = hostShutdown,
    };
};
