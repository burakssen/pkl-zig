const std = @import("std");
const msgpack = @import("msgpack");
const message = @import("message");

const transport = @import("transport.zig");

const log = std.log.scoped(.@"pkl-zig|transport-libpkl");

pub const pkl_error_t = extern struct {
    message: ?[*:0]const u8 = null,
};

pub const pkl_exec_t = opaque {};

pub const pkl_message_response_handler = ?*const fn (
    length: c_uint,
    message: [*c]const u8,
    userData: ?*anyopaque,
) callconv(.c) void;

pub extern "c" fn pkl_init(
    handler: pkl_message_response_handler,
    userData: ?*anyopaque,
    exec: *?*pkl_exec_t,
    err: ?*pkl_error_t,
) c_int;

pub extern "c" fn pkl_send_message(
    exec: ?*const pkl_exec_t,
    length: c_uint,
    message: [*c]const u8,
    err: ?*pkl_error_t,
) c_int;

pub extern "c" fn pkl_close(
    exec: ?*pkl_exec_t,
    err: ?*pkl_error_t,
) c_int;

pub extern "c" fn pkl_version() [*c]const u8;

pub const LibPklTransport = struct {
    pub const queue_capacity = transport.queue_capacity;
    pub const IncomingEnvelope = transport.IncomingEnvelope;
    pub const Options = struct {
        pkl_argv: ?[]const []const u8 = null,
    };

    io: std.Io,
    allocator: std.mem.Allocator,
    exec: ?*pkl_exec_t = null,
    started: bool = false,

    incoming_pipe_read: std.Io.File,
    incoming_pipe_write_fd: std.posix.fd_t,

    outgoing_pipe_read_fd: std.posix.fd_t,
    outgoing_pipe_write_fd: std.posix.fd_t,

    group: std.Io.Group = .init,

    incoming_buffer: [queue_capacity]IncomingEnvelope = undefined,
    incoming: std.Io.Queue(IncomingEnvelope) = undefined,

    state_mutex: std.Io.Mutex = .init,
    send_mutex: std.Io.Mutex = .init,
    terminal_error: ?anyerror = null,

    // isolate-bound worker thread so pkl_init, pkl_send_message, and pkl_close
    // are strictly executed on the same OS thread satisfying GraalVM isolate constraints.
    worker_thread: ?std.Thread = null,
    init_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0), // 0: pending, 1: ok, 2: err

    pub fn init(io_handle: std.Io, allocator: std.mem.Allocator) !*LibPklTransport {
        return initWithOptions(io_handle, allocator, .{});
    }

    pub fn initWithOptions(
        io_handle: std.Io,
        allocator: std.mem.Allocator,
        options: Options,
    ) !*LibPklTransport {
        _ = options;
        log.info("Initializing libpkl C-ABI transport.", .{});

        const self = try allocator.create(LibPklTransport);
        errdefer allocator.destroy(self);

        var in_fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&in_fds) != 0) return error.PipeFailed;
        errdefer {
            _ = std.c.close(in_fds[0]);
            _ = std.c.close(in_fds[1]);
        }

        var out_fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&out_fds) != 0) return error.PipeFailed;
        errdefer {
            _ = std.c.close(out_fds[0]);
            _ = std.c.close(out_fds[1]);
        }

        self.* = .{
            .io = io_handle,
            .allocator = allocator,
            .exec = null,
            .started = false,
            .incoming_pipe_read = .{ .handle = in_fds[0], .flags = .{ .nonblocking = false } },
            .incoming_pipe_write_fd = in_fds[1],
            .outgoing_pipe_read_fd = out_fds[0],
            .outgoing_pipe_write_fd = out_fds[1],
            .incoming_buffer = undefined,
            .incoming = undefined,
        };
        self.incoming = .init(&self.incoming_buffer);

        // Spawn dedicated worker thread for isolate calls (pkl_init, pkl_send_message, pkl_close)
        const thread = try std.Thread.spawn(.{}, workerFn, .{self});
        self.worker_thread = thread;

        // Wait for pkl_init on worker thread
        while (self.init_state.load(.acquire) == 0) {
            std.Thread.yield() catch {};
        }

        if (self.init_state.load(.acquire) == 2) {
            self.deinit();
            return error.PklInitFailed;
        }

        log.info("Initialized libpkl C-ABI transport.", .{});
        return self;
    }

    pub fn deinit(self: *LibPklTransport) void {
        log.info("Deinitializing libpkl C-ABI transport.", .{});

        _ = self.setStarted(false);

        // Close outgoing pipe write end so worker thread gets EOF and exits
        if (self.outgoing_pipe_write_fd != -1) {
            _ = std.c.close(self.outgoing_pipe_write_fd);
            self.outgoing_pipe_write_fd = -1;
        }

        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }

        if (self.outgoing_pipe_read_fd != -1) {
            _ = std.c.close(self.outgoing_pipe_read_fd);
            self.outgoing_pipe_read_fd = -1;
        }

        // Close incoming pipe write fd so readLoop gets EOF
        if (self.incoming_pipe_write_fd != -1) {
            _ = std.c.close(self.incoming_pipe_write_fd);
            self.incoming_pipe_write_fd = -1;
        }

        self.incoming.close(self.io);
        self.group.cancel(self.io);

        self.incoming_pipe_read.close(self.io);

        self.drainIncoming();
        self.allocator.destroy(self);
        log.info("Deinitialized libpkl C-ABI transport.", .{});
    }

    pub fn start(self: *LibPklTransport) !void {
        if (self.isStarted()) {
            log.warn("LibPkl transport already started.", .{});
            return;
        }
        _ = self.setStarted(true);
        self.group.async(self.io, readTask, .{self});
    }

    pub fn send(self: *LibPklTransport, msg: message.Outgoing) !void {
        try self.send_mutex.lock(self.io);
        defer self.send_mutex.unlock(self.io);

        if (!self.isStarted()) {
            log.warn("Cannot send {s}: transport is not started.", .{@tagName(msg)});
            return error.NotStarted;
        }

        const data = try transport.encodeOutgoing(self.allocator, msg);
        defer self.allocator.free(data);

        // Write frame length followed by frame payload to outgoing pipe
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);

        _ = try self.writeAllFd(self.outgoing_pipe_write_fd, &len_buf);
        _ = try self.writeAllFd(self.outgoing_pipe_write_fd, data);
    }

    pub fn sendAndFlush(self: *LibPklTransport, msg: message.Outgoing) !void {
        // sending to worker thread over pipe is synchronously queued and dispatched
        try self.send(msg);
    }

    pub fn recv(self: *LibPklTransport) !IncomingEnvelope {
        if (!self.isStarted()) {
            log.warn("Cannot receive message: transport is not started.", .{});
            return error.NotStarted;
        }

        const envelope = self.incoming.getOne(self.io) catch |err| {
            return self.resolveQueueError(err);
        };
        return envelope;
    }

    fn workerFn(self: *LibPklTransport) void {
        var err: pkl_error_t = .{};
        var exec_ptr: ?*pkl_exec_t = null;

        const res = pkl_init(onMessageCallback, self, &exec_ptr, &err);
        if (res != 0 or exec_ptr == null) {
            if (err.message) |msg| {
                log.err("pkl_init failed: {s}", .{msg});
            }
            self.init_state.store(2, .release);
            return;
        }

        self.exec = exec_ptr;
        self.init_state.store(1, .release);

        // Loop reading outgoing frames from outgoing_pipe_read_fd
        var len_buf: [4]u8 = undefined;
        while (true) {
            if (!readAllFd(self.outgoing_pipe_read_fd, &len_buf)) break;
            const frame_len = std.mem.readInt(u32, &len_buf, .big);

            const frame_buf = self.allocator.alloc(u8, frame_len) catch break;
            defer self.allocator.free(frame_buf);

            if (!readAllFd(self.outgoing_pipe_read_fd, frame_buf)) break;

            var send_err: pkl_error_t = .{};
            const send_res = pkl_send_message(exec_ptr, @intCast(frame_buf.len), frame_buf.ptr, &send_err);
            if (send_res != 0) {
                if (send_err.message) |msg| {
                    log.err("pkl_send_message failed: {s}", .{msg});
                }
            }
        }

        var close_err: pkl_error_t = .{};
        _ = pkl_close(exec_ptr, &close_err);
        self.exec = null;
    }

    fn writeAllFd(_: *LibPklTransport, fd: std.posix.fd_t, buffer: []const u8) !void {
        var written: usize = 0;
        while (written < buffer.len) {
            const n = std.c.write(fd, buffer.ptr + written, buffer.len - written);
            if (n <= 0) return error.WriteFailed;
            written += @intCast(n);
        }
    }

    fn readAllFd(fd: std.posix.fd_t, buffer: []u8) bool {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = std.c.read(fd, buffer.ptr + total, buffer.len - total);
            if (n <= 0) return false;
            total += @intCast(n);
        }
        return true;
    }

    fn onMessageCallback(
        length: c_uint,
        raw_msg: [*c]const u8,
        userData: ?*anyopaque,
    ) callconv(.c) void {
        const self: *LibPklTransport = @ptrCast(@alignCast(userData orelse return));
        if (length == 0 or raw_msg == null) return;
        const slice = raw_msg[0..length];
        var written: usize = 0;
        while (written < slice.len) {
            const n = std.c.write(self.incoming_pipe_write_fd, slice.ptr + written, slice.len - written);
            if (n <= 0) break;
            written += @intCast(n);
        }
    }

    fn readTask(self: *LibPklTransport) std.Io.Cancelable!void {
        defer self.incoming.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var pipe_reader = self.incoming_pipe_read.reader(self.io, &read_buffer);
        const reader = &pipe_reader.interface;

        var write_buffer: [1]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&write_buffer);
        var packer = msgpack.PackerIO.init(reader, &writer);

        while (true) {
            var payload = packer.read(self.allocator) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    if (self.isStarted()) {
                        log.err("Failed to read incoming msgpack payload: {}.", .{err});
                    }
                    break;
                },
            };
            errdefer payload.free(self.allocator);

            const incoming_msg = message.Incoming.decode(self.allocator, &payload) catch |err| {
                log.err("Failed to decode incoming message: {}.", .{err});
                payload.free(self.allocator);
                break;
            };

            const close_after_put = incoming_msg == .close_external_process;
            self.incoming.putOne(self.io, .{
                .payload = payload,
                .msg = incoming_msg,
            }) catch break;

            if (close_after_put) break;
        }
    }

    pub fn drainIncoming(self: *LibPklTransport) void {
        var count: usize = 0;
        while (true) {
            var envelope = self.incoming.getOne(self.io) catch break;
            envelope.deinit(self.allocator);
            count += 1;
        }

        if (count > 0) {
            log.warn("Drained {} incoming queued messages.", .{count});
        }
    }

    pub fn isStarted(self: *LibPklTransport) bool {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.started;
    }

    pub fn setStarted(self: *LibPklTransport, started_val: bool) bool {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        const previous = self.started;
        self.started = started_val;
        return previous;
    }

    pub fn recordTerminalError(self: *LibPklTransport, err: anyerror) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        if (self.terminal_error == null) self.terminal_error = err;
    }

    pub fn terminalError(self: *LibPklTransport) ?anyerror {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.terminal_error;
    }

    pub fn resolveQueueError(self: *LibPklTransport, fallback: anyerror) anyerror {
        return self.terminalError() orelse fallback;
    }

    pub fn version() ?[]const u8 {
        const ver_ptr = pkl_version();
        if (ver_ptr == null) return null;
        return std.mem.span(ver_ptr);
    }
};

pub const Transport = LibPklTransport;
