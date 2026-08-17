const std = @import("std");

const Transport = @import("transport.zig");
const channel = @import("channel.zig");
const io_tasks = @import("io.zig");

const log = std.log.scoped(.@"pkl-zig|transport|lifecycle");

pub fn init(io_handle: std.Io, allocator: std.mem.Allocator) !*Transport {
    return initWithOptions(io_handle, allocator, .{});
}

pub fn initWithOptions(
    io_handle: std.Io,
    allocator: std.mem.Allocator,
    options: Transport.Options,
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

    // Closing the queues wakes blocked task operations. The task group is then
    // canceled to interrupt child-pipe I/O that is currently in progress.
    self.outgoing.close(self.io);
    self.incoming.close(self.io);
    self.flushed.close(self.io);

    if (was_started) {
        log.info("Canceling transport task group.", .{});
        self.group.cancel(self.io);
    } else if (self.child.stdin) |stdin_value| {
        // A transport may be initialized and deinitialized without start().
        // Close stdin explicitly so the pkl server can observe EOF and exit.
        var stdin = stdin_value;
        stdin.close(self.io);
        self.child.stdin = null;
    }

    channel.drainOutgoing(self);
    channel.drainIncoming(self);

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

    // Mark the transport started before scheduling tasks so a task that runs
    // immediately never mistakes normal startup for shutdown.
    _ = self.setStarted(true);
    self.group.async(self.io, io_tasks.readTask, .{self});
    self.group.async(self.io, io_tasks.writeTask, .{self});

    log.info("Started transport tasks.", .{});
}
