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
    fullscreen: bool = false,
    window: ?glfw.Window = null,
    events: ArrayListUnmanaged(HostEvent) = .empty,
    closed: bool = false,
    glfw_initialized: bool = false,
    surface_announced: bool = false,

    pub fn init(allocator: Allocator, width: u32, height: u32, title: [:0]const u8) DesktopHost {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .title = title,
        };
    }

    pub fn initFullscreen(allocator: Allocator, title: [:0]const u8) DesktopHost {
        return .{
            .allocator = allocator,
            .width = 0,
            .height = 0,
            .title = title,
            .fullscreen = true,
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

        var hints: glfw.Window.Hints = .{
            .client_api = .no_api,
            .resizable = !self.fullscreen,
        };

        var monitor: ?glfw.Monitor = null;
        if (self.fullscreen) {
            const primary = glfw.Monitor.getPrimary() orelse return error.NoPrimaryMonitor;
            const mode = primary.getVideoMode() orelse return error.NoVideoMode;
            self.width = mode.getWidth();
            self.height = mode.getHeight();
            hints.red_bits = @intCast(mode.getRedBits());
            hints.green_bits = @intCast(mode.getGreenBits());
            hints.blue_bits = @intCast(mode.getBlueBits());
            hints.refresh_rate = @intCast(mode.getRefreshRate());
            hints.auto_iconify = false;
            monitor = primary;
        }

        const window = glfw.Window.create(self.width, self.height, self.title, monitor, null, hints) orelse return error.WindowCreationFailed;
        errdefer window.destroy();

        self.window = window;
        self.closed = false;
        self.surface_announced = false;

        window.setUserPointer(self);
        window.setIconifyCallback(iconifyCallback);
        window.setFramebufferSizeCallback(framebufferSizeCallback);

        if (self.fullscreen) {
            window.setInputModeCursor(.hidden);
        }

        try self.waitForInitialConfigure();

        try self.pushEvent(.{
            .kind = .surface_available,
            .extent = self.currentExtentUnchecked(),
        });
        self.surface_announced = true;
    }

    fn waitForInitialConfigure(self: *DesktopHost) !void {
        const window = self.window.?;
        const max_iterations: u32 = 20;
        const iteration_timeout_s: f64 = 0.05;
        var i: u32 = 0;
        while (i < max_iterations) : (i += 1) {
            const size = window.getFramebufferSize();
            if (size.width != 0 and size.height != 0) return;
            glfw.waitEventsTimeout(iteration_timeout_s);
        }
        return error.SurfaceConfigureTimeout;
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
        self.pollEscape();
        self.pushCloseEvent() catch {};
    }

    pub fn pump(self: *DesktopHost) void {
        if (self.window == null or self.closed) {
            return;
        }
        glfw.pollEvents();
        self.pollEscape();
        self.pushCloseEvent() catch {};
    }

    pub fn shutdown(self: *DesktopHost) void {
        if (self.window) |window| {
            window.setInputModeCursor(.normal);
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

    fn pollEscape(self: *DesktopHost) void {
        const window = self.window orelse return;
        if (self.closed) return;
        if (window.getKey(.escape) != .press) return;
        window.setShouldClose(true);
    }

    fn framebufferSizeCallback(window: glfw.Window, width: u32, height: u32) void {
        const self = fromWindow(window) orelse return;
        if (width == 0 or height == 0) {
            return;
        }
        if (!self.surface_announced) {
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
