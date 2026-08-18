const std = @import("std");

const message = @import("message");
const incoming = message.incoming;
const outgoing = message.outgoing;
const Transport = @import("transport");

const log = std.log.scoped(.@"pkl-zig|runtime");

/// Runtime owns the single receive loop for a pkl server process. Evaluators
/// submit requests independently; responses are routed by request ID while
/// logs and in-process reader callbacks are routed by evaluator ID.
pub const Runtime = @This();

pub const ResourceReader = struct {
    scheme: []const u8,
    has_hierarchical_uris: bool = false,
    is_globbable: bool = false,
    read: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]const u8,
    list_elements: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]const outgoing.PathElement = null,
    context: ?*anyopaque = null,
};

pub const ModuleReader = struct {
    scheme: []const u8,
    has_hierarchical_uris: bool = false,
    is_globbable: bool = false,
    is_local: bool = false,
    read: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]const u8,
    list_elements: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]const outgoing.PathElement = null,
    context: ?*anyopaque = null,
};

/// Optional evaluator-scoped Pkl log callback. The callback runs synchronously
/// on the runtime dispatcher and must not block or re-enter an evaluator that
/// shares this runtime.
pub const Logger = struct {
    context: ?*anyopaque = null,
    write: *const fn (
        ctx: ?*anyopaque,
        level: i32,
        message_text: []const u8,
        frame_uri: []const u8,
    ) void,
};

pub const RegistrationOptions = struct {
    resource_readers: []const ResourceReader = &.{},
    module_readers: []const ModuleReader = &.{},
    logger: ?Logger = null,
};

const Registration = struct {
    resource_readers: []ResourceReader,
    module_readers: []ModuleReader,
    logger: ?Logger,

    fn deinit(self: *Registration, allocator: std.mem.Allocator) void {
        for (self.resource_readers) |reader| allocator.free(reader.scheme);
        for (self.module_readers) |reader| allocator.free(reader.scheme);
        allocator.free(self.resource_readers);
        allocator.free(self.module_readers);
        allocator.destroy(self);
    }
};

fn dupeResourceReaders(allocator: std.mem.Allocator, readers: []const ResourceReader) ![]ResourceReader {
    const result = try allocator.alloc(ResourceReader, readers.len);
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |reader| allocator.free(reader.scheme);
    }
    for (readers, 0..) |reader, index| {
        const scheme = try allocator.dupe(u8, reader.scheme);
        result[index] = reader;
        result[index].scheme = scheme;
        initialized += 1;
    }
    return result;
}

fn dupeModuleReaders(allocator: std.mem.Allocator, readers: []const ModuleReader) ![]ModuleReader {
    const result = try allocator.alloc(ModuleReader, readers.len);
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |reader| allocator.free(reader.scheme);
    }
    for (readers, 0..) |reader, index| {
        const scheme = try allocator.dupe(u8, reader.scheme);
        result[index] = reader;
        result[index].scheme = scheme;
        initialized += 1;
    }
    return result;
}

const Completion = union(enum) {
    envelope: Transport.IncomingEnvelope,
    failure: anyerror,
};

const Pending = struct {
    buffer: [1]Completion = undefined,
    queue: std.Io.Queue(Completion) = undefined,
    completed: bool = false,

    fn init(self: *Pending) void {
        self.queue = .init(&self.buffer);
    }
};

io: std.Io,
allocator: std.mem.Allocator,
transport: *Transport,
owns_transport: bool,
dispatch_group: std.Io.Group = .init,
handler_group: std.Io.Group = .init,
state_mutex: std.Io.Mutex = .init,
refs: usize = 1,
accepting: bool = true,
closed_error: ?anyerror = null,
next_request_id: i64 = 1,
pending: std.AutoHashMap(i64, *Pending),
evaluators: std.AutoHashMap(i64, *Registration),

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Transport.Options,
) !*Runtime {
    const transport = try Transport.initWithOptions(io, allocator, options);
    errdefer transport.deinit();
    try transport.start();
    return initWithStartedTransport(io, allocator, transport, true);
}

/// Wrap an already-started transport. When `owns_transport` is false the
/// runtime only owns its dispatcher; the caller remains responsible for the
/// transport lifetime after all evaluator handles are deinitialized.
pub fn initWithStartedTransport(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *Transport,
    owns_transport: bool,
) !*Runtime {
    const self = try allocator.create(Runtime);
    errdefer allocator.destroy(self);

    self.* = .{
        .io = io,
        .allocator = allocator,
        .transport = transport,
        .owns_transport = owns_transport,
        .pending = std.AutoHashMap(i64, *Pending).init(allocator),
        .evaluators = std.AutoHashMap(i64, *Registration).init(allocator),
    };
    self.dispatch_group.async(io, dispatchTask, .{self});
    return self;
}

pub fn retain(self: *Runtime) !void {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    if (!self.accepting) return self.closed_error orelse error.ManagerClosed;
    self.refs += 1;
}

pub fn release(self: *Runtime) void {
    var _destroy = false;
    self.state_mutex.lockUncancelable(self.io);
    std.debug.assert(self.refs > 0);
    self.refs -= 1;
    _destroy = self.refs == 0;
    self.state_mutex.unlock(self.io);

    if (_destroy) self.destroy();
}

/// Prevents new requests while allowing already-started requests and evaluator
/// cleanup to drain. The transport remains alive until the last handle releases
/// the runtime, so manager shutdown cannot leave dangling transport pointers.
pub fn closeForManager(self: *Runtime) void {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    if (self.accepting) {
        self.accepting = false;
        self.closed_error = error.ManagerClosed;
    }
}

pub fn nextRequestId(self: *Runtime) !i64 {
    try self.state_mutex.lock(self.io);
    defer self.state_mutex.unlock(self.io);
    if (!self.accepting) return self.closed_error orelse error.ManagerClosed;

    const request_id = self.next_request_id;
    self.next_request_id = if (request_id == std.math.maxInt(i64)) 1 else request_id + 1;
    return request_id;
}

/// Registers the waiter before sending so even an immediate response cannot be
/// lost. Transport.send synchronously copies the outgoing message into an owned
/// frame, so all caller-owned slices may be released once this returns.
pub fn request(
    self: *Runtime,
    request_id: i64,
    msg: message.Outgoing,
) !Transport.IncomingEnvelope {
    var pending = Pending{};
    pending.init();

    try self.state_mutex.lock(self.io);
    if (!self.accepting) {
        const err = self.closed_error orelse error.ManagerClosed;
        self.state_mutex.unlock(self.io);
        return err;
    }
    self.pending.put(request_id, &pending) catch |err| {
        self.state_mutex.unlock(self.io);
        return err;
    };
    self.state_mutex.unlock(self.io);

    self.transport.send(msg) catch |err| {
        self.removePending(request_id);
        return err;
    };

    const completion = pending.queue.getOne(self.io) catch |err| {
        self.cancelPending(request_id, &pending);
        return self.transport.resolveQueueError(err);
    };
    self.removePending(request_id);
    return switch (completion) {
        .envelope => |envelope| envelope,
        .failure => |err| err,
    };
}

pub fn sendAndFlush(self: *Runtime, msg: message.Outgoing) !void {
    // CloseEvaluator remains legal after manager.close(): the retained runtime
    // keeps the process alive until evaluator handles are released.
    return self.transport.sendAndFlush(msg);
}

pub fn registerEvaluator(
    self: *Runtime,
    evaluator_id: i64,
    options: RegistrationOptions,
) !void {
    const registration = try self.allocator.create(Registration);
    errdefer self.allocator.destroy(registration);

    const resource_readers = try dupeResourceReaders(self.allocator, options.resource_readers);
    errdefer {
        for (resource_readers) |reader| self.allocator.free(reader.scheme);
        self.allocator.free(resource_readers);
    }
    const module_readers = try dupeModuleReaders(self.allocator, options.module_readers);
    errdefer {
        for (module_readers) |reader| self.allocator.free(reader.scheme);
        self.allocator.free(module_readers);
    }

    registration.* = .{
        .resource_readers = resource_readers,
        .module_readers = module_readers,
        .logger = options.logger,
    };

    try self.state_mutex.lock(self.io);
    defer self.state_mutex.unlock(self.io);
    if (self.evaluators.contains(evaluator_id)) return error.DuplicateEvaluatorId;
    try self.evaluators.put(evaluator_id, registration);
}

pub fn unregisterEvaluator(self: *Runtime, evaluator_id: i64) void {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    if (self.evaluators.fetchRemove(evaluator_id)) |entry| {
        entry.value.deinit(self.allocator);
    }
}

fn removePending(self: *Runtime, request_id: i64) void {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    _ = self.pending.remove(request_id);
}

fn cancelPending(self: *Runtime, request_id: i64, pending: *Pending) void {
    self.state_mutex.lockUncancelable(self.io);
    const removed = self.pending.fetchRemove(request_id);
    const completed = removed != null and pending.completed;
    self.state_mutex.unlock(self.io);

    // If the dispatcher won the race, it already placed an owned completion in
    // the one-slot queue. Drain it before the stack-backed Pending disappears.
    if (completed) {
        var buffer: [1]Completion = undefined;

        const count = pending.queue.getUncancelable(
            self.io,
            &buffer,
            1,
        ) catch |err| switch (err) {
            // This queue is local to Pending and is never explicitly closed.
            error.Closed => unreachable,
        };

        std.debug.assert(count == 1);

        switch (buffer[0]) {
            .envelope => |envelope_value| {
                var envelope = envelope_value;
                envelope.deinit(self.allocator);
            },
            .failure => {},
        }
    }
}

fn destroy(self: *Runtime) void {
    // Cancellation wakes the dispatcher if it is blocked in Transport.recv().
    self.dispatch_group.cancel(self.io);
    self.handler_group.cancel(self.io);

    self.state_mutex.lockUncancelable(self.io);
    var registrations = self.evaluators.valueIterator();
    while (registrations.next()) |registration| registration.*.deinit(self.allocator);
    self.evaluators.clearRetainingCapacity();
    self.state_mutex.unlock(self.io);

    self.pending.deinit();
    self.evaluators.deinit();
    if (self.owns_transport) self.transport.deinit();
    self.allocator.destroy(self);
}

fn dispatchTask(self: *Runtime) void {
    while (true) {
        var envelope = self.transport.recv() catch |err| {
            self.failRuntime(self.transport.resolveQueueError(err));
            return;
        };
        var routed = false;

        switch (envelope.msg) {
            .create_evaluator_response => |response| {
                routed = self.routeResponse(response.request_id, &envelope) catch |err| {
                    self.failRuntime(err);
                    envelope.deinit(self.allocator);
                    return;
                };
            },
            .evaluate_response => |response| {
                routed = self.routeResponse(response.request_id, &envelope) catch |err| {
                    self.failRuntime(err);
                    envelope.deinit(self.allocator);
                    return;
                };
            },
            .log => |entry| self.handleLog(entry),
            .read_resource => {
                const owned = envelope;
                envelope = undefined;
                routed = true;
                self.handler_group.async(self.io, handleReadResourceTask, .{ self, owned });
            },
            .read_module => {
                const owned = envelope;
                envelope = undefined;
                routed = true;
                self.handler_group.async(self.io, handleReadModuleTask, .{ self, owned });
            },
            .list_resources => {
                const owned = envelope;
                envelope = undefined;
                routed = true;
                self.handler_group.async(self.io, handleListResourcesTask, .{ self, owned });
            },
            .list_modules => {
                const owned = envelope;
                envelope = undefined;
                routed = true;
                self.handler_group.async(self.io, handleListModulesTask, .{ self, owned });
            },
            .close_external_process => {
                envelope.deinit(self.allocator);
                self.failRuntime(error.ExternalProcessClosed);
                return;
            },
            .initialize_module_reader, .initialize_resource_reader => {
                log.warn("External reader initialization is not handled by the in-process runtime.", .{});
            },
        }

        if (!routed) envelope.deinit(self.allocator);
    }
}

fn routeResponse(
    self: *Runtime,
    request_id: i64,
    envelope: *Transport.IncomingEnvelope,
) !bool {
    try self.state_mutex.lock(self.io);
    defer self.state_mutex.unlock(self.io);

    const pending = self.pending.get(request_id) orelse {
        log.warn("Dropping response for unknown request id {}.", .{request_id});
        return false;
    };
    if (pending.completed) return false;

    try pending.queue.putOne(self.io, .{ .envelope = envelope.* });
    pending.completed = true;
    envelope.* = undefined;
    return true;
}

fn failRuntime(self: *Runtime, err: anyerror) void {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);

    self.accepting = false;
    if (self.closed_error == null) self.closed_error = err;

    var iterator = self.pending.valueIterator();
    while (iterator.next()) |pending_ptr| {
        const pending = pending_ptr.*;
        if (pending.completed) continue;
        pending.queue.putOne(self.io, .{ .failure = err }) catch continue;
        pending.completed = true;
    }
}

fn uriScheme(uri: []const u8) ?[]const u8 {
    const index = std.mem.indexOfScalar(u8, uri, ':') orelse return null;
    return uri[0..index];
}

fn findResourceReader(registration: *const Registration, uri: []const u8) ?ResourceReader {
    const scheme = uriScheme(uri) orelse return null;
    for (registration.resource_readers) |reader| {
        if (std.mem.eql(u8, reader.scheme, scheme)) return reader;
    }
    return null;
}

fn findModuleReader(registration: *const Registration, uri: []const u8) ?ModuleReader {
    const scheme = uriScheme(uri) orelse return null;
    for (registration.module_readers) |reader| {
        if (std.mem.eql(u8, reader.scheme, scheme)) return reader;
    }
    return null;
}

fn handleLog(self: *Runtime, entry: incoming.Log) void {
    var logger: ?Logger = null;
    self.state_mutex.lockUncancelable(self.io);
    if (self.evaluators.get(entry.evaluator_id)) |registration| logger = registration.logger;
    self.state_mutex.unlock(self.io);

    if (logger) |callback| {
        callback.write(callback.context, entry.level, entry.message, entry.frame_uri);
        return;
    }

    switch (entry.level) {
        0 => log.debug("Pkl: {s} ({s})", .{ entry.message, entry.frame_uri }),
        1 => log.warn("Pkl: {s} ({s})", .{ entry.message, entry.frame_uri }),
        else => log.info("Pkl: {s} ({s})", .{ entry.message, entry.frame_uri }),
    }
}

fn resourceReader(self: *Runtime, evaluator_id: i64, uri: []const u8) ?ResourceReader {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    const registration = self.evaluators.get(evaluator_id) orelse return null;
    return findResourceReader(registration, uri);
}

fn moduleReader(self: *Runtime, evaluator_id: i64, uri: []const u8) ?ModuleReader {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    const registration = self.evaluators.get(evaluator_id) orelse return null;
    return findModuleReader(registration, uri);
}

fn handleReadResourceTask(self: *Runtime, envelope: Transport.IncomingEnvelope) void {
    var owned = envelope;
    defer owned.deinit(self.allocator);
    const req = switch (owned.msg) {
        .read_resource => |request_msg| request_msg,
        else => return,
    };
    self.handleReadResource(req) catch |err| {
        log.warn("Failed to answer resource reader request: {}.", .{err});
    };
}

fn handleReadModuleTask(self: *Runtime, envelope: Transport.IncomingEnvelope) void {
    var owned = envelope;
    defer owned.deinit(self.allocator);
    const req = switch (owned.msg) {
        .read_module => |request_msg| request_msg,
        else => return,
    };
    self.handleReadModule(req) catch |err| {
        log.warn("Failed to answer module reader request: {}.", .{err});
    };
}

fn handleListResourcesTask(self: *Runtime, envelope: Transport.IncomingEnvelope) void {
    var owned = envelope;
    defer owned.deinit(self.allocator);
    const req = switch (owned.msg) {
        .list_resources => |request_msg| request_msg,
        else => return,
    };
    self.handleListResources(req) catch |err| {
        log.warn("Failed to answer resource listing request: {}.", .{err});
    };
}

fn handleListModulesTask(self: *Runtime, envelope: Transport.IncomingEnvelope) void {
    var owned = envelope;
    defer owned.deinit(self.allocator);
    const req = switch (owned.msg) {
        .list_modules => |request_msg| request_msg,
        else => return,
    };
    self.handleListModules(req) catch |err| {
        log.warn("Failed to answer module listing request: {}.", .{err});
    };
}

fn handleReadResource(self: *Runtime, req: incoming.ReadResource) !void {
    const reader = self.resourceReader(req.evaluator_id, req.uri) orelse {
        try self.transport.send(.{ .read_resource_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .@"error" = "No resource reader registered for URI scheme",
        } });
        return;
    };

    // Reader-owned allocations are request scoped. Transport.send encodes the
    // response into an owned frame before returning, so the arena can be freed
    // immediately afterwards, including nested PathElement names.
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    if (reader.read(reader.context, arena.allocator(), req.uri)) |contents| {
        try self.transport.send(.{ .read_resource_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .contents = contents,
        } });
    } else |err| {
        try self.transport.send(.{ .read_resource_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .@"error" = @errorName(err),
        } });
    }
}

fn handleReadModule(self: *Runtime, req: incoming.ReadModule) !void {
    const reader = self.moduleReader(req.evaluator_id, req.uri) orelse {
        try self.transport.send(.{ .read_module_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .@"error" = "No module reader registered for URI scheme",
        } });
        return;
    };

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    if (reader.read(reader.context, arena.allocator(), req.uri)) |contents| {
        try self.transport.send(.{ .read_module_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .contents = contents,
        } });
    } else |err| {
        try self.transport.send(.{ .read_module_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .@"error" = @errorName(err),
        } });
    }
}

fn handleListResources(self: *Runtime, req: incoming.ListResources) !void {
    const reader = self.resourceReader(req.evaluator_id, req.uri) orelse {
        try self.transport.send(.{ .list_resources_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .@"error" = "No resource reader registered for URI scheme",
        } });
        return;
    };
    const list = reader.list_elements orelse {
        try self.transport.send(.{ .list_resources_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .@"error" = "Resource reader does not support listing elements",
        } });
        return;
    };

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    if (list(reader.context, arena.allocator(), req.uri)) |elements| {
        try self.transport.send(.{ .list_resources_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .path_elements = elements,
        } });
    } else |err| {
        try self.transport.send(.{ .list_resources_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .@"error" = @errorName(err),
        } });
    }
}

fn handleListModules(self: *Runtime, req: incoming.ListModules) !void {
    const reader = self.moduleReader(req.evaluator_id, req.uri) orelse {
        try self.transport.send(.{ .list_modules_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .@"error" = "No module reader registered for URI scheme",
        } });
        return;
    };
    const list = reader.list_elements orelse {
        try self.transport.send(.{ .list_modules_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .@"error" = "Module reader does not support listing elements",
        } });
        return;
    };

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    if (list(reader.context, arena.allocator(), req.uri)) |elements| {
        try self.transport.send(.{ .list_modules_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .path_elements = elements,
        } });
    } else |err| {
        try self.transport.send(.{ .list_modules_response = .{
            .request_id = req.request_id,
            .evaluator_id = req.evaluator_id,
            .@"error" = @errorName(err),
        } });
    }
}
