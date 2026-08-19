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

    // reusable module factory avoids duplicate module definitions
    const modules = createModules(b, target, optimize, msgpack_mod, integration_tests);
    _ = b.addModule("pkl", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/pkl.zig"),
        .imports = &.{
            .{ .name = "message", .module = modules.message },
            .{ .name = "transport", .module = modules.transport },
            .{ .name = "msgpack", .module = msgpack_mod },
        },
    });

    const test_step = b.step("test", "Run pkl-zig tests");
    inline for (&.{ modules.message, modules.transport, modules.pkl }) |mod| {
        const mod_test = b.addTest(.{ .root_module = mod });
        const mod_cmd = b.addRunArtifact(mod_test);
        test_step.dependOn(&mod_cmd.step);
    }

    const example_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("example/example.zig"),
        .imports = &.{
            .{ .name = "pkl", .module = modules.pkl },
        },
    });
    const example_exe = b.addExecutable(.{
        .name = "example",
        .root_module = example_mod,
    });

    const run_step = b.step("run", "Run example");
    const run_cmd = b.addRunArtifact(example_exe);
    run_step.dependOn(&run_cmd.step);

    const appconfig_mod = addCodegen(b, null, .{
        .target = target,
        .optimize = optimize,
        .package_name = "appconfig",
        .pkl_files = &.{b.path("example/codegen/AppConfig.pkl")},
        .output_dir = "codegen-example",
    });
    const codegen_example_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("example/codegen_example.zig"),
        .imports = &.{
            .{ .name = "pkl", .module = modules.pkl },
            .{ .name = "appconfig", .module = appconfig_mod },
        },
    });
    const codegen_example_exe = b.addExecutable(.{
        .name = "codegen-example",
        .root_module = codegen_example_mod,
    });
    const run_codegen_example_step = b.step("run-codegen-example", "Generate and run typed config example");
    const run_codegen_example_cmd = b.addRunArtifact(codegen_example_exe);
    run_codegen_example_step.dependOn(&run_codegen_example_cmd.step);

    // Integration tests
    const integration_step = b.step("integration-test", "Run tests that spawn pkl server");
    const integration_modules = createModules(b, target, optimize, msgpack_mod, true);

    const integration_fixture_options = b.addOptions();
    integration_fixture_options.addOption(
        []const u8,
        "integration_fixture_root",
        b.pathFromRoot("src/integration-fixtures"),
    );

    const integration_message_test = b.addTest(.{ .root_module = integration_modules.message });
    const integration_message_cmd = b.addRunArtifact(integration_message_test);
    integration_step.dependOn(&integration_message_cmd.step);

    const integration_evaluator_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/integration_test.zig"),
        .imports = &.{
            .{ .name = "pkl", .module = integration_modules.pkl },
        },
    });
    integration_evaluator_mod.addOptions(
        "integration_build_options",
        integration_fixture_options,
    );
    const integration_evaluator_test = b.addTest(.{ .root_module = integration_evaluator_mod });
    const integration_evaluator_cmd = b.addRunArtifact(integration_evaluator_test);
    integration_step.dependOn(&integration_evaluator_cmd.step);

    // Codegen snippet tests
    const snippet_step = b.step("codegen-snippet-test", "Generate and compile codegen snippet fixtures");
    const snippet_output_dir = "codegen/snippet-tests/output";
    const snippet_codegen_cmd = b.addSystemCommand(&.{ "pkl", "run", "codegen/src/gen.pkl", "--output-path", snippet_output_dir });
    snippet_codegen_cmd.stdio = .inherit;
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
            .imports = &.{.{ .name = "pkl", .module = modules.pkl }},
        });
    }
    for (snippet_modules) |mod| {
        for (&snippet_packages, 0..) |pkg, i| {
            mod.addImport(pkg.name, snippet_modules[i]);
        }
    }
    const snippet_fixture_options = b.addOptions();
    snippet_fixture_options.addOption(
        []const u8,
        "runtime_fixture_root",
        b.pathFromRoot("codegen/snippet-tests/runtime"),
    );
    const snippet_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/snippet-tests/test.zig"),
        .imports = &.{.{ .name = "pkl", .module = modules.pkl }},
    });
    snippet_test_mod.addOptions("snippet_build_options", snippet_fixture_options);
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

fn createModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    msgpack_mod: *std.Build.Module,
    integration_tests: bool,
) struct {
    message: *std.Build.Module,
    transport: *std.Build.Module,
    pkl: *std.Build.Module,
} {
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

    const pkl_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/pkl.zig"),
        .imports = &.{
            .{ .name = "message", .module = message_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "msgpack", .module = msgpack_mod },
        },
    });

    return .{
        .message = message_mod,
        .transport = transport_mod,
        .pkl = pkl_mod,
    };
}

pub const CodegenOptions = struct {
    /// Optional single path to .pkl file or directory
    pkl_file: ?std.Build.LazyPath = null,
    /// Or multiple .pkl files
    pkl_files: []const std.Build.LazyPath = &.{},

    /// Target module package name (e.g. "appconfig"), used to locate <output_dir>/<package_name>/index.zig
    package_name: []const u8,

    /// Optional root source file relative to output directory (defaults to "<package_name>/index.zig")
    root_file: ?[]const u8 = null,

    /// Base path for relative package structure passed to --base-path
    base_path: ?[]const u8 = null,

    /// Output directory name in zig-cache (defaults to "<package_name>-codegen")
    output_dir: ?[]const u8 = null,

    /// Target platform for the generated module
    target: ?std.Build.ResolvedTarget = null,

    /// Optimization mode for the generated module
    optimize: ?std.builtin.OptimizeMode = null,

    /// Optional extra CLI arguments to pass to `pkl run gen.pkl`
    extra_args: []const []const u8 = &.{},
};

// One simple system command calling pkl run codegen/src/gen.pkl, returning a ready-to-import *std.Build.Module.
pub fn addCodegen(
    b: *std.Build,
    pkl_dep: ?*std.Build.Dependency,
    options: CodegenOptions,
) *std.Build.Module {
    const gen_script = if (pkl_dep) |dep| dep.path("codegen/src/gen.pkl") else b.path("codegen/src/gen.pkl");
    const codegen_cmd = b.addSystemCommand(&.{ "pkl", "run" });
    codegen_cmd.addFileArg(gen_script);
    codegen_cmd.addArg("--output-path");
    const out_dir_name = options.output_dir orelse b.fmt("{s}-codegen", .{options.package_name});
    const codegen_dir = codegen_cmd.addOutputDirectoryArg(out_dir_name);
    if (options.base_path) |bp| {
        codegen_cmd.addArgs(&.{ "--base-path", bp });
    }
    if (options.extra_args.len > 0) {
        codegen_cmd.addArgs(options.extra_args);
    }
    if (options.pkl_file) |f| codegen_cmd.addFileArg(f);
    for (options.pkl_files) |f| codegen_cmd.addFileArg(f);
    codegen_cmd.stdio = .inherit;

    const root_subpath = options.root_file orelse b.fmt("{s}/index.zig", .{options.package_name});
    const root_source_file = codegen_dir.path(b, root_subpath);

    const pkl_mod = if (pkl_dep) |dep|
        dep.module("pkl")
    else
        b.modules.get("pkl") orelse unreachable;

    return b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .root_source_file = root_source_file,
        .imports = &.{
            .{ .name = "pkl", .module = pkl_mod },
        },
    });
}
