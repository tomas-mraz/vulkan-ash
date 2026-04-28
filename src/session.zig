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

const hitch_threshold_ns: u64 = 20 * std.time.ns_per_ms;
const hitch_diagnostics_enabled: bool = true;

const FrameStageTimes = struct {
    pump_ns: u64 = 0,
    wait_ns: u64 = 0,
    record_ns: u64 = 0,
    submit_ns: u64 = 0,
    present_ns: u64 = 0,
    acquire_ns: u64 = 0,
    total_ns: u64 = 0,
};

pub const Session = struct {
    allocator: Allocator,
    host: Host,
    app_name: [*:0]const u8,
    opts: SessionOptions,

    manager: ?Manager = null,
    swapchain: ?Swapchain = null,
    cmd_ctx: ?CommandContext = null,

    needs_recreate: bool = false,
    running: bool = false,
    paused: bool = false,
    primary_orientation: Orientation = .any,

    stages: FrameStageTimes = .{},

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

            const iter_start_ns = self.now();
            self.stages = .{};

            while (self.host.nextEvent()) |event| {
                if (try self.handleEvent(event, renderer)) {
                    return;
                }
                if (!self.running or self.paused) {
                    break;
                }
            }

            const pump_start_ns = self.now();
            self.host.pump();
            while (self.host.nextEvent()) |event| {
                if (try self.handleEvent(event, renderer)) {
                    return;
                }
                if (!self.running or self.paused) {
                    break;
                }
            }
            self.stages.pump_ns = self.now() -% pump_start_ns;

            if (!self.running or self.paused) {
                continue;
            }

            self.renderFrame(renderer) catch |err| {
                std.log.err("Session.renderFrame failed: {}", .{err});
            };

            self.stages.total_ns = self.now() -% iter_start_ns;
            if (hitch_diagnostics_enabled and self.stages.total_ns > hitch_threshold_ns) {
                std.log.warn(
                    "session frame stages [ms]: total={d:.2} pump={d:.2} wait={d:.2} record={d:.2} submit={d:.2} present={d:.2} acquire={d:.2}",
                    .{
                        nsToMs(self.stages.total_ns),
                        nsToMs(self.stages.pump_ns),
                        nsToMs(self.stages.wait_ns),
                        nsToMs(self.stages.record_ns),
                        nsToMs(self.stages.submit_ns),
                        nsToMs(self.stages.present_ns),
                        nsToMs(self.stages.acquire_ns),
                    },
                );
            }
        }
    }

    fn now(self: *Session) u64 {
        _ = self;
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
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

    fn beginFrame(self: *Session, image_index: u32) !vk.CommandBuffer {
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

    fn endFrame(self: *Session, command_buffer: vk.CommandBuffer) !void {
        try self.manager.?.device.?.endCommandBuffer(command_buffer);
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

        const manager = &self.manager.?;
        const device = manager.device.?;
        const swapchain = &self.swapchain.?;
        const image_index = swapchain.image_index;
        const swap_image = &swapchain.swap_images[image_index];

        // Wait for previous use of this image to finish before reusing its
        // command buffer and signaling its fence again. CPU work for the
        // next frame can already be in flight on a different image.
        const wait_start = self.now();
        _ = try device.waitForFences(&.{swap_image.frame_fence}, .true, std.math.maxInt(u64));
        try device.resetFences(&.{swap_image.frame_fence});
        self.stages.wait_ns = self.now() -% wait_start;

        const record_start = self.now();
        const command_buffer = try self.beginFrame(image_index);
        const frame = Frame{
            .cmd = command_buffer,
            .image_index = image_index,
            .extent = swapchain.extent,
            .swapchain = swapchain,
        };

        if (self.isPrimaryOrientation()) {
            try renderer.draw(self, &frame);
        }

        try self.endFrame(command_buffer);
        self.stages.record_ns = self.now() -% record_start;

        const submit_start = self.now();
        const wait_stages = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
        try device.queueSubmit(manager.graphics_queue.handle, &.{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&swap_image.image_acquired),
            .p_wait_dst_stage_mask = &wait_stages,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&swap_image.render_finished),
        }}, swap_image.frame_fence);
        self.stages.submit_ns = self.now() -% submit_start;

        const present_start = self.now();
        const present_result = device.queuePresentKHR(manager.present_queue.handle, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&swap_image.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&swapchain.handle),
            .p_image_indices = @ptrCast(&image_index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.needs_recreate = true;
                return;
            },
            else => return err,
        };
        if (present_result == .suboptimal_khr) {
            self.needs_recreate = true;
        }
        self.stages.present_ns = self.now() -% present_start;

        // Acquire next image now so the next frame already has a valid
        // image_index plus a semaphore that will be signaled when the image
        // is presentable. Lets the CPU prepare frame N+1 in parallel with
        // GPU work on frame N.
        const acquire_start = self.now();
        _ = swapchain.acquireNext() catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.needs_recreate = true;
            },
            else => return err,
        };
        self.stages.acquire_ns = self.now() -% acquire_start;
    }

    fn nsToMs(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
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
