const builtin = @import("builtin");
const std = @import("std");
const glfw = @import("glfw");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const BaseWrapper = vk.BaseWrapper;
pub const Device = vk.DeviceProxy;
const DeviceWrapper = vk.DeviceWrapper;
pub const Instance = vk.InstanceProxy;
const InstanceWrapper = vk.InstanceWrapper;

const validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};

var validation_layers_enabled = false;
var debug_enabled = false;

pub const Queue = struct {
    handle: vk.Queue = .null_handle,
    family: u32 = 0,
};

pub const DeviceOptions = struct {
    instance_extensions: []const [*:0]const u8 = &.{},
    device_extensions: []const [*:0]const u8 = &.{},
    p_next_chain: ?*const anyopaque = null,
    enabled_features: ?*const vk.PhysicalDeviceFeatures = null,
    api_version: u32 = vk.makeApiVersion(0, 1, 0, 0).toU32(),
};

pub const InstanceProcAddr = *const fn (instance: vk.Instance, proc_name: [*:0]const u8) vk.PfnVoidFunction;

pub const SurfaceFactory = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, instance: Instance) anyerror!vk.SurfaceKHR,
};

pub const InitOptions = struct {
    instance_proc_addr: InstanceProcAddr,
    surface_factory: ?SurfaceFactory = null,
    device: DeviceOptions = .{},
};

pub const Manager = struct {
    allocator: Allocator,
    base: BaseWrapper,
    instance: ?Instance = null,
    device: ?Device = null,
    surface: vk.SurfaceKHR = .null_handle,
    gpu: vk.PhysicalDevice = .null_handle,
    properties: vk.PhysicalDeviceProperties = undefined,
    memory_properties: vk.PhysicalDeviceMemoryProperties = undefined,
    graphics_queue: Queue = .{},
    present_queue: Queue = .{},
    queue: Queue = .{},
    debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,
    instance_wrapper: ?*InstanceWrapper = null,
    device_wrapper: ?*DeviceWrapper = null,
    api_version: u32 = vk.makeApiVersion(0, 1, 0, 0).toU32(),

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, options: InitOptions) !Manager {
        var self = Manager{
            .allocator = allocator,
            .base = BaseWrapper.load(options.instance_proc_addr),
            .api_version = options.device.api_version,
        };
        errdefer self.destroy();

        try requireInstanceApiVersion(&self.base, self.api_version);

        var instance_extensions = ArrayList([*:0]const u8).empty;
        defer instance_extensions.deinit(allocator);

        try appendExtensions(&instance_extensions, allocator, options.device.instance_extensions);
        if (debug_enabled) {
            try appendUniqueExtension(&instance_extensions, allocator, vk.extensions.ext_debug_utils.name);
        }
        if (builtin.os.tag.isDarwin()) {
            try appendUniqueExtension(&instance_extensions, allocator, vk.extensions.khr_portability_enumeration.name);
            try appendUniqueExtension(&instance_extensions, allocator, vk.extensions.khr_get_physical_device_properties_2.name);
        }

        var layer_names = ArrayList([*:0]const u8).empty;
        defer layer_names.deinit(allocator);
        if (validation_layers_enabled) {
            try ensureValidationLayersAvailable(&self.base, allocator);
            try layer_names.appendSlice(allocator, &validation_layers);
        }

        var instance_flags = vk.InstanceCreateFlags{};
        if (builtin.os.tag.isDarwin()) {
            instance_flags.enumerate_portability_bit_khr = true;
        }

        const instance_handle = try self.base.createInstance(&.{
            .flags = instance_flags,
            .p_application_info = &.{
                .p_application_name = app_name,
                .application_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
                .p_engine_name = "ash",
                .engine_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
                .api_version = self.api_version,
            },
            .enabled_layer_count = @intCast(layer_names.items.len),
            .pp_enabled_layer_names = if (layer_names.items.len == 0) undefined else layer_names.items.ptr,
            .enabled_extension_count = @intCast(instance_extensions.items.len),
            .pp_enabled_extension_names = if (instance_extensions.items.len == 0) undefined else instance_extensions.items.ptr,
        }, null);

        const instance_wrapper = try allocator.create(InstanceWrapper);
        errdefer allocator.destroy(instance_wrapper);
        instance_wrapper.* = InstanceWrapper.load(instance_handle, self.base.dispatch.vkGetInstanceProcAddr.?);
        self.instance_wrapper = instance_wrapper;
        self.instance = Instance.init(instance_handle, instance_wrapper);

        if (debug_enabled and self.instance.?.wrapper.dispatch.vkCreateDebugUtilsMessengerEXT != null) {
            self.debug_messenger = try self.instance.?.createDebugUtilsMessengerEXT(&.{
                .message_severity = .{
                    .warning_bit_ext = true,
                    .error_bit_ext = true,
                },
                .message_type = .{
                    .general_bit_ext = true,
                    .validation_bit_ext = true,
                    .performance_bit_ext = true,
                },
                .pfn_user_callback = &debugUtilsMessengerCallback,
            }, null);
        }

        if (options.surface_factory) |factory| {
            self.surface = try factory.callback(factory.context, self.instance.?);
        }

        const selection = try pickPhysicalDevice(self.instance.?, allocator, self.surface, self.api_version);
        self.gpu = selection.handle;
        self.properties = self.instance.?.getPhysicalDeviceProperties(self.gpu);
        self.memory_properties = self.instance.?.getPhysicalDeviceMemoryProperties(self.gpu);

        var device_extensions = ArrayList([*:0]const u8).empty;
        defer device_extensions.deinit(allocator);
        try appendExtensions(&device_extensions, allocator, options.device.device_extensions);
        if (self.surface != .null_handle) {
            try appendUniqueExtension(&device_extensions, allocator, vk.extensions.khr_swapchain.name);
        }
        if (builtin.os.tag.isDarwin() and try hasDeviceExtension(self.instance.?, allocator, self.gpu, vk.extensions.khr_portability_subset.name)) {
            try appendUniqueExtension(&device_extensions, allocator, vk.extensions.khr_portability_subset.name);
        }

        if (!try checkDeviceExtensions(self.instance.?, allocator, self.gpu, device_extensions.items)) {
            return error.MissingRequiredDeviceExtension;
        }

        const priorities = [_]f32{1.0};
        const queue_infos = [_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = selection.graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &priorities,
            },
            .{
                .queue_family_index = selection.present_family,
                .queue_count = 1,
                .p_queue_priorities = &priorities,
            },
        };
        const queue_info_count: u32 = if (selection.graphics_family == selection.present_family) 1 else 2;

        const device_handle = try self.instance.?.createDevice(self.gpu, &.{
            .queue_create_info_count = queue_info_count,
            .p_queue_create_infos = &queue_infos,
            .enabled_extension_count = @intCast(device_extensions.items.len),
            .pp_enabled_extension_names = if (device_extensions.items.len == 0) undefined else device_extensions.items.ptr,
            .p_enabled_features = if (options.device.enabled_features) |features| features else null,
            .p_next = options.device.p_next_chain,
        }, null);

        const device_wrapper = try allocator.create(DeviceWrapper);
        errdefer allocator.destroy(device_wrapper);
        device_wrapper.* = DeviceWrapper.load(device_handle, self.instance.?.wrapper.dispatch.vkGetDeviceProcAddr.?);
        self.device_wrapper = device_wrapper;
        self.device = Device.init(device_handle, device_wrapper);

        self.graphics_queue = .{
            .handle = self.device.?.getDeviceQueue(selection.graphics_family, 0),
            .family = selection.graphics_family,
        };
        self.present_queue = .{
            .handle = self.device.?.getDeviceQueue(selection.present_family, 0),
            .family = selection.present_family,
        };
        self.queue = self.graphics_queue;

        return self;
    }

    pub fn initGlfw(
        allocator: Allocator,
        app_name: [*:0]const u8,
        window: glfw.Window,
        device_options: DeviceOptions,
    ) !Manager {
        if (!glfw.vulkanSupported()) {
            return error.VulkanNotSupported;
        }

        const glfw_extensions = glfw.getRequiredInstanceExtensions() orelse {
            return error.MissingRequiredInstanceExtensions;
        };

        var combined = ArrayList([*:0]const u8).empty;
        defer combined.deinit(allocator);
        try appendExtensions(&combined, allocator, glfw_extensions);
        try appendExtensions(&combined, allocator, device_options.instance_extensions);

        var options = InitOptions{
            .instance_proc_addr = getGlfwInstanceProcAddr,
            .surface_factory = .{
                .context = @constCast(&window),
                .callback = createGlfwSurface,
            },
            .device = device_options,
        };
        options.device.instance_extensions = combined.items;

        return try Manager.init(allocator, app_name, options);
    }

    pub fn destroy(self: *Manager) void {
        if (self.device) |device| {
            device.deviceWaitIdle() catch {};
            device.destroyDevice(null);
            self.device = null;
        }
        if (self.device_wrapper) |wrapper| {
            self.allocator.destroy(wrapper);
            self.device_wrapper = null;
        }
        if (self.instance) |instance| {
            if (self.surface != .null_handle) {
                instance.destroySurfaceKHR(self.surface, null);
                self.surface = .null_handle;
            }
            if (self.debug_messenger != .null_handle) {
                instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
                self.debug_messenger = .null_handle;
            }
            instance.destroyInstance(null);
            self.instance = null;
        }
        if (self.instance_wrapper) |wrapper| {
            self.allocator.destroy(wrapper);
            self.instance_wrapper = null;
        }
        self.gpu = .null_handle;
        self.graphics_queue = .{};
        self.present_queue = .{};
        self.queue = .{};
    }

    pub fn getDebugMessenger(self: *const Manager) vk.DebugUtilsMessengerEXT {
        return self.debug_messenger;
    }

    pub fn querySurfaceExtent(self: *const Manager, fallback: vk.Extent2D) vk.Extent2D {
        if (self.instance == null or self.surface == .null_handle or self.gpu == .null_handle) {
            return fallback;
        }
        const capabilities = self.instance.?.getPhysicalDeviceSurfaceCapabilitiesKHR(self.gpu, self.surface) catch {
            return fallback;
        };
        if (capabilities.current_extent.width == std.math.maxInt(u32) and capabilities.current_extent.height == std.math.maxInt(u32)) {
            return fallback;
        }
        if (capabilities.current_extent.width == 0 or capabilities.current_extent.height == 0) {
            return fallback;
        }
        return capabilities.current_extent;
    }

    pub fn deviceName(self: *const Manager) []const u8 {
        return std.mem.sliceTo(&self.properties.device_name, 0);
    }

    pub fn findMemoryTypeIndex(
        self: *const Manager,
        memory_type_bits: u32,
        flags: vk.MemoryPropertyFlags,
    ) !u32 {
        for (self.memory_properties.memory_types[0..self.memory_properties.memory_type_count], 0..) |memory_type, index| {
            if (memory_type_bits & (@as(u32, 1) << @as(u5, @truncate(index))) == 0) {
                continue;
            }
            if (memory_type.property_flags.contains(flags)) {
                return @truncate(index);
            }
        }
        return error.NoSuitableMemoryType;
    }

    pub fn allocate(
        self: *const Manager,
        requirements: vk.MemoryRequirements,
        flags: vk.MemoryPropertyFlags,
    ) !vk.DeviceMemory {
        const device = self.device orelse return error.DeviceNotInitialized;
        return try device.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
        }, null);
    }
};

pub fn setDebug(state: bool) void {
    debug_enabled = state;
}

pub fn setValidations(state: bool) void {
    validation_layers_enabled = state;
}

pub fn newExtentSize(width: usize, height: usize) vk.Extent2D {
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

pub fn requireInstanceApiVersion(base: *const BaseWrapper, min_version: u32) !void {
    if (min_version == 0) {
        return;
    }
    const actual = base.enumerateInstanceVersion() catch vk.API_VERSION_1_0.toU32();
    if (actual < min_version) {
        std.log.err("required Vulkan API version {}.{}.{}, loader reports {}.{}.{}", .{
            apiVersionMajor(min_version),
            apiVersionMinor(min_version),
            apiVersionPatch(min_version),
            apiVersionMajor(actual),
            apiVersionMinor(actual),
            apiVersionPatch(actual),
        });
        return error.InsufficientInstanceApiVersion;
    }
}

pub fn checkDeviceExtensions(
    instance: Instance,
    allocator: Allocator,
    gpu: vk.PhysicalDevice,
    required: []const [*:0]const u8,
) !bool {
    const props = try instance.enumerateDeviceExtensionPropertiesAlloc(gpu, null, allocator);
    defer allocator.free(props);

    outer: for (required) |name| {
        for (props) |prop| {
            if (std.mem.eql(u8, std.mem.span(name), std.mem.sliceTo(&prop.extension_name, 0))) {
                continue :outer;
            }
        }
        return false;
    }
    return true;
}

fn appendExtensions(
    list: *ArrayList([*:0]const u8),
    allocator: Allocator,
    extensions: []const [*:0]const u8,
) !void {
    for (extensions) |extension| {
        try appendUniqueExtension(list, allocator, extension);
    }
}

fn appendUniqueExtension(
    list: *ArrayList([*:0]const u8),
    allocator: Allocator,
    extension: [*:0]const u8,
) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, std.mem.span(existing), std.mem.span(extension))) {
            return;
        }
    }
    try list.append(allocator, extension);
}

fn ensureValidationLayersAvailable(base: *const BaseWrapper, allocator: Allocator) !void {
    const available_layers = try base.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(available_layers);

    outer: for (validation_layers) |required_layer| {
        for (available_layers) |layer| {
            if (std.mem.eql(u8, std.mem.span(required_layer), std.mem.sliceTo(&layer.layer_name, 0))) {
                continue :outer;
            }
        }
        return error.MissingValidationLayer;
    }
}

fn hasDeviceExtension(
    instance: Instance,
    allocator: Allocator,
    gpu: vk.PhysicalDevice,
    extension: [*:0]const u8,
) !bool {
    return checkDeviceExtensions(instance, allocator, gpu, &.{extension});
}

const DeviceSelection = struct {
    handle: vk.PhysicalDevice,
    graphics_family: u32,
    present_family: u32,
    score: i32,
};

fn pickPhysicalDevice(
    instance: Instance,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
    min_api_version: u32,
) !DeviceSelection {
    const gpus = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(gpus);

    var best: ?DeviceSelection = null;

    for (gpus, 0..) |gpu, index| {
        const props = instance.getPhysicalDeviceProperties(gpu);
        if (min_api_version != 0 and props.api_version < min_api_version) {
            continue;
        }
        const queue_families = (try findQueueFamilies(instance, allocator, gpu, surface)) orelse continue;
        const score = scorePhysicalDevice(props, index);
        if (best == null or score > best.?.score) {
            best = .{
                .handle = gpu,
                .graphics_family = queue_families.graphics_family,
                .present_family = queue_families.present_family,
                .score = score,
            };
        }
    }

    return best orelse error.NoSuitableDevice;
}

const QueueFamilies = struct {
    graphics_family: u32,
    present_family: u32,
};

fn findQueueFamilies(
    instance: Instance,
    allocator: Allocator,
    gpu: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !?QueueFamilies {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(gpu, allocator);
    defer allocator.free(families);

    var graphics_only: ?u32 = null;
    var present_only: ?u32 = null;
    for (families, 0..) |family, index| {
        const family_index: u32 = @intCast(index);
        if (graphics_only == null and family.queue_flags.graphics_bit) {
            graphics_only = family_index;
        }
        if (surface == .null_handle) {
            continue;
        }
        if (present_only == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(gpu, family_index, surface)) == .true) {
            present_only = family_index;
        }
    }
    if (graphics_only == null) {
        return null;
    }
    if (surface == .null_handle) {
        return .{
            .graphics_family = graphics_only.?,
            .present_family = graphics_only.?,
        };
    }
    if (present_only == null) {
        return null;
    }
    return .{
        .graphics_family = graphics_only.?,
        .present_family = present_only.?,
    };
}

fn scorePhysicalDevice(props: vk.PhysicalDeviceProperties, index: usize) i32 {
    const name = std.mem.sliceTo(&props.device_name, 0);
    const type_name = @tagName(props.device_type);

    var score: i32 = 0;
    if (props.api_version >= vk.API_VERSION_1_3.toU32()) {
        score += 300;
    } else if (props.api_version >= vk.API_VERSION_1_2.toU32()) {
        score += 200;
    } else if (props.api_version >= vk.API_VERSION_1_1.toU32()) {
        score += 100;
    }
    if (std.mem.indexOf(u8, type_name, "discrete") != null) {
        score += 200;
    } else if (std.mem.indexOf(u8, type_name, "integrated") != null) {
        score += 100;
    }
    if (index == 0) {
        score += 100;
    }
    if (builtin.os.tag.isDarwin() and std.ascii.indexOfIgnoreCase(name, "kosmickrisp") != null) {
        score += 500;
    }
    return score;
}

fn getGlfwInstanceProcAddr(instance: vk.Instance, proc_name: [*:0]const u8) vk.PfnVoidFunction {
    return @ptrCast(glfw.getInstanceProcAddress(
        if (instance == .null_handle) null else @ptrFromInt(@intFromEnum(instance)),
        proc_name,
    ));
}

fn createGlfwSurface(context: ?*anyopaque, instance: Instance) !vk.SurfaceKHR {
    const window: *const glfw.Window = @ptrCast(@alignCast(context orelse return error.MissingWindowHandle));
    var surface: vk.SurfaceKHR = undefined;
    const result: vk.Result = @enumFromInt(glfw.createWindowSurface(instance.handle, window.*, null, &surface));
    if (result != .success) {
        return error.SurfaceInitFailed;
    }
    return surface;
}

fn debugUtilsMessengerCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_type: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    const severity_name = if (severity.error_bit_ext)
        "error"
    else if (severity.warning_bit_ext)
        "warning"
    else if (severity.info_bit_ext)
        "info"
    else
        "verbose";
    const type_name = if (message_type.validation_bit_ext)
        "validation"
    else if (message_type.performance_bit_ext)
        "performance"
    else
        "general";
    const message: []const u8 = if (callback_data) |data|
        if (data.p_message) |ptr| std.mem.span(ptr) else "no message"
    else
        "no message";
    std.log.warn("vulkan {s}/{s}: {s}", .{ severity_name, type_name, message });
    return .false;
}

fn apiVersionMajor(version: u32) u32 {
    return version >> 22;
}

fn apiVersionMinor(version: u32) u32 {
    return (version >> 12) & 0x3ff;
}

fn apiVersionPatch(version: u32) u32 {
    return version & 0xfff;
}
