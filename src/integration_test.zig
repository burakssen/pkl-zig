const std = @import("std");
const pkl = @import("pkl");
const integration_build_options = @import("integration_build_options");

test "evaluator decodes pkl-binary end to end" {
    const allocator = std.testing.allocator;

    var evaluator = try pkl.Evaluator.init(std.testing.io, allocator, .{});
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

test "Pkl 0.32 Reference decodes end to end" {
    const allocator = std.testing.allocator;

    const path = try fixturePath(allocator, "reference.pkl");
    defer allocator.free(path);

    var evaluator = try pkl.Evaluator.init(std.testing.io, allocator, .{});
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

    var evaluator = try project.newEvaluator(std.testing.io, allocator, .{});
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

    var evaluator = try pkl.Evaluator.init(std.testing.io, allocator, .{
        .allowed_resources = &.{ "customres:", "pkl:" },
        .resource_readers = &.{resource_reader},
    });
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

    var evaluator = try pkl.Evaluator.init(std.testing.io, allocator, .{
        .allowed_modules = &.{ "custommod:", "pkl:", "repl:" },
        .module_readers = &.{module_reader},
    });
    defer evaluator.deinit();

    const raw = try evaluator.evaluateExpressionRaw("custommod:config.pkl", "name");
    defer allocator.free(raw);

    var name = try pkl.decode([]const u8, allocator, raw);
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

    var evaluator = try pkl.Evaluator.init(std.testing.io, allocator, .{
        .allowed_modules = &.{ "globmod:", "pkl:", "repl:" },
        .module_readers = &.{module_reader},
    });
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

    var evaluator = try pkl.Evaluator.init(std.testing.io, allocator, .{
        .allowed_resources = &.{ "failres:", "pkl:" },
        .resource_readers = &.{resource_reader},
    });
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

    var eval1 = try manager.newEvaluator(.{});
    defer eval1.deinit();

    var props = std.StringHashMap([]const u8).init(allocator);
    defer props.deinit();
    try props.put("greeting", "Hello from eval2");

    var eval2 = try manager.newEvaluator(.{
        .properties = props,
    });
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
    var eval3 = try manager.newEvaluator(.{});
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

    var evaluator = try manager.newProjectEvaluator(&project, .{});
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
