// Code generated from Pkl module `union`. DO NOT EDIT.
const std = @import("std");

pub const AccountDisposition = enum {
    empty,
    icloud3,
    prod,
    shared,

    pub fn parse(value: []const u8) !AccountDisposition {
        if (std.mem.eql(u8, value, "")) return .empty;
        if (std.mem.eql(u8, value, "icloud3")) return .icloud3;
        if (std.mem.eql(u8, value, "prod")) return .prod;
        if (std.mem.eql(u8, value, "shared")) return .shared;
        return error.InvalidEnumValue;
    }

    pub fn pklName(self: AccountDisposition) []const u8 {
        return switch (self) {
            .empty => "",
            .icloud3 => "icloud3",
            .prod => "prod",
            .shared => "shared",
        };
    }
};
