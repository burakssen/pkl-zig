// Code generated from Pkl module `lib`. DO NOT EDIT.
const std = @import("std");

pub const MyEnum = enum {
    one,
    two,
    three,

    pub fn parse(value: []const u8) !MyEnum {
        if (std.mem.eql(u8, value, "one")) return .one;
        if (std.mem.eql(u8, value, "two")) return .two;
        if (std.mem.eql(u8, value, "three")) return .three;
        return error.InvalidEnumValue;
    }

    pub fn pklName(self: MyEnum) []const u8 {
        return switch (self) {
            .one => "one",
            .two => "two",
            .three => "three",
        };
    }
};
