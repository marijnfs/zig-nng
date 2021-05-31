const std = @import("std");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;
const builtin = @import("builtin");
const Target = std.build.Target;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    // const lib = b.addStaticLibrary("zig-nng", "src/main.zig");
    // lib.addIncludeDir("ext/nng/include");
    // lib.setBuildMode(mode);
    // lib.linkLibC();
    // lib.install();
    const target = b.standardTargetOptions(.{
        .whitelist = &[_]Target{
            .{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .musl,
            },
            .{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .abi = .gnu,
            },
        },
    });

    const pkg_network = Pkg{
        .name = "zig-network",
        .path = "ext/zig-network/network.zig",
    };

    const pkg_net = Pkg{
        .name = "net",
        .path = "src/net.zig",
        .dependencies = &[_]Pkg{pkg_network},
    };

    var main_tests = b.addTest("src/node.zig");
    main_tests.addIncludeDir("src");
    main_tests.linkLibC();
    main_tests.setBuildMode(mode);

    var net_tests = b.addTest("src/net.zig");
    net_tests.addIncludeDir("src");
    net_tests.addPackagePath("zig-network", "ext/zig-network/network.zig");
    net_tests.linkLibC();
    net_tests.setBuildMode(mode);

    const exe_node = b.addExecutable("node", "src/node.zig");
    exe_node.addIncludeDir("src");
    exe_node.addPackagePath("zbox", "ext/zbox/src/box.zig");
    exe_node.addPackagePath("zig-network", "ext/zig-network/network.zig");
    exe_node.linkLibC();
    exe_node.install();

    const exe_net = b.addExecutable("nettest", "exe/nettest.zig");
    exe_net.addIncludeDir("src");
    exe_net.addPackage(pkg_net);
    exe_net.install();

    const test_step = b.step("test", "Run library tests");
    // test_step.dependOn(&main_tests.step);
    test_step.dependOn(&net_tests.step);
}

pub fn getLibrary(
    b: *Builder,
    mode: builtin.Mode,
    target: std.build.Target,
) *std.build.LibExeObjStep {
    const lib_cflags = &[_][]const u8{"-std=c99"};

    lib.setBuildMode(mode);
    lib.setTarget(target);
    lib.linkSystemLibrary("c");

    return lib;
}
