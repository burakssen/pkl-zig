const std = @import("std");
const msgpack = @import("msgpack");

const message = @import("message");

const log = std.log.scoped(.@"pkl-zig|transport|envelope");

pub const IncomingEnvelope = struct {
    payload: msgpack.Payload,
    msg: message.Incoming,

    pub fn deinit(self: *IncomingEnvelope, allocator: std.mem.Allocator) void {
        log.debug("Deinitializing incoming envelope {s}.", .{@tagName(self.msg)});
        self.payload.free(allocator);
        self.* = undefined;
    }
};
