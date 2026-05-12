const std = @import("std");

const Transport = @This();

const channel = @import("channel.zig");
const envelope_mod = @import("envelope.zig");
const io_tasks = @import("io.zig");
const lifecycle = @import("lifecycle.zig");
const message = @import("message");

pub const frame = @import("frame.zig");
pub const IncomingEnvelope = envelope_mod.IncomingEnvelope;

pub const queue_capacity = 16;

pub const Options = struct {
    pkl_argv: []const []const u8 = &.{ "pkl", "server" },
    stderr: std.process.SpawnOptions.StdIo = .inherit,
};

io: std.Io,
allocator: std.mem.Allocator,
child: std.process.Child,
group: std.Io.Group,
started: bool,

outgoing_buffer: [queue_capacity][]u8,
incoming_buffer: [queue_capacity]IncomingEnvelope,
outgoing: std.Io.Queue([]u8),
incoming: std.Io.Queue(IncomingEnvelope),

pub const init = lifecycle.init;
pub const initWithOptions = lifecycle.initWithOptions;
pub const deinit = lifecycle.deinit;
pub const start = lifecycle.start;
pub const send = channel.send;
pub const recv = channel.recv;

test "send enqueues owned msgpack frame bytes" {
    const msgpack = @import("msgpack");

    const allocator = std.testing.allocator;

    var transport = Transport{
        .io = std.testing.io,
        .allocator = allocator,
        .child = undefined,
        .group = .init,
        .started = true,
        .outgoing_buffer = undefined,
        .incoming_buffer = undefined,
        .outgoing = undefined,
        .incoming = undefined,
    };
    transport.outgoing = .init(&transport.outgoing_buffer);
    transport.incoming = .init(&transport.incoming_buffer);

    try transport.send(.{
        .create_evaluator = .{
            .request_id = 135,
            .allowed_modules = &.{ "pkl:", "repl:", "file:" },
        },
    });

    const data = try transport.outgoing.getOne(std.testing.io);
    defer allocator.free(data);

    var writer_buffer: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buffer);
    var reader = std.Io.Reader.fixed(data);
    var packer = msgpack.PackerIO.init(&reader, &writer);

    var payload = try packer.read(allocator);
    defer payload.free(allocator);

    const decoded_frame = try message.codec.decodeFrame(&payload);
    try std.testing.expectEqual(message.Code.new_evaluator, decoded_frame.code);
}

test "incoming envelope owns payload backing decoded message" {
    const msgpack = @import("msgpack");

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
        .create_evaluator_response => |resp| {
            try std.testing.expectEqual(@as(i64, 100), resp.request_id);
            try std.testing.expectEqual(@as(i64, 200), resp.evaluator_id.?);
            try std.testing.expectEqualStrings("no error", resp.@"error".?);
        },
        else => return error.UnexpectedMessage,
    }
}

test {
    _ = channel;
    _ = envelope_mod;
    _ = frame;
    _ = io_tasks;
    _ = lifecycle;
}
