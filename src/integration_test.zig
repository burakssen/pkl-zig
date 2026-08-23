const std = @import("std");
const pkl = @import("pkl");
const integration_build_options = @import("integration_build_options");

/// Unwraps a creation result, failing the test with the server's diagnostic
/// when Pkl rejected evaluator creation.
fn expectInit(result: pkl.Evaluator.InitResult) !pkl.Evaluator {
    return switch (result) {
        .evaluator => |evaluator| evaluator,
        .failed => |failed| {
            defer failed.deinit(std.testing.allocator);
            std.debug.print("evaluator creation failed: {s}\n", .{failed.diagnostic});
            return error.CreateEvaluatorFailed;
        },
    };
}

test "evaluator decodes pkl-binary end to end" {
    const allocator = std.testing.allocator;

    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, .{}));
    defer evaluator.deinit();

    const raw = try evaluator.evaluateExpressionRaw("pkl:base", "42");
    defer allocator.free(raw);

    const decoded = try pkl.decode(i64, allocator, raw);
    try std.testing.expectEqual(@as(i64, 42), decoded);
}

fn fixturePath(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    return std.fs.path.join(
        allocator,
        &.{ integration_build_options.integration_fixture_root, relative },
    );
}

test "ModuleSource evaluates in-memory Pkl into typed Zig values" {
    const allocator = std.testing.allocator;
    const Config = struct {
        name: []const u8,
        answer: i64,
    };

    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, .{}));
    defer evaluator.deinit();

    var config = try evaluator.evaluateModule(Config, pkl.ModuleSource.fromText(
        \\name = "pkl-zig"
        \\answer = 40 + 2
    ));
    defer pkl.deinit(Config, allocator, &config);

    try std.testing.expectEqualStrings("pkl-zig", config.name);
    try std.testing.expectEqual(@as(i64, 42), config.answer);
}

test "standard output helpers evaluate text bytes value and files" {
    const allocator = std.testing.allocator;
    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, .{}));
    defer evaluator.deinit();

    var text = try evaluator.evaluateOutputText(pkl.ModuleSource.fromText(
        \\output {
        \\  text = "hello from pkl"
        \\}
    ));
    defer pkl.deinit([]const u8, allocator, &text);
    try std.testing.expectEqualStrings("hello from pkl", text);

    var bytes = try evaluator.evaluateOutputBytes(pkl.ModuleSource.fromText(
        \\output {
        \\  bytes = Bytes(1, 2, 3, 255)
        \\}
    ));
    defer pkl.deinit([]const u8, allocator, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, bytes);

    const number = try evaluator.evaluateOutputValue(
        i64,
        pkl.ModuleSource.fromText(
            \\output {
            \\  value = 6 * 7
            \\}
        ),
    );
    try std.testing.expectEqual(@as(i64, 42), number);

    var files = try evaluator.evaluateOutputFiles(pkl.ModuleSource.fromText(
        \\output {
        \\  files {
        \\    ["hello.txt"] {
        \\      text = "hello file"
        \\    }
        \\  }
        \\}
    ));
    defer files.deinit();
    try std.testing.expectEqualStrings("hello file", files.files.get("hello.txt").?);

    var binary_files = try evaluator.evaluateOutputFilesBytes(pkl.ModuleSource.fromText(
        \\output {
        \\  files {
        \\    ["data.bin"] {
        \\      bytes = Bytes(4, 5, 6)
        \\    }
        \\  }
        \\}
    ));
    defer binary_files.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, binary_files.files.get("data.bin").?);
}

test "preconfigured evaluator starts with binding defaults" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    var evaluator = try expectInit(try pkl.Evaluator.initPreconfigured(std.testing.io, allocator, &environ));
    defer evaluator.deinit();

    const answer = try evaluator.evaluateExpression(
        i64,
        pkl.ModuleSource.fromUri("pkl:base"),
        "21 * 2",
    );
    try std.testing.expectEqual(@as(i64, 42), answer);
}

test "evaluator creation failure carries the Pkl diagnostic" {
    const allocator = std.testing.allocator;

    var result = try pkl.Evaluator.init(std.testing.io, allocator, .{
        .allowed_modules = &.{"["},
    });
    try std.testing.expect(result == .failed);
    defer result.failed.deinit(allocator);
    try std.testing.expect(result.failed.diagnostic.len != 0);
}

test "Pkl 0.32 Reference decodes end to end" {
    const allocator = std.testing.allocator;

    const path = try fixturePath(allocator, "reference.pkl");
    defer allocator.free(path);

    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, .{}));
    defer evaluator.deinit();

    const uri = try pkl.Evaluator.fileUriFromPath(std.testing.io, allocator, path);
    defer allocator.free(uri);

    const raw = try evaluator.evaluateExpressionRaw(uri, "nested");
    defer allocator.free(raw);

    var reference = try pkl.decode(pkl.Reference, allocator, raw);
    defer pkl.deinit(pkl.Reference, allocator, &reference);

    try std.testing.expect(reference.domain.* == .object);
    try std.testing.expect(reference.data.* == .string);
    try std.testing.expectEqualStrings("thing", reference.data.string);
    try std.testing.expectEqual(@as(usize, 1), reference.path.len);

    const access = switch (reference.path[0]) {
        .object => |object| object,
        else => return error.ExpectedReferenceAccess,
    };
    const property = access.properties.get("property") orelse return error.MissingReferenceProperty;
    try std.testing.expect(property == .string);
    try std.testing.expectEqualStrings("name", property.string);
}

test "PklProject resolved evaluator settings apply end to end" {
    const allocator = std.testing.allocator;

    const project_dir = try fixturePath(allocator, "project");
    defer allocator.free(project_dir);

    var project = try pkl.Project.load(std.testing.io, allocator, project_dir, .{});
    defer project.deinit(allocator);

    const module_paths = project.resolved_evaluator_settings.module_path orelse
        return error.MissingResolvedModulePath;
    try std.testing.expectEqual(@as(usize, 1), module_paths.len);
    try std.testing.expect(std.fs.path.isAbsolute(module_paths[0]));
    try std.testing.expectEqualStrings("modules", std.fs.path.basename(module_paths[0]));

    var evaluator = try expectInit(try project.newEvaluator(std.testing.io, allocator, .{}));
    defer evaluator.deinit();

    const module_path = try std.fs.path.join(allocator, &.{ project_dir, "main.pkl" });
    defer allocator.free(module_path);
    const module_uri = try pkl.Evaluator.fileUriFromPath(std.testing.io, allocator, module_path);
    defer allocator.free(module_uri);

    const raw = try evaluator.evaluateExpressionRaw(module_uri, "result");
    defer allocator.free(raw);

    var result = try pkl.decode([]const u8, allocator, raw);
    defer pkl.deinit([]const u8, allocator, &result);
    try std.testing.expectEqualStrings("from-module-path:from-project", result);
}

fn testResourceRead(_: ?*anyopaque, _: std.mem.Allocator, uri: []const u8) anyerror![]const u8 {
    if (std.mem.eql(u8, uri, "customres:hello.txt")) {
        return "Hello from in-process resource reader!";
    }
    return error.FileNotFound;
}

test "in-process custom ResourceReader reads resource" {
    const allocator = std.testing.allocator;

    const resource_reader = pkl.ResourceReader{
        .scheme = "customres",
        .read = testResourceRead,
    };

    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, .{
        .allowed_resources = &.{ "customres:", "pkl:" },
        .resource_readers = &.{resource_reader},
    }));
    defer evaluator.deinit();

    const raw = try evaluator.evaluateExpressionRaw("pkl:base", "read(\"customres:hello.txt\").text");
    defer allocator.free(raw);

    var text = try pkl.decode([]const u8, allocator, raw);
    defer pkl.deinit([]const u8, allocator, &text);

    try std.testing.expectEqualStrings("Hello from in-process resource reader!", text);
}

fn testModuleRead(_: ?*anyopaque, _: std.mem.Allocator, uri: []const u8) anyerror![]const u8 {
    if (std.mem.eql(u8, uri, "custommod:config.pkl")) {
        return "name = \"pkl-zig\"\nversion = 1";
    }
    return error.FileNotFound;
}

test "in-process custom ModuleReader evaluates module" {
    const allocator = std.testing.allocator;

    const module_reader = pkl.ModuleReader{
        .scheme = "custommod",
        .read = testModuleRead,
    };

    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, .{
        .allowed_modules = &.{ "custommod:", "pkl:", "repl:" },
        .module_readers = &.{module_reader},
    }));
    defer evaluator.deinit();

    const raw = try evaluator.evaluateExpressionRaw("custommod:config.pkl", "name");
    defer allocator.free(raw);

    var name = try pkl.decode([]const u8, allocator, raw);
    defer pkl.deinit([]const u8, allocator, &name);

    try std.testing.expectEqualStrings("pkl-zig", name);
}

test "OptionsBuilder automatically permits in-process reader schemes" {
    const allocator = std.testing.allocator;
    const module_reader = pkl.ModuleReader{
        .scheme = "custommod",
        .read = testModuleRead,
    };

    var options = try pkl.EvaluatorOptionsBuilder.init(allocator, .{});
    defer options.deinit();
    try options.addModuleReader(module_reader);

    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, options.build()));
    defer evaluator.deinit();

    var name = try evaluator.evaluateExpression(
        []const u8,
        pkl.ModuleSource.fromUri("custommod:config.pkl"),
        "name",
    );
    defer pkl.deinit([]const u8, allocator, &name);
    try std.testing.expectEqualStrings("pkl-zig", name);
}

fn testGlobModuleRead(_: ?*anyopaque, _: std.mem.Allocator, uri: []const u8) anyerror![]const u8 {
    if (std.mem.eql(u8, uri, "globmod:/a.pkl")) {
        return "val = 10";
    } else if (std.mem.eql(u8, uri, "globmod:/b.pkl")) {
        return "val = 20";
    }
    return error.FileNotFound;
}

fn testGlobModuleList(_: ?*anyopaque, _: std.mem.Allocator, uri: []const u8) anyerror![]const pkl.PathElement {
    if (std.mem.eql(u8, uri, "globmod:/")) {
        const elements = [_]pkl.PathElement{
            .{ .name = "a.pkl", .is_directory = false },
            .{ .name = "b.pkl", .is_directory = false },
        };
        return &elements;
    }
    return error.FileNotFound;
}

test "in-process custom ModuleReader globbing" {
    const allocator = std.testing.allocator;

    const module_reader = pkl.ModuleReader{
        .scheme = "globmod",
        .has_hierarchical_uris = true,
        .is_globbable = true,
        .read = testGlobModuleRead,
        .list_elements = testGlobModuleList,
    };

    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, .{
        .allowed_modules = &.{ "globmod:", "pkl:", "repl:" },
        .module_readers = &.{module_reader},
    }));
    defer evaluator.deinit();

    const raw = try evaluator.evaluateExpressionRaw("pkl:base", "(import*(\"globmod:/*.pkl\")).length");
    defer allocator.free(raw);

    const count = try pkl.decode(i64, allocator, raw);
    try std.testing.expectEqual(@as(i64, 2), count);
}

fn testFailingRead(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    return error.ResourceNotFound;
}

test "in-process custom ResourceReader propagates read error" {
    const allocator = std.testing.allocator;

    const resource_reader = pkl.ResourceReader{
        .scheme = "failres",
        .read = testFailingRead,
    };

    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, .{
        .allowed_resources = &.{ "failres:", "pkl:" },
        .resource_readers = &.{resource_reader},
    }));
    defer evaluator.deinit();

    const result = evaluator.evaluateExpressionRaw("pkl:base", "read(\"failres:missing.txt\").text");
    try std.testing.expectError(error.EvaluateFailed, result);
    try std.testing.expect(evaluator.lastError() != null);
    try std.testing.expect(std.mem.indexOf(u8, evaluator.lastError().?, "ResourceNotFound") != null);
}

test "EvaluatorManager multiplexes multiple evaluators on a single process" {
    const allocator = std.testing.allocator;

    var manager = try pkl.EvaluatorManager.init(std.testing.io, allocator, .{});
    defer manager.deinit();

    var eval1 = try expectInit(try manager.newEvaluator(.{}));
    defer eval1.deinit();

    var props = std.StringHashMap([]const u8).init(allocator);
    defer props.deinit();
    try props.put("greeting", "Hello from eval2");

    var eval2 = try expectInit(try manager.newEvaluator(.{
        .properties = props,
    }));
    defer eval2.deinit();

    try std.testing.expect(eval1.evaluator_id != eval2.evaluator_id);

    // Evaluate on eval1
    {
        const raw = try eval1.evaluateExpressionRaw("pkl:base", "10 + 20");
        defer allocator.free(raw);
        const res = try pkl.decode(i64, allocator, raw);
        try std.testing.expectEqual(@as(i64, 30), res);
    }

    // Evaluate on eval2 using its custom property
    {
        const raw = try eval2.evaluateExpressionRaw("pkl:base", "read(\"prop:greeting\")");
        defer allocator.free(raw);
        var text = try pkl.decode([]const u8, allocator, raw);
        defer pkl.deinit([]const u8, allocator, &text);
        try std.testing.expectEqualStrings("Hello from eval2", text);
    }

    // Close eval1 explicitly
    try eval1.close();

    // eval2 still works after eval1 is closed
    {
        const raw = try eval2.evaluateExpressionRaw("pkl:base", "5 * 5");
        defer allocator.free(raw);
        const res = try pkl.decode(i64, allocator, raw);
        try std.testing.expectEqual(@as(i64, 25), res);
    }

    // Spawn a 3rd evaluator on the same manager
    var eval3 = try expectInit(try manager.newEvaluator(.{}));
    defer eval3.deinit();

    {
        const raw = try eval3.evaluateExpressionRaw("pkl:base", "100 - 1");
        defer allocator.free(raw);
        const res = try pkl.decode(i64, allocator, raw);
        try std.testing.expectEqual(@as(i64, 99), res);
    }
}

test "EvaluatorManager evaluates PklProject" {
    const allocator = std.testing.allocator;

    const project_dir = try fixturePath(allocator, "project");
    defer allocator.free(project_dir);

    var project = try pkl.Project.load(std.testing.io, allocator, project_dir, .{});
    defer project.deinit(allocator);

    var manager = try pkl.EvaluatorManager.init(std.testing.io, allocator, .{});
    defer manager.deinit();

    var evaluator = try expectInit(try manager.newProjectEvaluator(&project, .{}));
    defer evaluator.deinit();

    const module_path = try std.fs.path.join(allocator, &.{ project_dir, "main.pkl" });
    defer allocator.free(module_path);
    const module_uri = try pkl.Evaluator.fileUriFromPath(std.testing.io, allocator, module_path);
    defer allocator.free(module_uri);

    const raw = try evaluator.evaluateExpressionRaw(module_uri, "result");
    defer allocator.free(raw);

    var result = try pkl.decode([]const u8, allocator, raw);
    defer pkl.deinit([]const u8, allocator, &result);
    try std.testing.expectEqualStrings("from-module-path:from-project", result);
}

fn allocatingResourceRead(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    uri: []const u8,
) anyerror![]const u8 {
    if (!std.mem.eql(u8, uri, "ownedres:data.txt")) return error.FileNotFound;
    return allocator.dupe(u8, "allocated by reader");
}

test "in-process reader allocations are request scoped" {
    const allocator = std.testing.allocator;
    const reader = pkl.ResourceReader{
        .scheme = "ownedres",
        .read = allocatingResourceRead,
    };

    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, .{
        .allowed_resources = &.{ "ownedres:", "pkl:" },
        .resource_readers = &.{reader},
    }));
    defer evaluator.deinit();

    const raw = try evaluator.evaluateExpressionRaw(
        "pkl:base",
        "read(\"ownedres:data.txt\").text",
    );
    defer allocator.free(raw);
    var text = try pkl.decode([]const u8, allocator, raw);
    defer pkl.deinit([]const u8, allocator, &text);
    try std.testing.expectEqualStrings("allocated by reader", text);
}

test "manager close invalidates retained evaluator safely" {
    const allocator = std.testing.allocator;
    var manager = try pkl.EvaluatorManager.init(std.testing.io, allocator, .{});
    defer manager.deinit();

    var evaluator = try expectInit(try manager.newEvaluator(.{}));
    defer evaluator.deinit();

    manager.close();
    try std.testing.expectError(
        error.ManagerClosed,
        evaluator.evaluateExpressionRaw("pkl:base", "1 + 1"),
    );
    try std.testing.expectError(error.ManagerClosed, manager.newEvaluator(.{}));
}

const LogCapture = struct {
    seen: bool = false,
    level: i32 = -1,
};

fn captureLog(
    context: ?*anyopaque,
    level: i32,
    _: []const u8,
    _: []const u8,
) void {
    const capture: *LogCapture = @ptrCast(@alignCast(context.?));
    capture.seen = true;
    capture.level = level;
}

test "evaluator logger receives trace messages" {
    const allocator = std.testing.allocator;
    var capture = LogCapture{};
    var evaluator = try expectInit(try pkl.Evaluator.init(std.testing.io, allocator, .{
        .logger = .{
            .context = &capture,
            .write = captureLog,
        },
    }));
    defer evaluator.deinit();

    const raw = try evaluator.evaluateExpressionRaw("pkl:base", "trace(40 + 2)");
    defer allocator.free(raw);
    const result = try pkl.decode(i64, allocator, raw);

    try std.testing.expectEqual(@as(i64, 42), result);
    try std.testing.expect(capture.seen);
    try std.testing.expectEqual(@as(i32, 0), capture.level);
}

const AsyncEvaluation = union(enum) {
    value: i64,
    failure: anyerror,
};

fn evaluateAsync(
    evaluator: *pkl.Evaluator,
    expression: []const u8,
    results: *std.Io.Queue(AsyncEvaluation),
) void {
    const allocator = std.testing.allocator;
    const raw = evaluator.evaluateExpressionRaw("pkl:base", expression) catch |err| {
        results.putOne(std.testing.io, .{ .failure = err }) catch {};
        return;
    };
    defer allocator.free(raw);

    const decoded = pkl.decode(i64, allocator, raw) catch |err| {
        results.putOne(std.testing.io, .{ .failure = err }) catch {};
        return;
    };
    results.putOne(std.testing.io, .{ .value = decoded }) catch {};
}

fn expectAsyncValue(results: *std.Io.Queue(AsyncEvaluation), expected: i64) !void {
    const result = try results.getOne(std.testing.io);
    switch (result) {
        .value => |number| try std.testing.expectEqual(expected, number),
        .failure => |err| return err,
    }
}

test "manager routes concurrent evaluator responses by request id" {
    const allocator = std.testing.allocator;
    var manager = try pkl.EvaluatorManager.init(std.testing.io, allocator, .{});
    defer manager.deinit();

    var first = try expectInit(try manager.newEvaluator(.{}));
    defer first.deinit();
    var second = try expectInit(try manager.newEvaluator(.{}));
    defer second.deinit();

    var first_buffer: [1]AsyncEvaluation = undefined;
    var first_results: std.Io.Queue(AsyncEvaluation) = .init(&first_buffer);
    var second_buffer: [1]AsyncEvaluation = undefined;
    var second_results: std.Io.Queue(AsyncEvaluation) = .init(&second_buffer);
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);

    group.async(std.testing.io, evaluateAsync, .{ &first, "20 + 22", &first_results });
    group.async(std.testing.io, evaluateAsync, .{ &second, "9 * 11", &second_results });

    try expectAsyncValue(&first_results, 42);
    try expectAsyncValue(&second_results, 99);
}

const BlockingModuleState = struct {
    entered: *std.Io.Queue(bool),
    release: *std.Io.Queue(bool),
};

fn blockingModuleRead(
    context: ?*anyopaque,
    _: std.mem.Allocator,
    uri: []const u8,
) anyerror![]const u8 {
    if (!std.mem.eql(u8, uri, "blocking:config.pkl")) return error.FileNotFound;
    const state: *BlockingModuleState = @ptrCast(@alignCast(context.?));
    try state.entered.putOne(std.testing.io, true);
    _ = try state.release.getOne(std.testing.io);
    return "answer = 42";
}

fn evaluateBlockingModule(
    evaluator: *pkl.Evaluator,
    results: *std.Io.Queue(AsyncEvaluation),
) void {
    const result = evaluator.evaluateExpression(
        i64,
        pkl.ModuleSource.fromUri("blocking:config.pkl"),
        "answer",
    ) catch |err| {
        results.putOne(std.testing.io, .{ .failure = err }) catch {};
        return;
    };
    results.putOne(std.testing.io, .{ .value = result }) catch {};
}

test "manager close lets an already-started reader request drain" {
    const allocator = std.testing.allocator;
    var entered_buffer: [1]bool = undefined;
    var entered: std.Io.Queue(bool) = .init(&entered_buffer);
    var release_buffer: [1]bool = undefined;
    var release: std.Io.Queue(bool) = .init(&release_buffer);
    var result_buffer: [1]AsyncEvaluation = undefined;
    var results: std.Io.Queue(AsyncEvaluation) = .init(&result_buffer);
    var state = BlockingModuleState{ .entered = &entered, .release = &release };

    var manager = try pkl.EvaluatorManager.init(std.testing.io, allocator, .{});
    defer manager.deinit();
    var evaluator = try expectInit(try manager.newEvaluator(.{
        .allowed_modules = &.{ "blocking:", "pkl:", "repl:" },
        .module_readers = &.{.{
            .scheme = "blocking",
            .read = blockingModuleRead,
            .context = &state,
        }},
    }));
    defer evaluator.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    group.async(std.testing.io, evaluateBlockingModule, .{ &evaluator, &results });

    try std.testing.expect(try entered.getOne(std.testing.io));
    manager.close();
    try release.putOne(std.testing.io, true);
    try expectAsyncValue(&results, 42);

    try std.testing.expectError(
        error.ManagerClosed,
        evaluator.evaluateExpressionRaw("pkl:base", "1 + 1"),
    );
}
