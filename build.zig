const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const registry_path = resolveRegistryPath(b);

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

fn resolveRegistryPath(b: *std.Build) std.Build.LazyPath {
    const sdk_root = b.graph.environ_map.get("VULKAN_SDK") orelse
        @panic("VULKAN_SDK is not set; point it to the Vulkan SDK root");
    const io = b.graph.io;
    const candidates = [_][]const u8{
        b.fmt("{s}/registry/vk.xml", .{sdk_root}),
        b.fmt("{s}/share/vulkan/registry/vk.xml", .{sdk_root}),
        b.fmt("{s}/x86_64/share/vulkan/registry/vk.xml", .{sdk_root}),
    };

    for (candidates) |candidate| {
        std.Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        return .{ .cwd_relative = candidate };
    }

    @panic("vk.xml not found under VULKAN_SDK; expected registry/vk.xml, share/vulkan/registry/vk.xml, or x86_64/share/vulkan/registry/vk.xml");
}
