const std = @import("std");
const vk = @import("vulkan");
const zigimg = @import("zigimg");

const Allocator = std.mem.Allocator;
const CommandContext = @import("command_context.zig").CommandContext;
const Manager = @import("manager.zig").Manager;

pub const ImageResource = struct {
    image: vk.Image = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    view: vk.ImageView = .null_handle,
    sampler: vk.Sampler = .null_handle,
    format: vk.Format = .undefined,
    extent: vk.Extent3D = .{ .width = 0, .height = 0, .depth = 0 },
    layout: vk.ImageLayout = .undefined,

    pub fn deinit(self: *ImageResource, device: vk.DeviceProxy) void {
        if (self.sampler != .null_handle) {
            device.destroySampler(self.sampler, null);
            self.sampler = .null_handle;
        }
        if (self.view != .null_handle) {
            device.destroyImageView(self.view, null);
            self.view = .null_handle;
        }
        if (self.image != .null_handle) {
            device.destroyImage(self.image, null);
            self.image = .null_handle;
        }
        if (self.memory != .null_handle) {
            device.freeMemory(self.memory, null);
            self.memory = .null_handle;
        }
        self.extent = .{ .width = 0, .height = 0, .depth = 0 };
    }
};

pub const TextureOptions = struct {
    format: vk.Format = .r8g8b8a8_unorm,
    mag_filter: vk.Filter = .linear,
    min_filter: vk.Filter = .linear,
    mipmap_mode: vk.SamplerMipmapMode = .linear,
    address_mode_u: vk.SamplerAddressMode = .repeat,
    address_mode_v: vk.SamplerAddressMode = .repeat,
    address_mode_w: vk.SamplerAddressMode = .repeat,
    anisotropy_enable: vk.Bool32 = .false,
    max_anisotropy: f32 = 1,
    border_color: vk.BorderColor = .int_opaque_black,
    unnormalized_coordinates: vk.Bool32 = .false,
    compare_enable: vk.Bool32 = .false,
    compare_op: vk.CompareOp = .always,
};

pub fn createTextureFromFile(
    allocator: Allocator,
    manager: *const Manager,
    cmd_ctx: *CommandContext,
    path: []const u8,
    options: TextureOptions,
) !ImageResource {
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const encoded = try std.Io.Dir.cwd().readFileAlloc(
        io_threaded.io(),
        path,
        allocator,
        .unlimited,
    );
    defer allocator.free(encoded);

    return createTextureFromEncoded(allocator, manager, cmd_ctx, encoded, options);
}

pub fn createTextureFromEncoded(
    allocator: Allocator,
    manager: *const Manager,
    cmd_ctx: *CommandContext,
    encoded_bytes: []const u8,
    options: TextureOptions,
) !ImageResource {
    var image = try zigimg.Image.fromMemory(allocator, encoded_bytes);
    defer image.deinit(allocator);

    if (image.pixelFormat() != .rgba32) {
        try image.convert(allocator, .rgba32);
    }

    const width: u32 = @intCast(image.width);
    const height: u32 = @intCast(image.height);
    const tight_len = @as(usize, width) * @as(usize, height) * 4;
    const row_pitch = image.rowByteSize();
    const raw = image.rawBytes();

    if (row_pitch == @as(usize, width) * 4 and raw.len == tight_len) {
        return try createTextureFromRgba(
            manager,
            cmd_ctx,
            width,
            height,
            raw,
            options,
        );
    }

    var tight = try allocator.alloc(u8, tight_len);
    defer allocator.free(tight);

    for (0..height) |row| {
        const src_start = row * row_pitch;
        const dst_start = row * @as(usize, width) * 4;
        const src_end = src_start + @as(usize, width) * 4;
        const dst_end = dst_start + @as(usize, width) * 4;
        @memcpy(tight[dst_start..dst_end], raw[src_start..src_end]);
    }

    return try createTextureFromRgba(
        manager,
        cmd_ctx,
        width,
        height,
        tight,
        options,
    );
}

pub fn createTextureFromRgba(
    manager: *const Manager,
    cmd_ctx: *CommandContext,
    width: u32,
    height: u32,
    rgba_pixels: []const u8,
    options: TextureOptions,
) !ImageResource {
    const device = manager.device orelse return error.DeviceNotInitialized;
    const expected_len = @as(usize, width) * @as(usize, height) * 4;
    if (rgba_pixels.len != expected_len) {
        return error.InvalidPixelDataLength;
    }

    const staging_buffer = try device.createBuffer(&.{
        .size = rgba_pixels.len,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer device.destroyBuffer(staging_buffer, null);

    const staging_requirements = device.getBufferMemoryRequirements(staging_buffer);
    const staging_memory = try manager.allocate(staging_requirements, .{
        .host_visible_bit = true,
        .host_coherent_bit = true,
    });
    defer device.freeMemory(staging_memory, null);

    try device.bindBufferMemory(staging_buffer, staging_memory, 0);
    const mapped = try device.mapMemory(staging_memory, 0, vk.WHOLE_SIZE, .{});
    defer device.unmapMemory(staging_memory);
    @memcpy((@as([*]u8, @ptrCast(@alignCast(mapped))))[0..rgba_pixels.len], rgba_pixels);

    var result: ImageResource = .{
        .format = options.format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .layout = .undefined,
    };
    errdefer result.deinit(device);

    result.image = try device.createImage(&.{
        .image_type = .@"2d",
        .format = options.format,
        .extent = result.extent,
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);

    const image_requirements = device.getImageMemoryRequirements(result.image);
    result.memory = try manager.allocate(image_requirements, .{ .device_local_bit = true });
    try device.bindImageMemory(result.image, result.memory, 0);

    result.view = try device.createImageView(&.{
        .image = result.image,
        .view_type = .@"2d",
        .format = options.format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);

    result.sampler = try device.createSampler(&.{
        .mag_filter = options.mag_filter,
        .min_filter = options.min_filter,
        .address_mode_u = options.address_mode_u,
        .address_mode_v = options.address_mode_v,
        .address_mode_w = options.address_mode_w,
        .mip_lod_bias = 0,
        .anisotropy_enable = options.anisotropy_enable,
        .max_anisotropy = options.max_anisotropy,
        .border_color = options.border_color,
        .unnormalized_coordinates = options.unnormalized_coordinates,
        .compare_enable = options.compare_enable,
        .compare_op = options.compare_op,
        .mipmap_mode = options.mipmap_mode,
        .min_lod = 0,
        .max_lod = 0,
    }, null);

    const command_buffer = try cmd_ctx.beginOneTime();
    errdefer device.freeCommandBuffers(cmd_ctx.getCmdPool(), (&command_buffer)[0..1]);

    transitionImageLayout(device, command_buffer, result.image, .undefined, .transfer_dst_optimal, .{ .color_bit = true });
    copyBufferToImage(device, command_buffer, staging_buffer, result.image, width, height);
    transitionImageLayout(device, command_buffer, result.image, .transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });
    try cmd_ctx.endOneTime(manager.graphics_queue.handle, command_buffer);
    result.layout = .shader_read_only_optimal;

    return result;
}

fn transitionImageLayout(
    device: vk.DeviceProxy,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    aspect_mask: vk.ImageAspectFlags,
) void {
    var src_stage: vk.PipelineStageFlags = .{ .top_of_pipe_bit = true };
    var dst_stage: vk.PipelineStageFlags = .{ .transfer_bit = true };
    var src_access_mask: vk.AccessFlags = .{};
    var dst_access_mask: vk.AccessFlags = .{ .transfer_write_bit = true };

    if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
        src_stage = .{ .transfer_bit = true };
        dst_stage = .{ .fragment_shader_bit = true };
        src_access_mask = .{ .transfer_write_bit = true };
        dst_access_mask = .{ .shader_read_bit = true };
    }

    const barrier = vk.ImageMemoryBarrier{
        .src_access_mask = src_access_mask,
        .dst_access_mask = dst_access_mask,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = aspect_mask,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    device.cmdPipelineBarrier(
        command_buffer,
        src_stage,
        dst_stage,
        .{},
        &.{},
        &.{},
        &.{barrier},
    );
}

fn copyBufferToImage(
    device: vk.DeviceProxy,
    command_buffer: vk.CommandBuffer,
    buffer: vk.Buffer,
    image: vk.Image,
    width: u32,
    height: u32,
) void {
    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    device.cmdCopyBufferToImage(command_buffer, buffer, image, .transfer_dst_optimal, &.{region});
}
