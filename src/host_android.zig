const std = @import("std");
const vk = @import("vulkan");
const glue = @import("android_glue.zig");

const Host = @import("host.zig").Host;
const HostEvent = @import("host.zig").HostEvent;
const HostEventKind = @import("host.zig").HostEventKind;
const Instance = @import("manager.zig").Instance;
const InstanceProcAddr = @import("manager.zig").InstanceProcAddr;

const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;

const required_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
    "VK_KHR_android_surface",
};

pub const AndroidHost = struct {
    allocator: Allocator,
    app: *glue.android_app,
    events: ArrayListUnmanaged(HostEvent) = .empty,
    surface_announced: bool = false,
    closed: bool = false,

    pub fn init(allocator: Allocator, app: *glue.android_app) AndroidHost {
        return .{
            .allocator = allocator,
            .app = app,
        };
    }

    pub fn asHost(self: *AndroidHost) Host {
        self.app.userData = self;
        self.app.onAppCmd = onAppCmdThunk;
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn start(self: *AndroidHost) !void {
        // Pump until the framework gives us a window — surface_available is
        // emitted from the APP_CMD_INIT_WINDOW handler.
        while (!self.surface_announced and !self.closed) {
            _ = self.pumpOnce(-1);
        }
    }

    pub fn initVulkan(self: *AndroidHost) !void {
        _ = self;
    }

    pub fn instanceProcAddr(self: *AndroidHost) InstanceProcAddr {
        _ = self;
        return getAndroidInstanceProcAddr;
    }

    pub fn instanceExtensions(self: *AndroidHost) []const [*:0]const u8 {
        _ = self;
        return &required_extensions;
    }

    pub fn createSurface(self: *AndroidHost, instance: Instance) !vk.SurfaceKHR {
        const window = self.app.window orelse return error.NoWindow;
        const create_fn_raw = glue.vkGetInstanceProcAddr(
            instance.handle,
            "vkCreateAndroidSurfaceKHR",
        ) orelse return error.MissingAndroidSurfaceExtension;
        const PFN_vkCreateAndroidSurfaceKHR = *const fn (
            vk.Instance,
            *const vk.AndroidSurfaceCreateInfoKHR,
            ?*const vk.AllocationCallbacks,
            *vk.SurfaceKHR,
        ) callconv(.c) vk.Result;
        const create_fn: PFN_vkCreateAndroidSurfaceKHR = @ptrCast(create_fn_raw);

        const create_info = vk.AndroidSurfaceCreateInfoKHR{
            .flags = .{},
            .window = @ptrCast(window),
        };
        var surface: vk.SurfaceKHR = .null_handle;
        const result = create_fn(instance.handle, &create_info, null, &surface);
        if (result != .success) return error.SurfaceInitFailed;
        return surface;
    }

    pub fn currentExtent(self: *AndroidHost) ?vk.Extent2D {
        const window = self.app.window orelse return null;
        return windowExtent(window);
    }

    pub fn nextEvent(self: *AndroidHost) ?HostEvent {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn wait(self: *AndroidHost) void {
        if (self.events.items.len > 0 or self.closed) return;
        _ = self.pumpOnce(-1);
    }

    pub fn pump(self: *AndroidHost) void {
        // Drain everything that's ready without blocking.
        while (self.pumpOnce(0)) {}
    }

    pub fn shutdown(self: *AndroidHost) void {
        self.app.onAppCmd = null;
        self.app.userData = null;
        self.events.deinit(self.allocator);
        self.events = .empty;
        self.closed = true;
    }

    /// Returns true if a poll source was processed, false on timeout / no work.
    fn pumpOnce(self: *AndroidHost, timeout_ms: c_int) bool {
        var source_ptr: ?*anyopaque = null;
        const id = glue.ALooper_pollOnce(timeout_ms, null, null, &source_ptr);
        if (id < 0) {
            return false;
        }
        if (source_ptr) |raw| {
            const source: *glue.android_poll_source = @ptrCast(@alignCast(raw));
            if (source.process) |process_fn| {
                process_fn(self.app, source);
            }
        }
        if (self.app.destroyRequested != 0 and !self.closed) {
            self.pushEvent(.{ .kind = .close }) catch {};
            self.closed = true;
        }
        return true;
    }

    fn pushEvent(self: *AndroidHost, event: HostEvent) !void {
        if (self.events.items.len >= 16) return;
        try self.events.append(self.allocator, event);
    }

    fn handleCmd(self: *AndroidHost, cmd: i32) void {
        switch (cmd) {
            glue.APP_CMD_INIT_WINDOW => {
                if (self.app.window) |window| {
                    self.pushEvent(.{
                        .kind = .surface_available,
                        .extent = windowExtent(window),
                    }) catch {};
                    self.surface_announced = true;
                }
            },
            glue.APP_CMD_TERM_WINDOW => {
                self.pushEvent(.{ .kind = .surface_lost }) catch {};
                self.surface_announced = false;
            },
            glue.APP_CMD_WINDOW_REDRAW_NEEDED, glue.APP_CMD_CONTENT_RECT_CHANGED => {
                // Rotation/resize: rebuild swapchain at next frame boundary.
                // We deliberately ignore APP_CMD_CONFIG_CHANGED and
                // APP_CMD_WINDOW_RESIZED — those fire before the surface is
                // actually updated, so recreating then would query stale
                // capabilities. REDRAW_NEEDED and CONTENT_RECT_CHANGED come
                // after the new surface is ready.
                if (self.app.window) |window| {
                    if (self.surface_announced) {
                        self.pushEvent(.{
                            .kind = .surface_invalidated,
                            .extent = windowExtent(window),
                        }) catch {};
                    }
                }
            },
            glue.APP_CMD_PAUSE => self.pushEvent(.{ .kind = .paused }) catch {},
            glue.APP_CMD_RESUME => self.pushEvent(.{ .kind = .resumed }) catch {},
            glue.APP_CMD_DESTROY => self.pushEvent(.{ .kind = .close }) catch {},
            else => {},
        }
    }

    fn onAppCmdThunk(app: ?*glue.android_app, cmd: i32) callconv(.c) void {
        const a = app orelse return;
        const raw = a.userData orelse return;
        const self: *AndroidHost = @ptrCast(@alignCast(raw));
        self.handleCmd(cmd);
    }

    fn windowExtent(window: *glue.ANativeWindow) vk.Extent2D {
        return .{
            .width = @intCast(glue.ANativeWindow_getWidth(window)),
            .height = @intCast(glue.ANativeWindow_getHeight(window)),
        };
    }

    fn getAndroidInstanceProcAddr(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction {
        return glue.vkGetInstanceProcAddr(instance, name);
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

    fn cast(ptr: *anyopaque) *AndroidHost {
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
