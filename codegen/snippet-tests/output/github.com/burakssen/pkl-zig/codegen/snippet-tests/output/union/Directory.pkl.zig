// Code generated from Pkl module `union`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const County = @import("County.pkl.zig").County;
const AccountDisposition = @import("AccountDisposition.pkl.zig").AccountDisposition;
const Union = @import("Union.pkl.zig").Union;
const File = @import("File.pkl.zig").File;

pub const Directory = struct {
    name: []const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
        .{ .zig = "name", .pkl = "name" },
    };
};
