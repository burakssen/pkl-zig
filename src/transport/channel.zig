const std = @import("std");

const message = @import("message");

const Transport = @import("transport.zig");

const log = std.log.scoped(.@"pkl-zig|transport|channel");

pub fn send(
    self: *Transport,
    msg: message.Outgoing,
) !void {
    if (!self.started) {
        log.warn("Cannot send {s}: transport is not started.", .{@tagName(msg)});
        return error.NotStarted;
    }

    log.debug("Sending outgoing message {s}.", .{@tagName(msg)});
    const data = try Transport.frame.encodeOutgoing(self.allocator, msg);
    errdefer self.allocator.free(data);

    try self.outgoing.putOne(self.io, data);
    log.debug("Queued outgoing message {s}.", .{@tagName(msg)});
}

pub fn recv(self: *Transport) !Transport.IncomingEnvelope {
    if (!self.started) {
        log.warn("Cannot receive message: transport is not started.", .{});
        return error.NotStarted;
    }

    log.debug("Receiving incoming message.", .{});
    const envelope = try self.incoming.getOne(self.io);
    log.debug("Received incoming message {s}.", .{@tagName(envelope.msg)});
    return envelope;
}

pub fn drainOutgoing(self: *Transport) void {
    var count: usize = 0;
    while (true) {
        const data = self.outgoing.getOne(self.io) catch break;
        self.allocator.free(data);
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
