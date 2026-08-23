// Code generated from Pkl module `MyModule`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");

pub const MyModule = struct {
    foo: []const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pkl.deinit(@This(), allocator, self);
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "foo", .pkl = "foo" },
    };

    pub fn loadFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !@This() {
        var evaluator = switch (try pkl.Evaluator.init(io, allocator, .{})) {
            .evaluator => |evaluator| evaluator,
            .failed => return error.CreateEvaluatorFailed,
        };
        defer evaluator.deinit();
        return evaluator.loadFromPath(@This(), path);
    }

    pub fn loadFromPathWithEvaluator(evaluator: *pkl.Evaluator, path: []const u8) !@This() {
        return evaluator.loadFromPath(@This(), path);
    }

    pub fn load(evaluator: *pkl.Evaluator, module_uri: []const u8) !@This() {
        return evaluator.load(@This(), module_uri);
    }
};
