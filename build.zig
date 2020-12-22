const std = @import("std");
const Builder = std.build.Builder;
const builtin = @import("builtin");

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    // const lib = b.addStaticLibrary("zig-nng", "src/main.zig");
    // lib.addIncludeDir("nng/include");
    // lib.setBuildMode(mode);
    // lib.linkLibC();
    // lib.install();

    const nng_lib = getLibrary(b, mode);
    nng_lib.install();

    var main_tests = b.addTest("src/main.zig");
    main_tests.addIncludeDir("nng/include");
    main_tests.addIncludeDir("src");
    main_tests.linkLibC();
    main_tests.setBuildMode(mode);
    main_tests.linkLibrary(nng_lib);

    const exe_server = b.addExecutable("server", "src/server.zig");
    exe_server.addIncludeDir("nng/include");
    exe_server.addIncludeDir("src");
    exe_server.linkSystemLibrary("nng"); //Todo, link to locally build library
    exe_server.linkLibC();
    exe_server.install();

    const exe_client = b.addExecutable("client", "src/client.zig");
    exe_client.addIncludeDir("nng/include");
    exe_client.addIncludeDir("src");
    exe_client.linkSystemLibrary("nng"); //Todo, link to locally build library
    exe_client.linkLibC();
    exe_client.install();

    const exe_node = b.addExecutable("node", "src/node.zig");
    exe_node.addIncludeDir("nng/include");
    exe_node.addIncludeDir("src");
    exe_node.linkSystemLibrary("nng"); //Todo, link to locally build library
    exe_node.linkLibC();
    exe_node.install();

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}

pub fn getLibrary(
    b: *Builder,
    mode: builtin.Mode,
    // target: std.build.Target,
) *std.build.LibExeObjStep {
    const lib_cflags = &[_][]const u8{"-std=c99"};
    const lib = b.addStaticLibrary("nng", null);
    lib.setBuildMode(mode);
    // lib.setTarget(target);
    lib.linkSystemLibrary("c");

    lib.defineCMacro("NNG_PLATFORM_POSIX");
    lib.defineCMacro("NNG_PLATFORM_LINUX");
    lib.defineCMacro("NNG_USE_EVENTFD");
    lib.defineCMacro("NNG_HAVE_ABSTRACT_SOCKETS");

    lib.defineCMacro("_GNU_SOURCE");
    lib.defineCMacro("_REENTRANT");
    lib.defineCMacro("_THREAD_SAFE");
    lib.defineCMacro("_POSIX_PTHREAD_SEMANTICS");

    lib.addIncludeDir("nng/include");
    lib.addIncludeDir("nng/src");

    for (nng_src_files) |src_file| {
        lib.addCSourceFile(src_file, lib_cflags);
    }

    return lib;
}

// List all nng source files
const nng_src_files = [_][]const u8{
    "nng/src/core/aio.c",
    "nng/src/core/clock.c",
    "nng/src/core/device.c",
    "nng/src/core/dialer.c",
    "nng/src/core/file.c",
    "nng/src/core/idhash.c",
    "nng/src/core/init.c",
    "nng/src/core/list.c",
    "nng/src/core/listener.c",
    "nng/src/core/lmq.c",
    "nng/src/core/message.c",
    "nng/src/core/msgqueue.c",
    "nng/src/core/options.c",
    "nng/src/core/panic.c",
    "nng/src/core/pipe.c",
    "nng/src/core/pollable.c",
    "nng/src/core/protocol.c",
    "nng/src/core/reap.c",
    "nng/src/core/socket.c",
    "nng/src/core/stats.c",
    "nng/src/core/stream.c",
    "nng/src/core/strs.c",
    "nng/src/core/taskq.c",
    "nng/src/core/tcp.c",
    "nng/src/core/thread.c",
    "nng/src/core/timer.c",
    "nng/src/core/transport.c",
    "nng/src/core/url.c",
    "nng/src/nng.c",
    "nng/src/nng_legacy.c",
    "nng/src/platform/posix/posix_alloc.c",
    "nng/src/platform/posix/posix_atomic.c",
    "nng/src/platform/posix/posix_clock.c",
    "nng/src/platform/posix/posix_debug.c",
    "nng/src/platform/posix/posix_file.c",
    "nng/src/platform/posix/posix_ipcconn.c",
    "nng/src/platform/posix/posix_ipcdial.c",
    "nng/src/platform/posix/posix_ipclisten.c",
    "nng/src/platform/posix/posix_pipe.c",
    "nng/src/platform/posix/posix_pollq_epoll.c",
    "nng/src/platform/posix/posix_pollq_kqueue.c",
    "nng/src/platform/posix/posix_pollq_poll.c",
    "nng/src/platform/posix/posix_pollq_port.c",
    "nng/src/platform/posix/posix_rand_arc4random.c",
    "nng/src/platform/posix/posix_rand_getrandom.c",
    "nng/src/platform/posix/posix_rand_urandom.c",
    "nng/src/platform/posix/posix_resolv_gai.c",
    "nng/src/platform/posix/posix_sockaddr.c",
    "nng/src/platform/posix/posix_tcpconn.c",
    "nng/src/platform/posix/posix_tcpdial.c",
    "nng/src/platform/posix/posix_tcplisten.c",
    "nng/src/platform/posix/posix_thread.c",
    "nng/src/platform/posix/posix_udp.c",
    "nng/src/protocol/bus0/bus.c",
    "nng/src/protocol/pair0/pair.c",
    "nng/src/protocol/pair1/pair.c",
    "nng/src/protocol/pair1/pair1_poly.c",
    "nng/src/protocol/pipeline0/pull.c",
    "nng/src/protocol/pipeline0/push.c",
    "nng/src/protocol/pubsub0/pub.c",
    "nng/src/protocol/pubsub0/sub.c",
    "nng/src/protocol/pubsub0/xsub.c",
    "nng/src/protocol/reqrep0/rep.c",
    "nng/src/protocol/reqrep0/req.c",
    "nng/src/protocol/reqrep0/xrep.c",
    "nng/src/protocol/reqrep0/xreq.c",
    "nng/src/protocol/survey0/respond.c",
    "nng/src/protocol/survey0/survey.c",
    "nng/src/protocol/survey0/xrespond.c",
    "nng/src/protocol/survey0/xsurvey.c",
    "nng/src/supplemental/base64/base64.c",
    "nng/src/supplemental/http/http_chunk.c",
    "nng/src/supplemental/http/http_client.c",
    "nng/src/supplemental/http/http_conn.c",
    "nng/src/supplemental/http/http_msg.c",
    "nng/src/supplemental/http/http_public.c",
    "nng/src/supplemental/http/http_schemes.c",
    "nng/src/supplemental/http/http_server.c",
    "nng/src/supplemental/sha1/sha1.c",
    // "nng/src/supplemental/tls/mbedtls/tls.c",
    "nng/src/supplemental/tls/tls_common.c",
    "nng/src/supplemental/util/options.c",
    "nng/src/supplemental/util/platform.c",
    "nng/src/supplemental/websocket/stub.c",
    "nng/src/supplemental/websocket/websocket.c",
    "nng/src/transport/inproc/inproc.c",
    "nng/src/transport/ipc/ipc.c",
    "nng/src/transport/tcp/tcp.c",
    "nng/src/transport/tls/tls.c",
    "nng/src/transport/ws/websocket.c",
    // "nng/src/transport/zerotier/zerotier.c",
    // "nng/src/transport/zerotier/zthash.c",
};
