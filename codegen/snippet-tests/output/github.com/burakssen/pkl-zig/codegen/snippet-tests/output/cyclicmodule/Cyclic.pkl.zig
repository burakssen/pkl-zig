// Code generated from Pkl module `CyclicModule`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const CyclicModule = @import("CyclicModule.pkl.zig").CyclicModule;

pub const Cyclic = struct {
    a: []const u8,
    b: i64,
    myself: ?Cyclic,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "a", .pkl = "a" },
        .{ .zig = "b", .pkl = "b" },
        .{ .zig = "myself", .pkl = "myself" },
    };
};
