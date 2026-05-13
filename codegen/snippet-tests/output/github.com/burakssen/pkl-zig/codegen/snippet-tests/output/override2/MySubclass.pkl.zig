// Code generated from Pkl module `Override2`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const Override2 = @import("Override2.pkl.zig").Override2;

pub const MySubclass = struct {
    /// Different doc comments
    foo: []const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "foo", .pkl = "foo" },
    };
};
