const std = @import("std");

const message = @import("message");
const incoming = message.incoming;
const outgoing = message.outgoing;
const Transport = @import("transport");
const value = @import("value.zig");
const log = std.log.scoped(.@"pkl-zig|evaluator");

const Evaluator = @This();

// Simple function-pointer vtables instead of dynamic interface abstractions.

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

pub const Options = struct {
    pkl_argv: []const []const u8 = &.{ "pkl", "server" },
    allowed_modules: ?[]const []const u8 = &.{
        "pkl:",
        "repl:",
        "file:",
        "http:",
        "https:",
        "modulepath:",
        "package:",
        "projectpackage:",
    },
    allowed_resources: ?[]const []const u8 = &.{
        "http:",
        "https:",
        "file:",
        "env:",
        "prop:",
        "modulepath:",
        "package:",
        "projectpackage:",
    },
    module_paths: ?[]const []const u8 = null,
    env: ?std.StringHashMap([]const u8) = null,
    properties: ?std.StringHashMap([]const u8) = null,
    timeout_seconds: ?i64 = null,
    root_dir: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    project: ?*outgoing.Project = null,
    http: ?*outgoing.Http = null,
    external_module_readers: ?std.StringHashMap(outgoing.ExternalReader) = null,
    external_resource_readers: ?std.StringHashMap(outgoing.ExternalReader) = null,
    resource_readers: ?[]const ResourceReader = null,
    module_readers: ?[]const ModuleReader = null,
    trace_mode: ?[]const u8 = null,

    /// A conservative preset for evaluating content that should not be able to
    /// read local files, packages, project packages, or the network.
    pub fn restricted() Options {
        return .{
            .allowed_modules = &.{ "pkl:", "repl:" },
            .allowed_resources = &.{},
        };
    }
};

io: std.Io,
allocator: std.mem.Allocator,
transport: ?*Transport,
owns_transport: bool = true,
evaluator_id: i64,
next_request_id: i64,
resource_readers: []const ResourceReader = &.{},
module_readers: []const ModuleReader = &.{},
request_mutex: ?*std.Io.Mutex = null,
local_mutex: std.Io.Mutex = .init,
last_error: ?[]u8 = null,

fn mutex(self: *Evaluator) *std.Io.Mutex {
    return self.request_mutex orelse &self.local_mutex;
}

pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !Evaluator {
    const transport = try Transport.initWithOptions(io, allocator, .{ .pkl_argv = options.pkl_argv });
    errdefer transport.deinit();

    try transport.start();

    var self = Evaluator{
        .io = io,
        .allocator = allocator,
        .transport = transport,
        .owns_transport = true,
        .evaluator_id = 0,
        .next_request_id = 1,
        .resource_readers = options.resource_readers orelse &.{},
        .module_readers = options.module_readers orelse &.{},
        .request_mutex = null,
    };
    errdefer self.clearLastErrorUnlocked();

    self.evaluator_id = try self.createUnlocked(options);
    return self;
}

pub fn initWithTransport(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *Transport,
    shared_mutex: ?*std.Io.Mutex,
    options: Options,
) !Evaluator {
    var self = Evaluator{
        .io = io,
        .allocator = allocator,
        .transport = transport,
        .owns_transport = false,
        .evaluator_id = 0,
        .next_request_id = 1,
        .resource_readers = options.resource_readers orelse &.{},
        .module_readers = options.module_readers orelse &.{},
        .request_mutex = shared_mutex,
    };
    errdefer self.clearLastErrorUnlocked();

    self.evaluator_id = try self.createUnlocked(options);
    return self;
}

/// Deinitialization is idempotent with respect to an earlier explicit close().
pub fn deinit(self: *Evaluator) void {
    self.close() catch |err| {
        log.warn("Failed to close evaluator {} cleanly: {}.", .{ self.evaluator_id, err });
    };
    self.clearLastErrorUnlocked();
}

/// Send Pkl's one-way CloseEvaluator message and wait until the transport's
/// writer has written that frame before tearing down the child process.
pub fn close(self: *Evaluator) !void {
    try self.mutex().lock(self.io);
    defer self.mutex().unlock(self.io);

    const transport = self.transport orelse return;

    // Make the state closed before doing any fallible work. Even when flushing
    // the close frame fails, no later operation may dereference this transport.
    self.transport = null;
    defer if (self.owns_transport) transport.deinit();

    try transport.sendAndFlush(.{
        .close_evaluator = .{ .evaluator_id = self.evaluator_id },
    });
}

/// Returns the last diagnostic received from Pkl. The slice is owned by the
/// evaluator and remains valid until the next request or deinit().
pub fn lastError(self: *const Evaluator) ?[]const u8 {
    return self.last_error;
}

pub fn evaluateModuleRaw(self: *Evaluator, module_uri: []const u8) ![]u8 {
    return self.evaluateExpressionRaw(module_uri, null);
}

/// Evaluations are intentionally serialized. The message-passing protocol
/// permits multiple in-flight request IDs, but a shared receive queue requires
/// a dispatcher to support that safely. Serializing here prevents one caller
/// from consuming and destroying another caller's response.
pub fn evaluateExpressionRaw(
    self: *Evaluator,
    module_uri: []const u8,
    expr: ?[]const u8,
) ![]u8 {
    try self.mutex().lock(self.io);
    defer self.mutex().unlock(self.io);

    self.clearLastErrorUnlocked();
    const transport = self.transport orelse return error.EvaluatorClosed;
    const request_id = self.nextRequestIdUnlocked();

    try transport.send(.{ .evaluate = .{
        .request_id = request_id,
        .evaluator_id = self.evaluator_id,
        .module_uri = module_uri,
        .expr = expr,
    } });

    while (true) {
        var envelope = try transport.recv();
        defer envelope.deinit(self.allocator);

        switch (envelope.msg) {
            .evaluate_response => |response| {
                if (response.request_id != request_id) return error.UnexpectedResponseId;
                if (response.evaluator_id != self.evaluator_id) return error.UnexpectedEvaluatorId;

                if (response.@"error") |diagnostic| {
                    try self.setLastErrorUnlocked(diagnostic);
                    return error.EvaluateFailed;
                }

                const result = response.result orelse return error.MissingEvaluateResult;
                return self.allocator.dupe(u8, result);
            },
            .log => |entry| {
                if (entry.evaluator_id != self.evaluator_id) return error.UnexpectedEvaluatorId;
                switch (entry.level) {
                    0 => log.debug("Pkl: {s} ({s})", .{ entry.message, entry.frame_uri }),
                    1 => log.warn("Pkl: {s} ({s})", .{ entry.message, entry.frame_uri }),
                    else => log.info("Pkl: {s} ({s})", .{ entry.message, entry.frame_uri }),
                }
            },
            .read_resource => |req| {
                if (req.evaluator_id != self.evaluator_id) return error.UnexpectedEvaluatorId;
                try self.handleReadResource(transport, req);
            },
            .read_module => |req| {
                if (req.evaluator_id != self.evaluator_id) return error.UnexpectedEvaluatorId;
                try self.handleReadModule(transport, req);
            },
            .list_resources => |req| {
                if (req.evaluator_id != self.evaluator_id) return error.UnexpectedEvaluatorId;
                try self.handleListResources(transport, req);
            },
            .list_modules => |req| {
                if (req.evaluator_id != self.evaluator_id) return error.UnexpectedEvaluatorId;
                try self.handleListModules(transport, req);
            },
            .close_external_process => return error.ExternalProcessClosed,
            else => return error.UnexpectedMessage,
        }
    }
}

pub fn loadFromPath(
    self: *Evaluator,
    comptime T: type,
    path: []const u8,
) !T {
    const uri = try fileUriFromPath(self.io, self.allocator, path);
    defer self.allocator.free(uri);
    return self.load(T, uri);
}

pub fn load(self: *Evaluator, comptime T: type, module_uri: []const u8) !T {
    const bytes = try self.evaluateModuleRaw(module_uri);
    defer self.allocator.free(bytes);
    return value.decodeInto(T, self.allocator, bytes);
}

fn createUnlocked(self: *Evaluator, options: Options) !i64 {
    try self.mutex().lock(self.io);
    defer self.mutex().unlock(self.io);

    self.clearLastErrorUnlocked();
    const transport = self.transport orelse return error.EvaluatorClosed;
    const request_id = self.nextRequestIdUnlocked();

    var client_resource_readers: ?[]outgoing.ResourceReader = null;
    if (options.resource_readers) |readers| {
        const out_readers = try self.allocator.alloc(outgoing.ResourceReader, readers.len);
        for (readers, 0..) |r, i| {
            out_readers[i] = .{
                .scheme = r.scheme,
                .has_hierarchical_uris = r.has_hierarchical_uris,
                .is_globbable = r.is_globbable,
            };
        }
        client_resource_readers = out_readers;
    }
    defer if (client_resource_readers) |r| self.allocator.free(r);

    var client_module_readers: ?[]outgoing.ModuleReader = null;
    if (options.module_readers) |readers| {
        const out_readers = try self.allocator.alloc(outgoing.ModuleReader, readers.len);
        for (readers, 0..) |r, i| {
            out_readers[i] = .{
                .scheme = r.scheme,
                .has_hierarchical_uris = r.has_hierarchical_uris,
                .is_globbable = r.is_globbable,
                .is_local = r.is_local,
            };
        }
        client_module_readers = out_readers;
    }
    defer if (client_module_readers) |r| self.allocator.free(r);

    try transport.send(.{ .create_evaluator = .{
        .request_id = request_id,
        .client_resource_readers = client_resource_readers,
        .client_module_readers = client_module_readers,
        .allowed_modules = options.allowed_modules,
        .allowed_resources = options.allowed_resources,
        .module_paths = options.module_paths,
        .env = options.env,
        .properties = options.properties,
        .timeout_seconds = options.timeout_seconds,
        .root_dir = options.root_dir,
        .cache_dir = options.cache_dir,
        .output_format = options.output_format,
        .project = options.project,
        .http = options.http,
        .external_module_readers = options.external_module_readers,
        .external_resource_readers = options.external_resource_readers,
        .trace_mode = options.trace_mode,
    } });

    while (true) {
        var envelope = try transport.recv();
        defer envelope.deinit(self.allocator);

        switch (envelope.msg) {
            .create_evaluator_response => |response| {
                if (response.request_id != request_id) return error.UnexpectedResponseId;

                if (response.@"error") |diagnostic| {
                    try self.setLastErrorUnlocked(diagnostic);
                    return error.CreateEvaluatorFailed;
                }

                return response.evaluator_id orelse error.MissingEvaluatorId;
            },
            .log => {},
            .close_external_process => return error.ExternalProcessClosed,
            else => return error.UnexpectedMessage,
        }
    }
}

fn uriScheme(uri: []const u8) ?[]const u8 {
    const idx = std.mem.indexOfScalar(u8, uri, ':') orelse return null;
    return uri[0..idx];
}

fn findResourceReader(self: *const Evaluator, uri: []const u8) ?ResourceReader {
    const scheme = uriScheme(uri) orelse return null;
    for (self.resource_readers) |reader| {
        if (std.mem.eql(u8, reader.scheme, scheme)) return reader;
    }
    return null;
}

fn findModuleReader(self: *const Evaluator, uri: []const u8) ?ModuleReader {
    const scheme = uriScheme(uri) orelse return null;
    for (self.module_readers) |reader| {
        if (std.mem.eql(u8, reader.scheme, scheme)) return reader;
    }
    return null;
}

fn handleReadResource(self: *Evaluator, transport: *Transport, req: incoming.ReadResource) !void {
    const reader = self.findResourceReader(req.uri) orelse {
        try transport.send(.{ .read_resource_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .@"error" = "No resource reader registered for URI scheme",
        } });
        return;
    };

    if (reader.read(reader.context, self.allocator, req.uri)) |contents| {
        try transport.send(.{ .read_resource_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .contents = contents,
        } });
    } else |err| {
        try transport.send(.{ .read_resource_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .@"error" = @errorName(err),
        } });
    }
}

fn handleReadModule(self: *Evaluator, transport: *Transport, req: incoming.ReadModule) !void {
    const reader = self.findModuleReader(req.uri) orelse {
        try transport.send(.{ .read_module_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .@"error" = "No module reader registered for URI scheme",
        } });
        return;
    };

    if (reader.read(reader.context, self.allocator, req.uri)) |contents| {
        try transport.send(.{ .read_module_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .contents = contents,
        } });
    } else |err| {
        try transport.send(.{ .read_module_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .@"error" = @errorName(err),
        } });
    }
}

fn handleListResources(self: *Evaluator, transport: *Transport, req: incoming.ListResources) !void {
    const reader = self.findResourceReader(req.uri) orelse {
        try transport.send(.{ .list_resources_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .@"error" = "No resource reader registered for URI scheme",
        } });
        return;
    };

    const list_fn = reader.list_elements orelse {
        try transport.send(.{ .list_resources_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .@"error" = "Resource reader does not support listing elements",
        } });
        return;
    };

    if (list_fn(reader.context, self.allocator, req.uri)) |elements| {
        try transport.send(.{ .list_resources_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .path_elements = elements,
        } });
    } else |err| {
        try transport.send(.{ .list_resources_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .@"error" = @errorName(err),
        } });
    }
}

fn handleListModules(self: *Evaluator, transport: *Transport, req: incoming.ListModules) !void {
    const reader = self.findModuleReader(req.uri) orelse {
        try transport.send(.{ .list_modules_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .@"error" = "No module reader registered for URI scheme",
        } });
        return;
    };

    const list_fn = reader.list_elements orelse {
        try transport.send(.{ .list_modules_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .@"error" = "Module reader does not support listing elements",
        } });
        return;
    };

    if (list_fn(reader.context, self.allocator, req.uri)) |elements| {
        try transport.send(.{ .list_modules_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .path_elements = elements,
        } });
    } else |err| {
        try transport.send(.{ .list_modules_response = .{
            .request_id = req.request_id,
            .evaluator_id = self.evaluator_id,
            .@"error" = @errorName(err),
        } });
    }
}

fn nextRequestIdUnlocked(self: *Evaluator) i64 {
    const request_id = self.next_request_id;
    self.next_request_id = if (self.next_request_id == std.math.maxInt(i64))
        1
    else
        self.next_request_id + 1;
    return request_id;
}

fn clearLastErrorUnlocked(self: *Evaluator) void {
    if (self.last_error) |diagnostic| self.allocator.free(diagnostic);
    self.last_error = null;
}

fn setLastErrorUnlocked(self: *Evaluator, diagnostic: []const u8) !void {
    self.clearLastErrorUnlocked();
    self.last_error = try self.allocator.dupe(u8, diagnostic);
}

pub fn fileUriFromPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "file:")) return allocator.dupe(u8, path);

    const absolute_path = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, path });
    };
    defer allocator.free(absolute_path);

    return fileUriFromAbsolutePath(allocator, absolute_path);
}

fn fileUriFromAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const encoded_path = try percentEncodeFilePath(allocator, path);
    defer allocator.free(encoded_path);

    // UNC: \\server\share\a.pkl -> file://server/share/a.pkl
    if (std.mem.startsWith(u8, encoded_path, "//")) {
        return std.fmt.allocPrint(allocator, "file:{s}", .{encoded_path});
    }

    // Windows drive: C:\dir\a.pkl -> file:///C:/dir/a.pkl
    if (isWindowsDrivePath(encoded_path)) {
        return std.fmt.allocPrint(allocator, "file:///{s}", .{encoded_path});
    }

    // POSIX absolute paths begin with '/', so this naturally produces three
    // slashes: file:// + /tmp/a.pkl = file:///tmp/a.pkl.
    if (std.mem.startsWith(u8, encoded_path, "/")) {
        return std.fmt.allocPrint(allocator, "file://{s}", .{encoded_path});
    }

    return error.ExpectedAbsolutePath;
}

fn percentEncodeFilePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(allocator);

    const hex = "0123456789ABCDEF";
    for (path) |raw_ch| {
        const ch: u8 = if (raw_ch == '\\') '/' else raw_ch;
        if (isUnescapedPathChar(ch)) {
            try encoded.append(allocator, ch);
            continue;
        }

        try encoded.append(allocator, '%');
        try encoded.append(allocator, hex[ch >> 4]);
        try encoded.append(allocator, hex[ch & 0x0f]);
    }

    return encoded.toOwnedSlice(allocator);
}

fn isUnescapedPathChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or
        ch == '-' or
        ch == '_' or
        ch == '.' or
        ch == '~' or
        ch == '/' or
        ch == ':';
}

fn isWindowsDrivePath(path: []const u8) bool {
    return path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        path[2] == '/';
}

test "fileUriFromPath keeps file URI unchanged" {
    const allocator = std.testing.allocator;
    const uri = try fileUriFromPath(std.testing.io, allocator, "file:///tmp/config.pkl");
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("file:///tmp/config.pkl", uri);
}

test "fileUriFromPath preserves absolute POSIX path and encodes spaces" {
    const allocator = std.testing.allocator;

    const uri = try fileUriFromAbsolutePath(allocator, "/tmp/My Config.pkl");
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("file:///tmp/My%20Config.pkl", uri);
}

test "file URI helper handles Windows drive path" {
    const allocator = std.testing.allocator;

    const uri = try fileUriFromAbsolutePath(allocator, "C:\\Users\\Burak\\My Config.pkl");
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("file:///C:/Users/Burak/My%20Config.pkl", uri);
}

test "file URI helper handles Windows UNC path" {
    const allocator = std.testing.allocator;

    const uri = try fileUriFromAbsolutePath(allocator, "\\\\server\\share\\My Config.pkl");
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("file://server/share/My%20Config.pkl", uri);
}

test "fileUriFromPath resolves relative path against cwd" {
    const allocator = std.testing.allocator;

    const uri = try fileUriFromPath(std.testing.io, allocator, "config/My File.pkl");
    defer allocator.free(uri);

    try std.testing.expect(std.mem.startsWith(u8, uri, "file:///"));
    try std.testing.expect(std.mem.endsWith(u8, uri, "/config/My%20File.pkl"));
}
