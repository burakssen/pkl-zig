const std = @import("std");
const pkl = @import("pkl");

test "evaluator decodes pkl-binary end to end" {
    const allocator = std.testing.allocator;

    var evaluator = try pkl.Evaluator.init(std.testing.io, allocator, .{});
    defer evaluator.deinit();

    const raw = try evaluator.evaluateExpressionRaw("pkl:base", "42");
    defer allocator.free(raw);

    const decoded = try pkl.decode(i64, allocator, raw);
    try std.testing.expectEqual(@as(i64, 42), decoded);
}
