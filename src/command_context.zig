const std = @import("std");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;
const Device = @import("manager.zig").Device;

pub const CommandContext = struct {
    allocator: Allocator,
    device: Device,
    cmd_pool: vk.CommandPool = .null_handle,
    cmd_buffers: []vk.CommandBuffer = &.{},

    pub fn init(
        allocator: Allocator,
        device: Device,
        queue_family_index: u32,
        command_buffer_count: usize,
    ) !CommandContext {
        var self = CommandContext{
            .allocator = allocator,
            .device = device,
        };
        errdefer self.destroy();

        self.cmd_pool = try device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = queue_family_index,
        }, null);

        if (command_buffer_count == 0) {
            return self;
        }

        self.cmd_buffers = try allocator.alloc(vk.CommandBuffer, command_buffer_count);
        errdefer allocator.free(self.cmd_buffers);

        try device.allocateCommandBuffers(&.{
            .command_pool = self.cmd_pool,
            .level = .primary,
            .command_buffer_count = @intCast(command_buffer_count),
        }, self.cmd_buffers.ptr);

        return self;
    }

    pub fn destroy(self: *CommandContext) void {
        if (self.cmd_buffers.len > 0) {
            self.device.freeCommandBuffers(self.cmd_pool, self.cmd_buffers);
            self.allocator.free(self.cmd_buffers);
            self.cmd_buffers = &.{};
        }
        if (self.cmd_pool != .null_handle) {
            self.device.destroyCommandPool(self.cmd_pool, null);
            self.cmd_pool = .null_handle;
        }
    }

    pub fn getCmdPool(self: *const CommandContext) vk.CommandPool {
        return self.cmd_pool;
    }

    pub fn getCmdBuffers(self: *const CommandContext) []vk.CommandBuffer {
        return self.cmd_buffers;
    }

    pub fn beginOneTime(self: *CommandContext) !vk.CommandBuffer {
        var command_buffer: vk.CommandBuffer = undefined;
        try self.device.allocateCommandBuffers(&.{
            .command_pool = self.cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, (&command_buffer)[0..1].ptr);
        errdefer self.device.freeCommandBuffers(self.cmd_pool, (&command_buffer)[0..1]);

        try self.device.beginCommandBuffer(command_buffer, &.{
            .flags = .{ .one_time_submit_bit = true },
        });
        return command_buffer;
    }

    pub fn endOneTime(self: *CommandContext, queue: vk.Queue, command_buffer: vk.CommandBuffer) !void {
        try self.device.endCommandBuffer(command_buffer);

        const fence = try self.device.createFence(&.{}, null);
        defer self.device.destroyFence(fence, null);

        try self.device.queueSubmit(queue, &.{.{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
        }}, fence);

        _ = try self.device.waitForFences(&.{fence}, .true, 10 * std.time.ns_per_s);
        self.device.freeCommandBuffers(self.cmd_pool, (&command_buffer)[0..1]);
    }

    pub fn bindVertexBuffers(
        self: *const CommandContext,
        command_buffer: vk.CommandBuffer,
        first_binding: u32,
        buffers: []const vk.Buffer,
        offsets: []const vk.DeviceSize,
    ) void {
        if (buffers.len == 0) {
            return;
        }
        std.debug.assert(buffers.len == offsets.len);
        self.device.cmdBindVertexBuffers(command_buffer, first_binding, buffers, offsets);
    }

    pub fn draw(
        self: *const CommandContext,
        command_buffer: vk.CommandBuffer,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        self.device.cmdDraw(command_buffer, vertex_count, instance_count, first_vertex, first_instance);
    }
};
