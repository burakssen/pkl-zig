// Code generated from Pkl module `ExtendsAbstractClass`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const ExtendsAbstractClass = @import("ExtendsAbstractClass.pkl.zig").ExtendsAbstractClass;
const A = @import("A.pkl.zig").A;
const B = @import("B.pkl.zig").B;

pub const C = struct {
    b: []const u8,
    c: @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib3").ZigZigZig,
    e: @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib2").Cities,
    d: []const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "b", .pkl = "b" },
        .{ .zig = "c", .pkl = "c" },
        .{ .zig = "e", .pkl = "e" },
        .{ .zig = "d", .pkl = "d" },
    };
};
