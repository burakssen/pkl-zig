// Code generated from Pkl module `org.foo.BugHolder`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const BugKind = @import("BugKind.pkl.zig").BugKind;
const BugKindTwo = @import("BugKindTwo.pkl.zig").BugKindTwo;
const BugHolder = @import("BugHolder.pkl.zig").BugHolder;
const Person = @import("Person.pkl.zig").Person;
const Bike = @import("Bike.pkl.zig").Bike;
const Wheel = @import("Wheel.pkl.zig").Wheel;
const Being = @import("Being.pkl.zig").Being;
const ThisPerson = @import("ThisPerson.pkl.zig").ThisPerson;
const D = @import("D.pkl.zig").D;
const C = @import("C.pkl.zig").C;
const B = @import("B.pkl.zig").B;
const A = @import("A.pkl.zig").A;

pub const Bug = struct {
    /// The owner of this bug.
    owner: ?Person,
    /// The age of this bug
    age: ?i64,
    /// How long the bug holds its breath for
    holdsbreathfor: pkl.Duration,
    size: pkl.DataSize,
    kind: BugKind,
    kind2: BugKindTwo,
    kind3: []const u8,
    kind4: []const u8,
    bagofstuff: pkl.Value,
    bugclass: pkl.Class,
    bugtypealias: pkl.TypeAlias,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pkl.deinit(@This(), allocator, self);
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "owner", .pkl = "owner" },
        .{ .zig = "age", .pkl = "age" },
        .{ .zig = "holdsbreathfor", .pkl = "holdsBreathFor" },
        .{ .zig = "size", .pkl = "size" },
        .{ .zig = "kind", .pkl = "kind" },
        .{ .zig = "kind2", .pkl = "kind2" },
        .{ .zig = "kind3", .pkl = "kind3" },
        .{ .zig = "kind4", .pkl = "kind4" },
        .{ .zig = "bagofstuff", .pkl = "bagOfStuff" },
        .{ .zig = "bugclass", .pkl = "bugClass" },
        .{ .zig = "bugtypealias", .pkl = "bugTypeAlias" },
    };
};
