// Code generated from Pkl module `ExtendsAbstractClass`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const ExtendsAbstractClass = @import("ExtendsAbstractClass.pkl.zig").ExtendsAbstractClass;
const B = @import("B.pkl.zig").B;
const C = @import("C.pkl.zig").C;

pub const A = struct {
    b: []const u8,
    c: @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib3").ZigZigZig,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pkl.deinit(@This(), allocator, self);
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "b", .pkl = "b" },
        .{ .zig = "c", .pkl = "c" },
    };
};
