// Code generated from Pkl module `overrideerr`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const Overrideerr = @import("Overrideerr.pkl.zig").Overrideerr;
const Child = @import("Child.pkl.zig").Child;

pub const Parent = struct {
    prop: i64,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "prop", .pkl = "prop" },
    };
};
