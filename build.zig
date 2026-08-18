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
            .{ .name = "msgpack", .module = msgpack_mod },
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

    const codegen_cmd = b.addSystemCommand(&.{ "pkl", "run", "codegen/src/gen.pkl", "--output-path" });
    codegen_cmd.stdio = .inherit;
    const codegen_dir = codegen_cmd.addOutputDirectoryArg("codegen-example");
    codegen_cmd.addFileArg(b.path("example/codegen/AppConfig.pkl"));
    const appconfig_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = codegen_dir.path(b, "appconfig/index.zig"),
        .imports = &.{
            .{ .name = "pkl", .module = pkl_mod },
        },
    });
    const codegen_example_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("example/codegen_example.zig"),
        .imports = &.{
            .{ .name = "pkl", .module = pkl_mod },
            .{ .name = "appconfig", .module = appconfig_mod },
        },
    });
    const codegen_example_exe = b.addExecutable(.{
        .name = "codegen-example",
        .root_module = codegen_example_mod,
    });
    //codegen_example_exe.step.dependOn(&codegen_cmd.step);
    const run_codegen_example_step = b.step("run-codegen-example", "Generate and run typed config example");
    const run_codegen_example_cmd = b.addRunArtifact(codegen_example_exe);
    run_codegen_example_step.dependOn(&run_codegen_example_cmd.step);

    // Integration uses a separate module graph whose build_options are forced
    // on, then tests all public layers instead of only the message codec.
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

    const integration_transport_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/transport/transport.zig"),
        .imports = &.{
            .{ .name = "message", .module = integration_message_mod },
            .{ .name = "msgpack", .module = msgpack_mod },
        },
    });

    const integration_pkl_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/pkl.zig"),
        .imports = &.{
            .{ .name = "message", .module = integration_message_mod },
            .{ .name = "transport", .module = integration_transport_mod },
            .{ .name = "msgpack", .module = msgpack_mod },
        },
    });
    const integration_message_test = b.addTest(.{ .root_module = integration_message_mod });
    const integration_message_cmd = b.addRunArtifact(integration_message_test);
    integration_step.dependOn(&integration_message_cmd.step);

    const integration_evaluator_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/integration_test.zig"),
        .imports = &.{
            .{ .name = "pkl", .module = integration_pkl_mod },
        },
    });
    const integration_evaluator_test = b.addTest(.{ .root_module = integration_evaluator_mod });
    const integration_evaluator_cmd = b.addRunArtifact(integration_evaluator_test);
    integration_step.dependOn(&integration_evaluator_cmd.step);

    const snippet_step = b.step("codegen-snippet-test", "Generate and compile codegen snippet fixtures");
    const snippet_output_dir = "codegen/snippet-tests/output";
    const snippet_clean_cmd = b.addSystemCommand(&.{ "rm", "-rf", "codegen/snippet-tests/output/github.com" });
    const snippet_codegen_cmd = b.addSystemCommand(&.{ "pkl", "run", "codegen/src/gen.pkl", "--output-path", snippet_output_dir });
    snippet_codegen_cmd.stdio = .inherit;
    snippet_codegen_cmd.step.dependOn(&snippet_clean_cmd.step);
    const snippet_inputs = [_][]const u8{
        "codegen/snippet-tests/input/Classes.pkl",
        "codegen/snippet-tests/input/CyclicModule.pkl",
        "codegen/snippet-tests/input/EmptyOpenModule.pkl",
        "codegen/snippet-tests/input/ExplicitName.pkl",
        "codegen/snippet-tests/input/ExtendAbstractClass.pkl",
        "codegen/snippet-tests/input/ExtendModule.pkl",
        "codegen/snippet-tests/input/ExtendOpenClass.pkl",
        "codegen/snippet-tests/input/HiddenProperties.pkl",
        "codegen/snippet-tests/input/ModuleType.pkl",
        "codegen/snippet-tests/input/ModuleUsingLib.pkl",
        "codegen/snippet-tests/input/NoMappingHidden.pkl",
        "codegen/snippet-tests/input/Override.pkl",
        "codegen/snippet-tests/input/Override2.pkl",
        "codegen/snippet-tests/input/PackageNameKeyword.pkl",
        "codegen/snippet-tests/input/Pairs.pkl",
        "codegen/snippet-tests/input/References.pkl",
        "codegen/snippet-tests/input/StructTags.pkl",
        "codegen/snippet-tests/input/UnionNameKeyword.pkl",
        "codegen/snippet-tests/input/Unions.pkl",
    };
    for (&snippet_inputs) |input| {
        snippet_codegen_cmd.addFileArg(b.path(input));
    }
    const snippet_packages = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/bugholder", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/bugholder/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/cyclicmodule", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/cyclicmodule/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/emptyopenmodule", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/emptyopenmodule/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/explicitname", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/explicitname/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/extendabstractclass", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/extendabstractclass/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/extendmodule", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/extendmodule/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/extendopenclass", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/extendopenclass/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/fieldannotations", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/fieldannotations/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/hiddenproperties", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/hiddenproperties/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/moduletype", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/moduletype/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/moduleusinglib", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/moduleusinglib/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/nomappinghidden", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/nomappinghidden/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/override", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/override/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/override2", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/override2/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/import", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/import/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/pairs", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/pairs/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/references", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/references/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib2", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib2/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib3", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib3/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib4", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib4/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/openmodule", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/openmodule/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/union", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/union/index.zig" },
        .{ .name = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/unionnamekeyword", .path = "github.com/burakssen/pkl-zig/codegen/snippet-tests/output/unionnamekeyword/index.zig" },
    };
    var snippet_modules: [snippet_packages.len]*std.Build.Module = undefined;
    for (&snippet_packages, 0..) |pkg, i| {
        snippet_modules[i] = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(b.fmt("{s}/{s}", .{ snippet_output_dir, pkg.path })),
            .imports = &.{.{ .name = "pkl", .module = pkl_mod }},
        });
    }
    for (snippet_modules) |mod| {
        for (&snippet_packages, 0..) |pkg, i| {
            mod.addImport(pkg.name, snippet_modules[i]);
        }
    }
    const snippet_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/snippet-tests/test.zig"),
        .imports = &.{.{ .name = "pkl", .module = pkl_mod }},
    });
    for (&snippet_packages, 0..) |pkg, i| {
        snippet_test_mod.addImport(pkg.name, snippet_modules[i]);
    }
    const snippet_test = b.addTest(.{ .root_module = snippet_test_mod });
    snippet_test.step.dependOn(&snippet_codegen_cmd.step);
    const snippet_test_cmd = b.addRunArtifact(snippet_test);
    snippet_step.dependOn(&snippet_test_cmd.step);
    const snippet_error_cmd = b.addSystemCommand(&.{
        "sh",
        "codegen/snippet-tests/check-errors.sh",
        "codegen/src/gen.pkl",
    });
    _ = snippet_error_cmd.addOutputDirectoryArg("snippet-codegen-errors");
    snippet_step.dependOn(&snippet_error_cmd.step);
}
