const std = @import("std");

const Transport = @import("transport.zig");
const channel = @import("channel.zig");
const io_tasks = @import("io.zig");

const log = std.log.scoped(.@"pkl-zig|transport|lifecycle");

pub fn init(
    io_handle: std.Io,
    allocator: std.mem.Allocator,
) !*Transport {
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
        .outgoing = undefined,
        .incoming = undefined,
    };
    transport.outgoing = .init(&transport.outgoing_buffer);
    transport.incoming = .init(&transport.incoming_buffer);

    log.info("Initialized transport.", .{});
    return transport;
}

pub fn deinit(self: *Transport) void {
    log.info("Deinitializing transport.", .{});

    self.outgoing.close(self.io);
    self.incoming.close(self.io);

    if (self.started) {
        log.info("Canceling transport task group.", .{});
        self.started = false;
        self.group.cancel(self.io);
    }

    channel.drainOutgoing(self);
    channel.drainIncoming(self);

    if (self.child.id != null) {
        log.info("Waiting for pkl server process to exit.", .{});
        _ = self.child.wait(self.io) catch |err| {
            log.warn("Failed to wait for pkl server process: {}. Killing it.", .{err});
            if (self.child.id != null) {
                self.child.kill(self.io);
            }
        };
    }

    self.allocator.destroy(self);
    log.info("Deinitialized transport.", .{});
}

pub fn start(self: *Transport) !void {
    if (self.started) {
        log.warn("Transport already started.", .{});
        return;
    }

    log.info("Starting transport tasks.", .{});
    self.group.async(self.io, io_tasks.readTask, .{self});
    self.group.async(self.io, io_tasks.writeTask, .{self});
    self.started = true;
    log.info("Started transport tasks.", .{});
}
