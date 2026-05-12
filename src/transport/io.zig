const std = @import("std");
const msgpack = @import("msgpack");

const message = @import("message");
const Transport = @import("transport.zig");

const log = std.log.scoped(.@"pkl-zig|transport|io");

pub fn readTask(self: *Transport) std.Io.Cancelable!void {
    log.debug("Read task started.", .{});
    readLoop(self) catch |err| switch (err) {
        error.Canceled => {
            log.debug("Read task canceled.", .{});
            self.incoming.close(self.io);
            return error.Canceled;
        },
        else => {
            if (isStopping(self)) {
                log.debug("Read task stopped during transport shutdown: {}.", .{err});
            } else {
                log.err("Read task failed: {}.", .{err});
            }
            self.incoming.close(self.io);
        },
    };
    log.debug("Read task stopped.", .{});
}

pub fn writeTask(self: *Transport) std.Io.Cancelable!void {
    log.debug("Write task started.", .{});
    writeLoop(self) catch |err| switch (err) {
        error.Canceled => {
            log.debug("Write task canceled.", .{});
            self.outgoing.close(self.io);
            return error.Canceled;
        },
        else => {
            if (isStopping(self)) {
                log.debug("Write task stopped during transport shutdown: {}.", .{err});
            } else {
                log.err("Write task failed: {}.", .{err});
            }
            self.outgoing.close(self.io);
        },
    };
    log.debug("Write task stopped.", .{});
}

pub fn readLoop(self: *Transport) !void {
    var stdout = self.child.stdout orelse {
        log.err("Cannot read from pkl server: child stdout is missing.", .{});
        return error.NoChildStdout;
    };

    var read_buffer: [4096]u8 = undefined;
    var stdout_reader = stdout.reader(self.io, &read_buffer);
    const reader = &stdout_reader.interface;

    var write_buffer: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&write_buffer);

    var packer = msgpack.PackerIO.init(reader, &writer);

    while (true) {
        var payload = packer.read(self.allocator) catch |err| switch (err) {
            error.EndOfStream => {
                if (isStopping(self)) {
                    log.debug("Reached end of pkl server stdout during transport shutdown.", .{});
                } else {
                    log.warn("Reached end of pkl server stdout.", .{});
                }
                break;
            },
            else => {
                if (isStopping(self)) {
                    log.debug("Stopped reading incoming msgpack payload during transport shutdown: {}.", .{err});
                } else {
                    log.err("Failed to read incoming msgpack payload: {}.", .{err});
                }
                return err;
            },
        };
        errdefer payload.free(self.allocator);

        const incoming_msg = message.Incoming.decode(self.allocator, &payload) catch |err| {
            log.err("Failed to decode incoming message: {}.", .{err});
            return err;
        };
        log.debug("Decoded incoming message {s}.", .{@tagName(incoming_msg)});
        const close_after_put = incoming_msg == .close_external_process;

        try self.incoming.putOne(self.io, .{
            .payload = payload,
            .msg = incoming_msg,
        });
        log.debug("Queued incoming message {s}.", .{@tagName(incoming_msg)});

        if (close_after_put) break;
    }

    self.incoming.close(self.io);
    log.debug("Closed incoming queue.", .{});
}

pub fn writeLoop(self: *Transport) !void {
    var stdin = self.child.stdin orelse {
        log.err("Cannot write to pkl server: child stdin is missing.", .{});
        return error.NoChildStdin;
    };
    defer {
        stdin.close(self.io);
        self.child.stdin = null;
        log.debug("Closed pkl server stdin.", .{});
    }

    while (true) {
        const data =
            self.outgoing.getOne(
                self.io,
            ) catch |err| switch (err) {
                error.Closed => {
                    log.debug("Outgoing queue closed.", .{});
                    break;
                },
                else => {
                    if (isStopping(self)) {
                        log.debug("Stopped waiting for outgoing frame during transport shutdown: {}.", .{err});
                    } else {
                        log.err("Failed to receive outgoing frame from queue: {}.", .{err});
                    }
                    return err;
                },
            };
        defer self.allocator.free(data);

        log.debug("Writing outgoing frame: {} bytes.", .{data.len});
        stdin.writeStreamingAll(
            self.io,
            data,
        ) catch |err| {
            if (isStopping(self)) {
                log.debug("Stopped writing outgoing frame during transport shutdown: {}.", .{err});
            } else {
                log.err("Failed to write outgoing frame: {}.", .{err});
            }
            return err;
        };
        log.debug("Wrote outgoing frame: {} bytes.", .{data.len});
    }
}

fn isStopping(self: *Transport) bool {
    return !self.started;
}
