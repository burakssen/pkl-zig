// Code generated from Pkl module `ExplicitName`. DO NOT EDIT.
const std = @import("std");

pub const ConfigType = enum {
    one,
    two,

    pub fn parse(value: []const u8) !ConfigType {
        if (std.mem.eql(u8, value, "one")) return .one;
        if (std.mem.eql(u8, value, "two")) return .two;
        return error.InvalidEnumValue;
    }

    pub fn pklName(self: ConfigType) []const u8 {
        return switch (self) {
            .one => "one",
            .two => "two",
        };
    }
};
