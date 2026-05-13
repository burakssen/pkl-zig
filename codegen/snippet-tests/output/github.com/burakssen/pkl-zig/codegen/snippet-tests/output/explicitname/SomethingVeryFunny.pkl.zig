// Code generated from Pkl module `ExplicitName`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const ConfigType = @import("ConfigType.pkl.zig").ConfigType;
const ExplicitlyCoolName = @import("ExplicitlyCoolName.pkl.zig").ExplicitlyCoolName;

pub const SomethingVeryFunny = struct {

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        return inline for (field_names) |entry| {
            if (std.mem.eql(u8, field_name, entry.zig)) break entry.pkl;
        } else field_name;
    }

    const field_names = [_]struct { zig: []const u8, pkl: []const u8 }{
    };
};
