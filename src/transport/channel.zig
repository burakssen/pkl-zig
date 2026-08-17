const std = @import("std");

const message = @import("message");
const Transport = @import("transport.zig");

const log = std.log.scoped(.@"pkl-zig|transport|channel");

pub fn send(self: *Transport, msg: message.Outgoing) !void {
    if (!self.isStarted()) {
        log.warn("Cannot send {s}: transport is not started.", .{@tagName(msg)});
        return error.NotStarted;
    }

    log.debug("Sending outgoing message {s}.", .{@tagName(msg)});
    const data = try Transport.frame.encodeOutgoing(self.allocator, msg);
    errdefer self.allocator.free(data);

    self.outgoing.putOne(self.io, .{ .data = data }) catch |err| {
        return self.resolveQueueError(err);
    };
    log.debug("Queued outgoing message {s}.", .{@tagName(msg)});
}

/// Queue a frame and wait until the writer task has successfully written all of
/// its bytes to the child stdin. Flush operations are serialized so a simple
/// acknowledgement queue is sufficient and acknowledgements cannot be stolen
/// by another flush waiter.
pub fn sendAndFlush(self: *Transport, msg: message.Outgoing) !void {
    try self.flush_mutex.lock(self.io);
    defer self.flush_mutex.unlock(self.io);

    if (!self.isStarted()) {
        log.warn("Cannot send and flush {s}: transport is not started.", .{@tagName(msg)});
        return error.NotStarted;
    }

    const token = self.nextFlushToken();
    const data = try Transport.frame.encodeOutgoing(self.allocator, msg);

    // Transfer ownership to the outgoing queue only after putOne succeeds.
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

        // A stale acknowledgement can exist if an earlier waiter was canceled
        // after its frame was written. There is only one active flush waiter,
        // so discarding that stale token is safe.
        log.debug("Discarded stale flush acknowledgement {} while waiting for {}.", .{ flushed_token, token });
    }
}

pub fn recv(self: *Transport) !Transport.IncomingEnvelope {
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
