const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const msgpack_dep = b.dependency("zig_msgpack", .{
        .target = target,
        .optimize = optimize,
    });

    const msgpack_mod = msgpack_dep.module("msgpack");

    const integration_tests = b.option(bool, "integration", "Run tests that spawn pkl server") orelse false;

    const test_options = b.addOptions();
    test_options.addOption(bool, "integration_tests", integration_tests);

    const message_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/message/message.zig"),
        .imports = &.{
            .{ .name = "msgpack", .module = msgpack_mod },
        },
    });

    message_mod.addImport("message", message_mod);
    message_mod.addOptions("build_options", test_options);

    const transport_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/transport/transport.zig"),
        .imports = &.{
            .{ .name = "message", .module = message_mod },
            .{ .name = "msgpack", .module = msgpack_mod },
        },
    });

    const pkl_mod = b.addModule("pkl", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/pkl.zig"),
        .imports = &.{
            .{ .name = "message", .module = message_mod },
            .{ .name = "transport", .module = transport_mod },
        },
    });

    const test_step = b.step("test", "Run pkl-zig tests");

    inline for (&.{ message_mod, transport_mod, pkl_mod }) |mod| {
        const mod_test = b.addTest(.{ .root_module = mod });
        const mod_cmd = b.addRunArtifact(mod_test);
        test_step.dependOn(&mod_cmd.step);
    }

    const example_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("example/example.zig"),
        .imports = &.{
            .{ .name = "pkl", .module = pkl_mod },
        },
    });
    const example_exe = b.addExecutable(.{
        .name = "example",
        .root_module = example_mod,
    });

    const run_step = b.step("run", "Run example");
    const run_cmd = b.addRunArtifact(example_exe);
    run_step.dependOn(&run_cmd.step);

    const integration_step = b.step("integration-test", "Run tests that spawn pkl server");
    const integration_options = b.addOptions();
    integration_options.addOption(bool, "integration_tests", true);

    const integration_message_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/message/message.zig"),
        .imports = &.{
            .{ .name = "msgpack", .module = msgpack_mod },
        },
    });
    integration_message_mod.addImport("message", integration_message_mod);
    integration_message_mod.addOptions("build_options", integration_options);

    const integration_test = b.addTest(.{ .root_module = integration_message_mod });
    const integration_cmd = b.addRunArtifact(integration_test);
    integration_step.dependOn(&integration_cmd.step);
}
