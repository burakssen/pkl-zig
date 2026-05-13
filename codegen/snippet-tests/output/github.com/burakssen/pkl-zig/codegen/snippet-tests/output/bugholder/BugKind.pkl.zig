// Code generated from Pkl module `org.foo.BugHolder`. DO NOT EDIT.
const std = @import("std");

pub const BugKind = enum {
    butterfly,
    beetle,
    beetle_one,

    pub fn parse(value: []const u8) !BugKind {
        if (std.mem.eql(u8, value, "butterfly")) return .butterfly;
        if (std.mem.eql(u8, value, "beetle\"")) return .beetle;
        if (std.mem.eql(u8, value, "beetle one")) return .beetle_one;
        return error.InvalidEnumValue;
    }

    pub fn pklName(self: BugKind) []const u8 {
        return switch (self) {
            .butterfly => "butterfly",
            .beetle => "beetle\"",
            .beetle_one => "beetle one",
        };
    }
};
