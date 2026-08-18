const std = @import("std");
const msgpack = @import("msgpack");
const message = @import("message");

const io_tasks = @import("io.zig");

const log = std.log.scoped(.@"pkl-zig|transport");

const Transport = @This();

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

pub const Options = struct {
    pkl_argv: []const []const u8 = &.{ "pkl", "server" },
    stderr: std.process.SpawnOptions.StdIo = .inherit,
};

pub const frame = struct {
    pub const encodeOutgoing = Transport.encodeOutgoing;
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

pub fn init(io_handle: std.Io, allocator: std.mem.Allocator) !*Transport {
    return initWithOptions(io_handle, allocator, .{});
}

pub fn initWithOptions(
    io_handle: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
) !*Transport {
    log.info("Initializing transport.", .{});

    const transport = try allocator.create(Transport);
    errdefer allocator.destroy(transport);

    log.info("Spawning pkl server process.", .{});
    const child = try std.process.spawn(io_handle, .{
        .argv = options.pkl_argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = options.stderr,
    });
    errdefer child.kill(io_handle);

    transport.* = .{
        .io = io_handle,
        .allocator = allocator,
        .child = child,
        .group = .init,
        .started = false,
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

    log.info("Initialized transport.", .{});
    return transport;
}

pub fn deinit(self: *Transport) void {
    log.info("Deinitializing transport.", .{});

    const was_started = self.setStarted(false);

    self.outgoing.close(self.io);
    self.incoming.close(self.io);
    self.flushed.close(self.io);

    if (was_started) {
        log.info("Canceling transport task group.", .{});
        self.group.cancel(self.io);
    } else if (self.child.stdin) |stdin_value| {
        var stdin = stdin_value;
        stdin.close(self.io);
        self.child.stdin = null;
    }

    self.drainOutgoing();
    self.drainIncoming();

    if (self.child.id != null) {
        log.info("Waiting for pkl server process to exit.", .{});
        _ = self.child.wait(self.io) catch |err| {
            log.warn("Failed to wait for pkl server process: {}. Killing it.", .{err});
            if (self.child.id != null) self.child.kill(self.io);
        };
    }

    self.allocator.destroy(self);
    log.info("Deinitialized transport.", .{});
}

pub fn start(self: *Transport) !void {
    if (self.isStarted()) {
        log.warn("Transport already started.", .{});
        return;
    }

    log.info("Starting transport tasks.", .{});
    _ = self.setStarted(true);
    self.group.async(self.io, io_tasks.readTask, .{self});
    self.group.async(self.io, io_tasks.writeTask, .{self});
    log.info("Started transport tasks.", .{});
}

pub fn send(self: *Transport, msg: message.Outgoing) !void {
    if (!self.isStarted()) {
        log.warn("Cannot send {s}: transport is not started.", .{@tagName(msg)});
        return error.NotStarted;
    }

    log.debug("Sending outgoing message {s}.", .{@tagName(msg)});
    const data = try encodeOutgoing(self.allocator, msg);
    errdefer self.allocator.free(data);

    self.outgoing.putOne(self.io, .{ .data = data }) catch |err| {
        return self.resolveQueueError(err);
    };
    log.debug("Queued outgoing message {s}.", .{@tagName(msg)});
}

pub fn sendAndFlush(self: *Transport, msg: message.Outgoing) !void {
    try self.flush_mutex.lock(self.io);
    defer self.flush_mutex.unlock(self.io);

    if (!self.isStarted()) {
        log.warn("Cannot send and flush {s}: transport is not started.", .{@tagName(msg)});
        return error.NotStarted;
    }

    const token = self.nextFlushToken();
    const data = try encodeOutgoing(self.allocator, msg);

    {
        errdefer self.allocator.free(data);
        self.outgoing.putOne(self.io, .{
            .data = data,
            .flush_token = token,
        }) catch |err| {
            return self.resolveQueueError(err);
        };
    }

    while (true) {
        const flushed_token = self.flushed.getOne(self.io) catch |err| {
            return self.resolveQueueError(err);
        };
        if (flushed_token == token) return;
        log.debug("Discarded stale flush acknowledgement {} while waiting for {}.", .{ flushed_token, token });
    }
}

pub fn recv(self: *Transport) !IncomingEnvelope {
    if (!self.isStarted()) {
        log.warn("Cannot receive message: transport is not started.", .{});
        return error.NotStarted;
    }

    log.debug("Receiving incoming message.", .{});
    const envelope = self.incoming.getOne(self.io) catch |err| {
        return self.resolveQueueError(err);
    };
    log.debug("Received incoming message {s}.", .{@tagName(envelope.msg)});
    return envelope;
}

pub fn drainOutgoing(self: *Transport) void {
    var count: usize = 0;
    while (true) {
        const outgoing = self.outgoing.getOne(self.io) catch break;
        self.allocator.free(outgoing.data);
        count += 1;
    }

    if (count == 0) {
        log.debug("Drained {} outgoing queued messages.", .{count});
    } else {
        log.warn("Drained {} outgoing queued messages.", .{count});
    }
}

pub fn drainIncoming(self: *Transport) void {
    var count: usize = 0;
    while (true) {
        var envelope = self.incoming.getOne(self.io) catch break;
        envelope.deinit(self.allocator);
        count += 1;
    }

    if (count == 0) {
        log.debug("Drained {} incoming queued messages.", .{count});
    } else {
        log.warn("Drained {} incoming queued messages.", .{count});
    }
}

pub fn isStarted(self: *Transport) bool {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    return self.started;
}

pub fn setStarted(self: *Transport, started_val: bool) bool {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);

    const previous = self.started;
    self.started = started_val;
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
    const token = self.next_flush_token;
    self.next_flush_token +%= 1;
    if (self.next_flush_token == 0) self.next_flush_token = 1;
    return token;
}

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

    // avoid double-buffering by directly converting allocating_writer's buffer
    var list = allocating_writer.toArrayList();
    defer list.deinit(allocator);

    const data = try list.toOwnedSlice(allocator);
    log.debug("Encoded outgoing frame for {s}: {} bytes.", .{ @tagName(msg), data.len });
    return data;
}

test "send enqueues owned msgpack frame bytes" {
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
    _ = io_tasks;
}
