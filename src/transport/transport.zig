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

pub const OutgoingFrame = struct {
    data: []u8,
    flush_token: ?u64 = null,
};

pub const Options = struct {
    pkl_argv: []const []const u8 = &.{ "pkl", "server" },
    stderr: std.process.SpawnOptions.StdIo = .inherit,
};

io: std.Io,
allocator: std.mem.Allocator,
child: std.process.Child,
group: std.Io.Group,
started: bool,

outgoing_buffer: [queue_capacity]OutgoingFrame,
incoming_buffer: [queue_capacity]IncomingEnvelope,
flushed_buffer: [queue_capacity]u64,
outgoing: std.Io.Queue(OutgoingFrame),
incoming: std.Io.Queue(IncomingEnvelope),
flushed: std.Io.Queue(u64),

state_mutex: std.Io.Mutex = .init,
flush_mutex: std.Io.Mutex = .init,
next_flush_token: u64 = 1,
terminal_error: ?anyerror = null,

pub const init = lifecycle.init;
pub const initWithOptions = lifecycle.initWithOptions;
pub const deinit = lifecycle.deinit;
pub const start = lifecycle.start;
pub const send = channel.send;
pub const sendAndFlush = channel.sendAndFlush;
pub const recv = channel.recv;

pub fn isStarted(self: *Transport) bool {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    return self.started;
}

/// Set the started state and return its previous value.
pub fn setStarted(self: *Transport, started: bool) bool {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);

    const previous = self.started;
    self.started = started;
    return previous;
}

pub fn recordTerminalError(self: *Transport, err: anyerror) void {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);

    if (self.terminal_error == null) self.terminal_error = err;
}

pub fn terminalError(self: *Transport) ?anyerror {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    return self.terminal_error;
}

pub fn resolveQueueError(self: *Transport, fallback: anyerror) anyerror {
    return self.terminalError() orelse fallback;
}

pub fn nextFlushToken(self: *Transport) u64 {
    // sendAndFlush holds flush_mutex for the entire operation, so no second
    // lock is needed here.
    const token = self.next_flush_token;
    self.next_flush_token +%= 1;
    if (self.next_flush_token == 0) self.next_flush_token = 1;
    return token;
}

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
        .flushed_buffer = undefined,
        .outgoing = undefined,
        .incoming = undefined,
        .flushed = undefined,
    };
    transport.outgoing = .init(&transport.outgoing_buffer);
    transport.incoming = .init(&transport.incoming_buffer);
    transport.flushed = .init(&transport.flushed_buffer);

    try transport.send(.{
        .create_evaluator = .{
            .request_id = 135,
            .allowed_modules = &.{ "pkl:", "repl:", "file:" },
        },
    });

    const queued = try transport.outgoing.getOne(std.testing.io);
    defer allocator.free(queued.data);

    try std.testing.expectEqual(@as(?u64, null), queued.flush_token);

    var writer_buffer: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buffer);
    var reader = std.Io.Reader.fixed(queued.data);
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
        .create_evaluator_response => |response| {
            try std.testing.expectEqual(@as(i64, 100), response.request_id);
            try std.testing.expectEqual(@as(i64, 200), response.evaluator_id.?);
            try std.testing.expectEqualStrings("no error", response.@"error".?);
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
