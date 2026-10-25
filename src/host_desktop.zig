const std = @import("std");
const sdl = @import("sdl");
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
    window: ?*sdl.SDL_Window = null,
    events: ArrayListUnmanaged(HostEvent) = .empty,
    closed: bool = false,
    minimized: bool = false,
    sdl_initialized: bool = false,
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

        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
            logSdlError("SDL_Init");
            return error.SdlInitFailed;
        }
        self.sdl_initialized = true;
        errdefer {
            sdl.SDL_Quit();
            self.sdl_initialized = false;
        }

        // HIGH_PIXEL_DENSITY: render at the native resolution on HiDPI
        // displays (Retina); sizes below are queried in pixels.
        var flags: sdl.SDL_WindowFlags = sdl.SDL_WINDOW_VULKAN | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        if (self.fullscreen) {
            // Borderless fullscreen at the desktop mode of the primary display.
            const mode = sdl.SDL_GetDesktopDisplayMode(sdl.SDL_GetPrimaryDisplay()) orelse {
                logSdlError("SDL_GetDesktopDisplayMode");
                return error.NoVideoMode;
            };
            self.width = @intCast(mode.*.w);
            self.height = @intCast(mode.*.h);
            flags |= sdl.SDL_WINDOW_FULLSCREEN;
        } else {
            flags |= sdl.SDL_WINDOW_RESIZABLE;
        }

        const window = sdl.SDL_CreateWindow(self.title, @intCast(self.width), @intCast(self.height), flags) orelse {
            logSdlError("SDL_CreateWindow");
            return error.WindowCreationFailed;
        };
        errdefer sdl.SDL_DestroyWindow(window);

        self.window = window;
        self.closed = false;
        self.minimized = false;
        self.surface_announced = false;

        if (self.fullscreen) {
            _ = sdl.SDL_HideCursor();
        }

        try self.waitForInitialConfigure();

        try self.pushEvent(.{
            .kind = .surface_available,
            .extent = self.currentExtentUnchecked(),
        });
        self.surface_announced = true;
    }

    fn waitForInitialConfigure(self: *DesktopHost) !void {
        const max_iterations: u32 = 20;
        const iteration_timeout_ms: i32 = 50;
        var i: u32 = 0;
        while (i < max_iterations) : (i += 1) {
            const extent = self.currentExtentUnchecked();
            if (extent.width != 0 and extent.height != 0) return;
            var event: sdl.SDL_Event = undefined;
            if (sdl.SDL_WaitEventTimeout(&event, iteration_timeout_ms)) {
                self.handleEvent(&event);
            }
        }
        return error.SurfaceConfigureTimeout;
    }

    pub fn initVulkan(self: *DesktopHost) !void {
        _ = self;
        // SDL loads the Vulkan loader when a SDL_WINDOW_VULKAN window is created.
        if (sdl.SDL_Vulkan_GetVkGetInstanceProcAddr() == null) {
            logSdlError("SDL_Vulkan_GetVkGetInstanceProcAddr");
            return error.VulkanNotSupported;
        }
    }

    pub fn instanceProcAddr(self: *DesktopHost) InstanceProcAddr {
        _ = self;
        return getSdlInstanceProcAddr;
    }

    pub fn instanceExtensions(self: *DesktopHost) []const [*:0]const u8 {
        if (self.window == null) {
            return &.{};
        }
        var count: u32 = 0;
        const extensions = sdl.SDL_Vulkan_GetInstanceExtensions(&count) orelse return &.{};
        const items: [*]const [*:0]const u8 = @ptrCast(extensions);
        return items[0..count];
    }

    pub fn createSurface(self: *DesktopHost, instance: Instance) !vk.SurfaceKHR {
        const window = self.window orelse return error.NoWindow;

        var surface: sdl.VkSurfaceKHR = undefined;
        if (!sdl.SDL_Vulkan_CreateSurface(window, @ptrFromInt(@intFromEnum(instance.handle)), null, &surface)) {
            logSdlError("SDL_Vulkan_CreateSurface");
            return error.SurfaceInitFailed;
        }
        return switch (@typeInfo(sdl.VkSurfaceKHR)) {
            // Non-dispatchable handles are pointers on 64-bit targets, u64 otherwise.
            .optional, .pointer => @enumFromInt(@intFromPtr(surface)),
            else => @enumFromInt(surface),
        };
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
        var event: sdl.SDL_Event = undefined;
        if (sdl.SDL_WaitEvent(&event)) {
            self.handleEvent(&event);
        }
        self.drainEvents();
    }

    pub fn pump(self: *DesktopHost) void {
        if (self.window == null or self.closed) {
            return;
        }
        self.drainEvents();
    }

    pub fn shutdown(self: *DesktopHost) void {
        if (self.window) |window| {
            _ = sdl.SDL_ShowCursor();
            sdl.SDL_DestroyWindow(window);
            self.window = null;
        }
        if (self.sdl_initialized) {
            sdl.SDL_Quit();
            self.sdl_initialized = false;
        }
        self.events.deinit(self.allocator);
        self.events = .empty;
        self.closed = true;
    }

    fn currentExtentUnchecked(self: *DesktopHost) vk.Extent2D {
        var width: c_int = 0;
        var height: c_int = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(self.window.?, &width, &height);
        return .{
            .width = @intCast(@max(width, 0)),
            .height = @intCast(@max(height, 0)),
        };
    }

    fn drainEvents(self: *DesktopHost) void {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            self.handleEvent(&event);
        }
    }

    fn handleEvent(self: *DesktopHost, event: *const sdl.SDL_Event) void {
        switch (event.type) {
            sdl.SDL_EVENT_QUIT, sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.pushCloseEvent(),
            sdl.SDL_EVENT_WINDOW_MINIMIZED => {
                self.minimized = true;
                self.pushEvent(.{ .kind = .paused }) catch {};
            },
            sdl.SDL_EVENT_WINDOW_RESTORED => {
                // RESTORED also follows un-maximizing; only a minimized
                // window was paused.
                if (!self.minimized) return;
                self.minimized = false;
                self.pushEvent(.{ .kind = .resumed }) catch {};
            },
            sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
                const width = event.window.data1;
                const height = event.window.data2;
                if (width <= 0 or height <= 0) {
                    return;
                }
                if (!self.surface_announced) {
                    return;
                }
                self.pushEvent(.{
                    .kind = .surface_invalidated,
                    .extent = .{ .width = @intCast(width), .height = @intCast(height) },
                }) catch {};
            },
            else => {},
        }
    }

    fn pushEvent(self: *DesktopHost, event: HostEvent) !void {
        if (self.events.items.len >= 16) {
            return;
        }
        try self.events.append(self.allocator, event);
    }

    fn pushCloseEvent(self: *DesktopHost) void {
        if (self.closed) {
            return;
        }
        self.closed = true;
        self.pushEvent(.{ .kind = .close }) catch {};
    }

    fn logSdlError(what: []const u8) void {
        std.log.err("{s}: {s}", .{ what, sdl.SDL_GetError() });
    }

    fn getSdlInstanceProcAddr(instance: vk.Instance, proc_name: [*:0]const u8) vk.PfnVoidFunction {
        const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @ptrCast(sdl.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse return null);
        return get_instance_proc_addr(instance, proc_name);
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
