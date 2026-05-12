const std = @import("std");
const msgpack = @import("msgpack");

const message = @import("message");

const log = std.log.scoped(.@"pkl-zig|transport|frame");

pub fn encodeOutgoing(allocator: std.mem.Allocator, msg: message.Outgoing) ![]u8 {
    log.debug("Encoding outgoing frame for {s}.", .{@tagName(msg)});

    var payload = try msg.encode(allocator);
    defer payload.free(allocator);

    var allocating_writer: std.Io.Writer.Allocating = .init(allocator);
    defer allocating_writer.deinit();

    var reader_buffer: [1]u8 = undefined;
    var reader: std.Io.Reader = .fixed(&reader_buffer);

    var packer = msgpack.PackerIO.init(&reader, &allocating_writer.writer);
    try packer.write(payload);
    try allocating_writer.writer.flush();

    var list = allocating_writer.toArrayList();
    defer list.deinit(allocator);

    const data = try list.toOwnedSlice(allocator);
    log.debug("Encoded outgoing frame for {s}: {} bytes.", .{ @tagName(msg), data.len });
    return data;
}
