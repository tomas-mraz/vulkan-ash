const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const registry_path: std.Build.LazyPath = .{
        .cwd_relative = "C:/Programs/VulkanSDK/1.4.341.1/share/vulkan/registry/vk.xml",
    };

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = registry_path,
    }).module("vulkan-zig");
    const glfw_dep = b.dependency("zig_glfw", .{
        .target = target,
        .optimize = optimize,
    });
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const ash_module = b.addModule("ash", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "glfw", .module = glfw_dep.module("glfw") },
            .{ .name = "vulkan", .module = vulkan },
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
        },
    });

    const lib = b.addLibrary(.{
        .name = "ash",
        .linkage = .static,
        .root_module = ash_module,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = ash_module,
    });

    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run ash tests");
    test_step.dependOn(&test_run.step);
}
