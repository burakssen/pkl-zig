const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const msgpack_dep = b.dependency("zig_msgpack", .{
        .target = target,
        .optimize = optimize,
    });

    const msgpack_mod = msgpack_dep.module("msgpack");

    const message_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/message/message.zig"),
        .imports = &.{
            .{ .name = "msgpack", .module = msgpack_mod },
        },
    });

    message_mod.addImport("message", message_mod);

    const transport_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/transport/transport.zig"),
        .imports = &.{
            .{ .name = "message", .module = message_mod },
        },
    });

    const test_step = b.step("test", "Run pkl-zig tests");

    inline for (&.{ message_mod, transport_mod }) |mod| {
        const mod_test = b.addTest(.{ .root_module = mod });
        const mod_cmd = b.addRunArtifact(mod_test);
        test_step.dependOn(&mod_cmd.step);
    }
}
