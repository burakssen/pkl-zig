const std = @import("std");
const msgpack = @import("msgpack");
const message = @import("message");

const transport = @import("transport.zig");
const io_tasks = @import("io.zig");

const log = std.log.scoped(.@"pkl-zig|transport-process");

const ProcessTransport = @This();

pub const queue_capacity = transport.queue_capacity;
pub const IncomingEnvelope = transport.IncomingEnvelope;
pub const OutgoingFrame = transport.OutgoingFrame;

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

pub fn init(io_handle: std.Io, allocator: std.mem.Allocator) !*ProcessTransport {
    return initWithOptions(io_handle, allocator, .{});
}

pub fn initWithOptions(
    io_handle: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
) !*ProcessTransport {
    log.info("Initializing process transport.", .{});

    const self = try allocator.create(ProcessTransport);
    errdefer allocator.destroy(self);

    log.info("Spawning pkl server process.", .{});
    const child = try std.process.spawn(io_handle, .{
        .argv = options.pkl_argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = options.stderr,
    });
    errdefer child.kill(io_handle);

    self.* = .{
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
    self.outgoing = .init(&self.outgoing_buffer);
    self.incoming = .init(&self.incoming_buffer);
    self.flushed = .init(&self.flushed_buffer);

    log.info("Initialized process transport.", .{});
    return self;
}

pub fn deinit(self: *ProcessTransport) void {
    log.info("Deinitializing process transport.", .{});

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
    log.info("Deinitialized process transport.", .{});
}

pub fn start(self: *ProcessTransport) !void {
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

pub fn send(self: *ProcessTransport, msg: message.Outgoing) !void {
    if (!self.isStarted()) {
        log.warn("Cannot send {s}: transport is not started.", .{@tagName(msg)});
        return error.NotStarted;
    }

    log.debug("Sending outgoing message {s}.", .{@tagName(msg)});
    const data = try transport.encodeOutgoing(self.allocator, msg);
    errdefer self.allocator.free(data);

    self.outgoing.putOne(self.io, .{ .data = data }) catch |err| {
        return self.resolveQueueError(err);
    };
    log.debug("Queued outgoing message {s}.", .{@tagName(msg)});
}

pub fn sendAndFlush(self: *ProcessTransport, msg: message.Outgoing) !void {
    try self.flush_mutex.lock(self.io);
    defer self.flush_mutex.unlock(self.io);

    if (!self.isStarted()) {
        log.warn("Cannot send and flush {s}: transport is not started.", .{@tagName(msg)});
        return error.NotStarted;
    }

    const token = self.nextFlushToken();
    const data = try transport.encodeOutgoing(self.allocator, msg);

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

pub fn recv(self: *ProcessTransport) !IncomingEnvelope {
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

pub fn drainOutgoing(self: *ProcessTransport) void {
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

pub fn drainIncoming(self: *ProcessTransport) void {
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

pub fn isStarted(self: *ProcessTransport) bool {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    return self.started;
}

pub fn setStarted(self: *ProcessTransport, started_val: bool) bool {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);

    const previous = self.started;
    self.started = started_val;
    return previous;
}

pub fn recordTerminalError(self: *ProcessTransport, err: anyerror) void {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);

    if (self.terminal_error == null) self.terminal_error = err;
}

pub fn terminalError(self: *ProcessTransport) ?anyerror {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    return self.terminal_error;
}

pub fn resolveQueueError(self: *ProcessTransport, fallback: anyerror) anyerror {
    return self.terminalError() orelse fallback;
}

pub fn nextFlushToken(self: *ProcessTransport) u64 {
    const token = self.next_flush_token;
    self.next_flush_token +%= 1;
    if (self.next_flush_token == 0) self.next_flush_token = 1;
    return token;
}

test "send enqueues owned msgpack frame bytes" {
    const allocator = std.testing.allocator;
    var process_transport = ProcessTransport{
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
    process_transport.outgoing = .init(&process_transport.outgoing_buffer);
    process_transport.incoming = .init(&process_transport.incoming_buffer);
    process_transport.flushed = .init(&process_transport.flushed_buffer);

    try process_transport.send(.{
        .create_evaluator = .{
            .request_id = 135,
            .allowed_modules = &.{ "pkl:", "repl:", "file:" },
        },
    });

    const queued = try process_transport.outgoing.getOne(std.testing.io);
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
