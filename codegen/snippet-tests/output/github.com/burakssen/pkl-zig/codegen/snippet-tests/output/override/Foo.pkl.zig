// Code generated from Pkl module `override`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const Override = @import("Override.pkl.zig").Override;
const Bar = @import("Bar.pkl.zig").Bar;

pub const Foo = struct {
    myprop: []const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "myprop", .pkl = "myProp" },
    };
};
