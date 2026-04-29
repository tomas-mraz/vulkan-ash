const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const registry_path = resolveRegistryPath(b);

    const abi = target.result.abi;
    const is_android = abi == .android or abi == .androideabi;

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = registry_path,
    }).module("vulkan-zig");
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    var imports_buf: [3]std.Build.Module.Import = undefined;
    var imports_len: usize = 0;
    imports_buf[imports_len] = .{ .name = "vulkan", .module = vulkan };
    imports_len += 1;
    imports_buf[imports_len] = .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") };
    imports_len += 1;

    if (!is_android) {
        const glfw_dep = b.dependency("zig_glfw", .{
            .target = target,
            .optimize = optimize,
        });
        imports_buf[imports_len] = .{ .name = "glfw", .module = glfw_dep.module("glfw") };
        imports_len += 1;
    }

    const ash_module = b.addModule("ash", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports_buf[0..imports_len],
    });

    if (is_android) {
        const ndk = resolveAndroidNdk(b);
        const api_level = b.option(u32, "android-api", "Target Android API level") orelse 29;
        const arch_triple = androidArchTriple(target.result.cpu.arch);
        const sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot", .{ndk});
        const native_app_glue_dir = b.fmt("{s}/sources/android/native_app_glue", .{ndk});

        // Headers: NDK sysroot covers libc / android / vulkan; arch-specific
        // dir holds bits/asm headers selected per ABI.
        ash_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
        ash_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, arch_triple }) });
        ash_module.addIncludePath(.{ .cwd_relative = native_app_glue_dir });

        // Libraries: arch+api specific dir holds libc.so, libandroid.so, etc.
        ash_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, arch_triple, api_level }) });

        ash_module.addCSourceFile(.{
            .file = .{ .cwd_relative = b.fmt("{s}/android_native_app_glue.c", .{native_app_glue_dir}) },
            .flags = &.{},
        });
        ash_module.linkSystemLibrary("android", .{});
        ash_module.linkSystemLibrary("log", .{});
        ash_module.linkSystemLibrary("vulkan", .{});
    }

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
        b.fmt("{s}/macOS/share/vulkan/registry/vk.xml", .{sdk_root}),
        b.fmt("{s}/Bin/registry/vk.xml", .{sdk_root}),
    };

    for (candidates) |candidate| {
        std.Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        return .{ .cwd_relative = candidate };
    }

    @panic("vk.xml not found under VULKAN_SDK; expected registry/vk.xml, share/vulkan/registry/vk.xml, x86_64/share/vulkan/registry/vk.xml, macOS/share/vulkan/registry/vk.xml or Bin/registry/vk.xml");
}

fn resolveAndroidNdk(b: *std.Build) []const u8 {
    if (b.option([]const u8, "android-ndk", "Path to the Android NDK root")) |path| return path;
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |path| return path;
    if (b.graph.environ_map.get("ANDROID_NDK_ROOT")) |path| return path;
    @panic("Android target requires -Dandroid-ndk=<path>, ANDROID_NDK_HOME, or ANDROID_NDK_ROOT");
}

fn androidArchTriple(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "aarch64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86_64 => "x86_64-linux-android",
        .x86 => "i686-linux-android",
        else => @panic("unsupported Android architecture"),
    };
}
