// Code generated from Pkl module `ExtendingOpenClass`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const ExtendingOpenClass = @import("ExtendingOpenClass.pkl.zig").ExtendingOpenClass;
const MyClass = @import("MyClass.pkl.zig").MyClass;
const MyClass2 = @import("MyClass2.pkl.zig").MyClass2;

pub const MyOpenClass = struct {
    mystr: []const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pkl.deinit(@This(), allocator, self);
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "mystr", .pkl = "myStr" },
    };
};
