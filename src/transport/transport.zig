const std = @import("std");
const msgpack = @import("msgpack");
const message = @import("message");

const build_options = if (@hasDecl(@import("root"), "build_options"))
    @import("root").build_options
else
    @import("build_options");

const log = std.log.scoped(.@"pkl-zig|transport");

pub const queue_capacity = 16;

pub const IncomingEnvelope = struct {
    payload: msgpack.Payload,
    msg: message.Incoming,

    pub fn deinit(self: *IncomingEnvelope, allocator: std.mem.Allocator) void {
        log.debug("Deinitializing incoming envelope {s}.", .{@tagName(self.msg)});
        self.payload.free(allocator);
        self.* = undefined;
    }
};

pub const OutgoingFrame = struct {
    data: []u8,
    flush_token: ?u64 = null,
};

pub const Process = @import("process.zig");
pub const LibPkl = @import("libpkl.zig").LibPklTransport;

// Default to native libpkl transport; Process available when -Dprocess=true is used
pub const Transport = if (@hasDecl(build_options, "use_libpkl") and !build_options.use_libpkl)
    Process
else
    LibPkl;

pub const Options = Transport.Options;
pub const init = Transport.init;
pub const initWithOptions = Transport.initWithOptions;

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

test "incoming envelope owns payload backing decoded message" {
    const allocator = std.testing.allocator;
    var body = msgpack.Payload.mapPayload(allocator);
    try body.mapPut("requestId", msgpack.Payload.intToPayload(100));
    try body.mapPut("evaluatorId", msgpack.Payload.intToPayload(200));
    try body.mapPut("error", try msgpack.Payload.strToPayload("no error", allocator));

    var payload = try message.codec.encodeFrame(allocator, .new_evaluator_response, body);
    errdefer payload.free(allocator);
    const incoming_msg = try message.Incoming.decode(allocator, &payload);
    var envelope = IncomingEnvelope{
        .payload = payload,
        .msg = incoming_msg,
    };
    defer envelope.deinit(allocator);

    switch (envelope.msg) {
        .create_evaluator_response => |response| {
            try std.testing.expectEqual(@as(i64, 100), response.request_id);
            try std.testing.expectEqual(@as(i64, 200), response.evaluator_id.?);
            try std.testing.expectEqualStrings("no error", response.@"error".?);
        },
        else => return error.UnexpectedMessage,
    }
}

test {
    _ = Process;
    _ = LibPkl;
}
