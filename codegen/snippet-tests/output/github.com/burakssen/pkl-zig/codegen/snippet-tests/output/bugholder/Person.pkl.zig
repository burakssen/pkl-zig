// Code generated from Pkl module `org.foo.BugHolder`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const BugKind = @import("BugKind.pkl.zig").BugKind;
const BugKindTwo = @import("BugKindTwo.pkl.zig").BugKindTwo;
const BugHolder = @import("BugHolder.pkl.zig").BugHolder;
const Bug = @import("Bug.pkl.zig").Bug;
const Bike = @import("Bike.pkl.zig").Bike;
const Wheel = @import("Wheel.pkl.zig").Wheel;
const Being = @import("Being.pkl.zig").Being;
const ThisPerson = @import("ThisPerson.pkl.zig").ThisPerson;
const D = @import("D.pkl.zig").D;
const C = @import("C.pkl.zig").C;
const B = @import("B.pkl.zig").B;
const A = @import("A.pkl.zig").A;

/// A Person!
pub const Person = struct {
    isalive: bool,
    bike: Bike,
    /// The person's first name
    firstname: ?u16,
    /// The person's last name
    lastname: std.StringHashMap(?u32),
    things: []i64,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pkl.deinit(@This(), allocator, self);
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "isalive", .pkl = "isAlive" },
        .{ .zig = "bike", .pkl = "bike" },
        .{ .zig = "firstname", .pkl = "firstName" },
        .{ .zig = "lastname", .pkl = "lastName" },
        .{ .zig = "things", .pkl = "things" },
    };
};
