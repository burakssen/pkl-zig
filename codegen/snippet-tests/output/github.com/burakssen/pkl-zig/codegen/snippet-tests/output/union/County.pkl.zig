// Code generated from Pkl module `union`. DO NOT EDIT.
const std = @import("std");

/// Locale that contains cities and towns
pub const County = enum {
    san_francisco,
    san_mateo,
    yolo,

    pub fn parse(value: []const u8) !County {
        if (std.mem.eql(u8, value, "San Francisco")) return .san_francisco;
        if (std.mem.eql(u8, value, "San Mateo")) return .san_mateo;
        if (std.mem.eql(u8, value, "Yolo")) return .yolo;
        return error.InvalidEnumValue;
    }

    pub fn pklName(self: County) []const u8 {
        return switch (self) {
            .san_francisco => "San Francisco",
            .san_mateo => "San Mateo",
            .yolo => "Yolo",
        };
    }
};
