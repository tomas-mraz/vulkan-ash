const std = @import("std");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;
const Manager = @import("manager.zig").Manager;

pub const SwapchainOptions = struct {};

pub const Swapchain = struct {
    pub const PresentState = enum {
        optimal,
        suboptimal,
    };

    manager: *const Manager,
    allocator: Allocator,

    surface_format: vk.SurfaceFormatKHR,
    extent: vk.Extent2D,
    handle: vk.SwapchainKHR,

    swap_images: []SwapImage,
    image_index: u32,
    next_image_acquired: vk.Semaphore,

    pub fn init(manager: *const Manager, allocator: Allocator, extent: vk.Extent2D) !Swapchain {
        return try initRecycle(manager, allocator, extent, .null_handle);
    }

    pub fn deinit(self: Swapchain) void {
        if (self.handle == .null_handle) {
            return;
        }
        self.deinitExceptSwapchain();
        self.manager.device.?.destroySwapchainKHR(self.handle, null);
    }

    pub fn recreate(self: *Swapchain, new_extent: vk.Extent2D) !void {
        const manager = self.manager;
        const allocator = self.allocator;
        const old_handle = self.handle;

        try manager.device.?.queueWaitIdle(manager.present_queue.handle);
        self.deinitExceptSwapchain();

        self.handle = .null_handle;
        self.* = initRecycle(manager, allocator, new_extent, old_handle) catch |err| switch (err) {
            error.SwapchainCreationFailed => {
                manager.device.?.destroySwapchainKHR(old_handle, null);
                return err;
            },
            else => return err,
        };
    }

    pub fn waitForAllFences(self: Swapchain) !void {
        for (self.swap_images) |swap_image| {
            try swap_image.waitForFence(self.manager);
        }
    }

    pub fn present(self: *Swapchain, cmdbuf: vk.CommandBuffer) !PresentState {
        const current = &self.swap_images[self.image_index];
        try current.waitForFence(self.manager);
        try self.manager.device.?.resetFences(&.{current.frame_fence});

        const wait_stage = [_]vk.PipelineStageFlags{.{ .top_of_pipe_bit = true }};
        try self.manager.device.?.queueSubmit(self.manager.graphics_queue.handle, &.{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.image_acquired),
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&current.render_finished),
        }}, current.frame_fence);

        _ = try self.manager.device.?.queuePresentKHR(self.manager.present_queue.handle, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.handle),
            .p_image_indices = @ptrCast(&self.image_index),
        });

        const result = try self.manager.device.?.acquireNextImageKHR(
            self.handle,
            std.math.maxInt(u64),
            self.next_image_acquired,
            .null_handle,
        );

        std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &self.next_image_acquired);
        self.image_index = result.image_index;

        return switch (result.result) {
            .success => .optimal,
            .suboptimal_khr => .suboptimal,
            else => unreachable,
        };
    }

    fn initRecycle(
        manager: *const Manager,
        allocator: Allocator,
        extent: vk.Extent2D,
        old_handle: vk.SwapchainKHR,
    ) !Swapchain {
        const instance = manager.instance orelse return error.InstanceNotInitialized;
        const device = manager.device orelse return error.DeviceNotInitialized;

        const capabilities = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(manager.gpu, manager.surface);
        const actual_extent = findActualExtent(capabilities, extent);
        if (actual_extent.width == 0 or actual_extent.height == 0) {
            return error.InvalidSurfaceDimensions;
        }

        const surface_format = try findSurfaceFormat(instance, manager.gpu, manager.surface, allocator);
        const present_mode = try findPresentMode(instance, manager.gpu, manager.surface, allocator);

        var image_count = capabilities.min_image_count + 1;
        if (capabilities.max_image_count > 0) {
            image_count = @min(image_count, capabilities.max_image_count);
        }

        const queue_families = [_]u32{ manager.graphics_queue.family, manager.present_queue.family };
        const sharing_mode: vk.SharingMode = if (manager.graphics_queue.family != manager.present_queue.family)
            .concurrent
        else
            .exclusive;

        const handle = device.createSwapchainKHR(&.{
            .surface = manager.surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = actual_extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = sharing_mode,
            .queue_family_index_count = if (sharing_mode == .concurrent) queue_families.len else 0,
            .p_queue_family_indices = if (sharing_mode == .concurrent) &queue_families else undefined,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = .true,
            .old_swapchain = old_handle,
        }, null) catch {
            return error.SwapchainCreationFailed;
        };
        errdefer device.destroySwapchainKHR(handle, null);

        if (old_handle != .null_handle) {
            device.destroySwapchainKHR(old_handle, null);
        }

        const swap_images = try initSwapchainImages(manager, handle, surface_format.format, allocator);
        errdefer {
            for (swap_images) |swap_image| {
                swap_image.deinit(manager);
            }
            allocator.free(swap_images);
        }

        var next_image_acquired = try device.createSemaphore(&.{}, null);
        errdefer device.destroySemaphore(next_image_acquired, null);

        const result = try device.acquireNextImageKHR(handle, std.math.maxInt(u64), next_image_acquired, .null_handle);
        if (result.result == .not_ready or result.result == .timeout) {
            return error.ImageAcquireFailed;
        }

        std.mem.swap(vk.Semaphore, &swap_images[result.image_index].image_acquired, &next_image_acquired);
        return .{
            .manager = manager,
            .allocator = allocator,
            .surface_format = surface_format,
            .extent = actual_extent,
            .handle = handle,
            .swap_images = swap_images,
            .image_index = result.image_index,
            .next_image_acquired = next_image_acquired,
        };
    }

    fn deinitExceptSwapchain(self: Swapchain) void {
        for (self.swap_images) |swap_image| {
            swap_image.deinit(self.manager);
        }
        self.allocator.free(self.swap_images);
        self.manager.device.?.destroySemaphore(self.next_image_acquired, null);
    }
};

pub const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,

    fn init(manager: *const Manager, image: vk.Image, format: vk.Format) !SwapImage {
        const device = manager.device orelse return error.DeviceNotInitialized;

        const view = try device.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer device.destroyImageView(view, null);

        const image_acquired = try device.createSemaphore(&.{}, null);
        errdefer device.destroySemaphore(image_acquired, null);

        const render_finished = try device.createSemaphore(&.{}, null);
        errdefer device.destroySemaphore(render_finished, null);

        const frame_fence = try device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer device.destroyFence(frame_fence, null);

        return .{
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: SwapImage, manager: *const Manager) void {
        const device = manager.device orelse return;
        self.waitForFence(manager) catch return;
        device.destroyImageView(self.view, null);
        device.destroySemaphore(self.image_acquired, null);
        device.destroySemaphore(self.render_finished, null);
        device.destroyFence(self.frame_fence, null);
    }

    fn waitForFence(self: SwapImage, manager: *const Manager) !void {
        const device = manager.device orelse return error.DeviceNotInitialized;
        _ = try device.waitForFences(&.{self.frame_fence}, .true, std.math.maxInt(u64));
    }
};

fn initSwapchainImages(
    manager: *const Manager,
    swapchain: vk.SwapchainKHR,
    format: vk.Format,
    allocator: Allocator,
) ![]SwapImage {
    const device = manager.device orelse return error.DeviceNotInitialized;
    const images = try device.getSwapchainImagesAllocKHR(swapchain, allocator);
    defer allocator.free(images);

    const swap_images = try allocator.alloc(SwapImage, images.len);
    errdefer allocator.free(swap_images);

    var index: usize = 0;
    errdefer for (swap_images[0..index]) |swap_image| {
        swap_image.deinit(manager);
    };

    for (images) |image| {
        swap_images[index] = try SwapImage.init(manager, image, format);
        index += 1;
    }

    return swap_images;
}

fn findSurfaceFormat(
    instance: @import("manager.zig").Instance,
    gpu: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: Allocator,
) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };

    const surface_formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(gpu, surface, allocator);
    defer allocator.free(surface_formats);

    for (surface_formats) |surface_format| {
        if (std.meta.eql(surface_format, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0];
}

fn findPresentMode(
    instance: @import("manager.zig").Instance,
    gpu: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: Allocator,
) !vk.PresentModeKHR {
    const present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(gpu, surface, allocator);
    defer allocator.free(present_modes);

    const preferred = [_]vk.PresentModeKHR{ .mailbox_khr, .immediate_khr };
    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .fifo_khr;
}

fn findActualExtent(capabilities: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (capabilities.current_extent.width != 0xFFFF_FFFF) {
        return capabilities.current_extent;
    }

    return .{
        .width = std.math.clamp(extent.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        .height = std.math.clamp(extent.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
    };
}
