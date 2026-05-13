// Code generated from Pkl module `lib2`. DO NOT EDIT.
const std = @import("std");

pub const Cities = enum {
    london,
    san_francisco,
    los_angeles,

    pub fn parse(value: []const u8) !Cities {
        if (std.mem.eql(u8, value, "London")) return .london;
        if (std.mem.eql(u8, value, "San Francisco")) return .san_francisco;
        if (std.mem.eql(u8, value, "Los Angeles")) return .los_angeles;
        return error.InvalidEnumValue;
    }

    pub fn pklName(self: Cities) []const u8 {
        return switch (self) {
            .london => "London",
            .san_francisco => "San Francisco",
            .los_angeles => "Los Angeles",
        };
    }
};
