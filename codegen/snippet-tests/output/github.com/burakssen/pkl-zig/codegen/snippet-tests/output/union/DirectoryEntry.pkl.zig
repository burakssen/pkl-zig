// Code generated from Pkl module `union`. DO NOT EDIT.
const std = @import("std");
const pkl = @import("pkl");
const File = @import("File.pkl.zig").File;
const Directory = @import("Directory.pkl.zig").Directory;

pub const DirectoryEntry = union(enum) {
    file: File,
    directory: Directory,

    pub fn fromPklValue(allocator: std.mem.Allocator, value: pkl.Value) !@This() {
        const object = switch (value) {
            .object => |object| object,
            else => return error.UnsupportedType,
        };
        if (std.mem.eql(u8, object.name, "union#File")) {
            return .{ .file = try pkl.value.fromValue(File, allocator, value) };
        }
        if (std.mem.eql(u8, object.name, "union#Directory")) {
            return .{ .directory = try pkl.value.fromValue(Directory, allocator, value) };
        }
        return error.UnsupportedType;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pkl.deinit(@This(), allocator, self);
    }
};
