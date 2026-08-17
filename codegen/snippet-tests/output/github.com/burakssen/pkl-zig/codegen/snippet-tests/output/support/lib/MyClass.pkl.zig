// Code generated from Pkl module `lib`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const MyEnum = @import("MyEnum.pkl.zig").MyEnum;

pub const MyClass = struct {
    thing: []const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pkl.deinit(@This(), allocator, self);
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "thing", .pkl = "thing" },
    };
};
