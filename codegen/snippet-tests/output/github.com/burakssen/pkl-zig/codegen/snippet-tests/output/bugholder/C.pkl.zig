// Code generated from Pkl module `org.foo.BugHolder`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const BugKind = @import("BugKind.pkl.zig").BugKind;
const BugKindTwo = @import("BugKindTwo.pkl.zig").BugKindTwo;
const BugHolder = @import("BugHolder.pkl.zig").BugHolder;
const Bug = @import("Bug.pkl.zig").Bug;
const Person = @import("Person.pkl.zig").Person;
const Bike = @import("Bike.pkl.zig").Bike;
const Wheel = @import("Wheel.pkl.zig").Wheel;
const Being = @import("Being.pkl.zig").Being;
const ThisPerson = @import("ThisPerson.pkl.zig").ThisPerson;
const D = @import("D.pkl.zig").D;
const B = @import("B.pkl.zig").B;
const A = @import("A.pkl.zig").A;

pub const C = struct {
    a: []const u8,
    b: []const u8,
    c: []const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pkl.deinit(@This(), allocator, self);
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "a", .pkl = "a" },
        .{ .zig = "b", .pkl = "b" },
        .{ .zig = "c", .pkl = "c" },
    };
};
