// Code generated from Pkl module `org.foo.BugHolder`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const BugKind = @import("BugKind.pkl.zig").BugKind;
const BugKindTwo = @import("BugKindTwo.pkl.zig").BugKindTwo;
const Bug = @import("Bug.pkl.zig").Bug;
const Person = @import("Person.pkl.zig").Person;
const Bike = @import("Bike.pkl.zig").Bike;
const Wheel = @import("Wheel.pkl.zig").Wheel;
const Being = @import("Being.pkl.zig").Being;
const ThisPerson = @import("ThisPerson.pkl.zig").ThisPerson;
const D = @import("D.pkl.zig").D;
const C = @import("C.pkl.zig").C;
const B = @import("B.pkl.zig").B;
const A = @import("A.pkl.zig").A;

pub const BugHolder = struct {
    bug: Bug,
    @"_蚊子": Bug,
    thisperson: ThisPerson,
    d: D,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "bug", .pkl = "bug" },
        .{ .zig = "_蚊子", .pkl = "蚊子" },
        .{ .zig = "thisperson", .pkl = "thisPerson" },
        .{ .zig = "d", .pkl = "d" },
    };

    pub fn loadFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !@This() {
        var evaluator = try pkl.Evaluator.init(io, allocator, .{});
        defer evaluator.deinit();
        return evaluator.loadFromPath(@This(), path);
    }

    pub fn load(evaluator: *pkl.Evaluator, module_uri: []const u8) !@This() {
        return evaluator.load(@This(), module_uri);
    }
};
