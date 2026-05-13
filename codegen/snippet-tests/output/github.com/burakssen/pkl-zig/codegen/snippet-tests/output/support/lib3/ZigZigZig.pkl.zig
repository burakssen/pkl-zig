// Code generated from Pkl module `lib3`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");

pub const ZigZigZig = struct {
    duck: []const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "duck", .pkl = "duck" },
    };
};
