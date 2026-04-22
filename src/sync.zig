const vk = @import("vulkan");

const Device = @import("manager.zig").Device;

pub const SyncInfo = struct {
    device: Device,
    fence: vk.Fence = .null_handle,
    semaphore: vk.Semaphore = .null_handle,

    pub fn init(device: Device) !SyncInfo {
        var self = SyncInfo{
            .device = device,
        };
        errdefer self.destroy();

        self.fence = try device.createFence(&.{}, null);
        self.semaphore = try device.createSemaphore(&.{}, null);
        return self;
    }

    pub fn destroy(self: *SyncInfo) void {
        if (self.fence != .null_handle) {
            self.device.destroyFence(self.fence, null);
            self.fence = .null_handle;
        }
        if (self.semaphore != .null_handle) {
            self.device.destroySemaphore(self.semaphore, null);
            self.semaphore = .null_handle;
        }
    }
};
