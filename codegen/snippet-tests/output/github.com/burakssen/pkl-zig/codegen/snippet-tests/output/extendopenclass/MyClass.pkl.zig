// Code generated from Pkl module `ExtendingOpenClass`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const ExtendingOpenClass = @import("ExtendingOpenClass.pkl.zig").ExtendingOpenClass;
const MyOpenClass = @import("MyOpenClass.pkl.zig").MyOpenClass;
const MyClass2 = @import("MyClass2.pkl.zig").MyClass2;

pub const MyClass = struct {
    mystr: []const u8,
    myboolean: bool,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "mystr", .pkl = "myStr" },
        .{ .zig = "myboolean", .pkl = "myBoolean" },
    };
};
