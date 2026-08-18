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
