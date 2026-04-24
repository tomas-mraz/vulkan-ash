const std = @import("std");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;
const CommandContext = @import("command_context.zig").CommandContext;
const Host = @import("host.zig").Host;
const HostEvent = @import("host.zig").HostEvent;
const HostEventKind = @import("host.zig").HostEventKind;
const Manager = @import("manager.zig").Manager;
const DeviceOptions = @import("manager.zig").DeviceOptions;
const InitOptions = @import("manager.zig").InitOptions;
const SurfaceFactory = @import("manager.zig").SurfaceFactory;
const Swapchain = @import("swapchain.zig").Swapchain;
const SwapchainOptions = @import("swapchain.zig").SwapchainOptions;
const SyncInfo = @import("sync.zig").SyncInfo;

pub const Frame = struct {
    cmd: vk.CommandBuffer,
    image_index: u32,
    extent: vk.Extent2D,
    swapchain: *Swapchain,
};

pub const Orientation = enum {
    any,
    landscape,
    portrait,
};

pub const SessionOptions = struct {
    device_options: DeviceOptions = .{},
    swapchain_options: SwapchainOptions = .{},
};

pub const AcquireNextImageResult = struct {
    image_index: u32,
    acquired: bool,
};

pub const Session = struct {
    allocator: Allocator,
    host: Host,
    app_name: [*:0]const u8,
    opts: SessionOptions,

    manager: ?Manager = null,
    swapchain: ?Swapchain = null,
    cmd_ctx: ?CommandContext = null,
    sync: ?SyncInfo = null,

    needs_recreate: bool = false,
    running: bool = false,
    paused: bool = false,
    primary_orientation: Orientation = .any,

    pub fn init(allocator: Allocator, host: Host, app_name: [*:0]const u8, opts: ?SessionOptions) Session {
        return .{
            .allocator = allocator,
            .host = host,
            .app_name = app_name,
            .opts = opts orelse .{},
        };
    }

    pub fn setPrimaryOrientation(self: *Session, orientation: Orientation) void {
        self.primary_orientation = orientation;
    }

    pub fn run(self: *Session, renderer: anytype) !void {
        try self.host.start();
        defer self.host.shutdown();

        while (true) {
            if (!self.running or self.paused) {
                if (self.host.nextEvent()) |event| {
                    if (try self.handleEvent(event, renderer)) {
                        return;
                    }
                } else {
                    self.host.wait();
                }
                continue;
            }

            while (self.host.nextEvent()) |event| {
                if (try self.handleEvent(event, renderer)) {
                    return;
                }
                if (!self.running or self.paused) {
                    break;
                }
            }

            self.host.pump();
            while (self.host.nextEvent()) |event| {
                if (try self.handleEvent(event, renderer)) {
                    return;
                }
                if (!self.running or self.paused) {
                    break;
                }
            }

            if (!self.running or self.paused) {
                continue;
            }

            self.renderFrame(renderer) catch |err| {
                std.log.err("Session.renderFrame failed: {}", .{err});
            };
        }
    }

    pub fn needsRecreate(self: *const Session) bool {
        return self.needs_recreate;
    }

    pub fn requestRecreate(self: *Session) void {
        self.needs_recreate = true;
    }

    pub fn ackRecreate(self: *Session) void {
        self.needs_recreate = false;
    }

    pub fn acquireNextImage(
        self: *Session,
        timeout: u64,
        semaphore: vk.Semaphore,
        fence: vk.Fence,
    ) !AcquireNextImageResult {
        const swapchain = self.swapchain orelse return error.NoSwapchain;
        const device = self.manager.?.device orelse return error.DeviceNotInitialized;

        const acquired = device.acquireNextImageKHR(swapchain.handle, timeout, semaphore, fence) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.needs_recreate = true;
                return .{
                    .image_index = 0,
                    .acquired = false,
                };
            },
            else => return err,
        };

        if (acquired.result == .suboptimal_khr) {
            self.needs_recreate = true;
        }

        return .{
            .image_index = acquired.image_index,
            .acquired = true,
        };
    }

    pub fn presentImage(self: *Session, image_index: u32, wait_semaphores: []const vk.Semaphore) !bool {
        const swapchain = self.swapchain orelse return error.NoSwapchain;
        const manager = self.manager orelse return error.ManagerNotInitialized;
        const device = manager.device orelse return error.DeviceNotInitialized;

        const result = device.queuePresentKHR(manager.present_queue.handle, &.{
            .wait_semaphore_count = @intCast(wait_semaphores.len),
            .p_wait_semaphores = if (wait_semaphores.len == 0) undefined else wait_semaphores.ptr,
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&swapchain.handle),
            .p_image_indices = @ptrCast(&image_index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.needs_recreate = true;
                return false;
            },
            else => return err,
        };

        if (result == .suboptimal_khr) {
            self.needs_recreate = true;
        }
        return true;
    }

    pub fn beginFrame(self: *Session, image_index: u32) !vk.CommandBuffer {
        const cmd_ctx = self.cmd_ctx orelse return error.NoCommandContext;
        const command_buffers = cmd_ctx.getCmdBuffers();
        if (image_index >= command_buffers.len) {
            return error.CommandBufferOutOfRange;
        }

        const command_buffer = command_buffers[image_index];
        try self.manager.?.device.?.resetCommandBuffer(command_buffer, .{});
        try self.manager.?.device.?.beginCommandBuffer(command_buffer, &.{});
        return command_buffer;
    }

    pub fn endFrame(self: *Session, command_buffer: vk.CommandBuffer) !void {
        try self.manager.?.device.?.endCommandBuffer(command_buffer);
    }

    pub fn submitRender(
        self: *Session,
        command_buffer: vk.CommandBuffer,
        fence: vk.Fence,
        wait_semaphores: []const vk.Semaphore,
    ) !void {
        const manager = self.manager orelse return error.ManagerNotInitialized;
        const device = manager.device orelse return error.DeviceNotInitialized;

        var wait_stages = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
        try device.resetFences(&.{fence});
        try device.queueSubmit(manager.graphics_queue.handle, &.{.{
            .wait_semaphore_count = @intCast(wait_semaphores.len),
            .p_wait_semaphores = if (wait_semaphores.len == 0) undefined else wait_semaphores.ptr,
            .p_wait_dst_stage_mask = if (wait_semaphores.len == 0) undefined else &wait_stages,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
        }}, fence);
    }

    fn handleEvent(self: *Session, event: HostEvent, renderer: anytype) !bool {
        switch (event.kind) {
            .surface_available => {
                if (self.running) {
                    self.requestRecreate();
                    return false;
                }
                try self.setupDevice(renderer, event.extent);
                return false;
            },
            .surface_lost => {
                self.teardownDevice(renderer);
                return false;
            },
            .surface_invalidated => {
                if (self.running) {
                    self.requestRecreate();
                }
                return false;
            },
            .paused => {
                if (self.running) {
                    self.manager.?.device.?.deviceWaitIdle() catch {};
                }
                self.paused = true;
                return false;
            },
            .resumed => {
                self.paused = false;
                return false;
            },
            .close => {
                self.teardownDevice(renderer);
                return true;
            },
        }
    }

    fn setupDevice(self: *Session, renderer: anytype, hint: vk.Extent2D) !void {
        try self.host.initVulkan();
        var base = vk.BaseWrapper.load(self.host.instanceProcAddr());
        try @import("manager.zig").requireInstanceApiVersion(&base, self.opts.device_options.api_version);

        var instance_extensions = std.ArrayList([*:0]const u8).empty;
        defer instance_extensions.deinit(self.allocator);
        try instance_extensions.appendSlice(self.allocator, self.opts.device_options.instance_extensions);
        try instance_extensions.appendSlice(self.allocator, self.host.instanceExtensions());

        var device_options = self.opts.device_options;
        device_options.instance_extensions = instance_extensions.items;

        const init_options = InitOptions{
            .instance_proc_addr = self.host.instanceProcAddr(),
            .surface_factory = SurfaceFactory{
                .context = @constCast(&self.host),
                .callback = createSurfaceFromHost,
            },
            .device = device_options,
        };

        self.manager = try Manager.init(self.allocator, self.app_name, init_options);
        errdefer self.teardownDevice(renderer);

        self.swapchain = try Swapchain.initWithOptions(&self.manager.?, self.allocator, hint, self.opts.swapchain_options);
        self.cmd_ctx = try CommandContext.init(
            self.allocator,
            self.manager.?.device.?,
            self.manager.?.graphics_queue.family,
            self.swapchain.?.imageCount(),
        );
        self.sync = try SyncInfo.init(self.manager.?.device.?);

        try renderer.createOnce(self);
        try renderer.createSized(self, self.swapchain.?.extent);
        self.running = true;
    }

    fn teardownDevice(self: *Session, renderer: anytype) void {
        if (self.manager) |*manager| {
            if (manager.device) |device| {
                device.deviceWaitIdle() catch {};
            }
        }
        if (self.running) {
            renderer.destroySized();
            renderer.destroyOnce();
            self.running = false;
        }
        if (self.sync) |*sync| {
            sync.destroy();
            self.sync = null;
        }
        if (self.cmd_ctx) |*cmd_ctx| {
            cmd_ctx.destroy();
            self.cmd_ctx = null;
        }
        if (self.swapchain) |swapchain| {
            swapchain.deinit();
            self.swapchain = null;
        }
        if (self.manager) |*manager| {
            manager.destroy();
            self.manager = null;
        }
        self.needs_recreate = false;
    }

    fn renderFrame(self: *Session, renderer: anytype) !void {
        if (self.needsRecreate()) {
            try self.recreateSwapchain(renderer);
        }

        const device = self.manager.?.device.?;
        _ = try device.waitForFences(&.{self.sync.?.fence}, .true, 10 * std.time.ns_per_s);

        const acquired = try self.acquireNextImage(std.math.maxInt(u64), self.sync.?.semaphore, .null_handle);
        if (!acquired.acquired) {
            try self.recreateSwapchain(renderer);
            return;
        }

        const command_buffer = try self.beginFrame(acquired.image_index);
        const frame = Frame{
            .cmd = command_buffer,
            .image_index = acquired.image_index,
            .extent = self.swapchain.?.extent,
            .swapchain = &self.swapchain.?,
        };

        if (self.isPrimaryOrientation()) {
            try renderer.draw(self, &frame);
        }

        try self.endFrame(command_buffer);
        try self.submitRender(command_buffer, self.sync.?.fence, &.{self.sync.?.semaphore});
        _ = try self.presentImage(acquired.image_index, &.{});
    }

    fn recreateSwapchain(self: *Session, renderer: anytype) !void {
        const manager = self.manager orelse return error.ManagerNotInitialized;
        try manager.device.?.deviceWaitIdle();

        renderer.destroySized();

        var hint = self.swapchain.?.extent;
        if (self.host.currentExtent()) |current_extent| {
            hint = manager.querySurfaceExtent(current_extent);
        }

        try self.swapchain.?.recreate(hint);
        self.ackRecreate();

        if (self.cmd_ctx) |*cmd_ctx| {
            cmd_ctx.destroy();
            cmd_ctx.* = try CommandContext.init(
                self.allocator,
                manager.device.?,
                manager.graphics_queue.family,
                self.swapchain.?.imageCount(),
            );
        }

        try renderer.createSized(self, self.swapchain.?.extent);
    }

    fn isPrimaryOrientation(self: *const Session) bool {
        if (self.primary_orientation == .any or self.swapchain == null) {
            return true;
        }
        var width = self.swapchain.?.extent.width;
        var height = self.swapchain.?.extent.height;
        if (self.swapchain.?.pre_transform.rotate_90_bit_khr or self.swapchain.?.pre_transform.rotate_270_bit_khr) {
            std.mem.swap(u32, &width, &height);
        }
        return switch (self.primary_orientation) {
            .any => true,
            .landscape => width >= height,
            .portrait => height >= width,
        };
    }
};

fn createSurfaceFromHost(context: ?*anyopaque, instance: @import("manager.zig").Instance) !vk.SurfaceKHR {
    const host: *Host = @ptrCast(@alignCast(context orelse return error.MissingHost));
    return try host.createSurface(instance);
}
