const std = @import("std");

const message = @import("message");
const outgoing = message.outgoing;
const Transport = @import("transport");
const Runtime = @import("runtime.zig");
const value = @import("value.zig");
const log = std.log.scoped(.@"pkl-zig|evaluator");

const Evaluator = @This();

pub const ResourceReader = Runtime.ResourceReader;
pub const ModuleReader = Runtime.ModuleReader;
pub const Logger = Runtime.Logger;

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
    logger: ?Logger = null,
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
runtime: ?*Runtime,
evaluator_id: i64,
local_mutex: std.Io.Mutex = .init,
closed: bool = false,
last_error: ?[]u8 = null,

pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !Evaluator {
    const runtime = try Runtime.init(io, allocator, .{ .pkl_argv = options.pkl_argv });
    return initWithOwnedRuntime(io, allocator, runtime, options);
}

/// Compatibility entry point for callers that already own a started Transport.
/// The evaluator owns the dispatcher wrapper, but not the transport itself.
/// Sharing one Transport between evaluators now requires EvaluatorManager so
/// there is exactly one receive dispatcher for that process.
pub fn initWithTransport(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *Transport,
    shared_mutex: ?*std.Io.Mutex,
    options: Options,
) !Evaluator {
    if (shared_mutex != null) return error.SharedTransportRequiresManager;
    const runtime = try Runtime.initWithStartedTransport(io, allocator, transport, false);
    return initWithOwnedRuntime(io, allocator, runtime, options);
}

/// Consumes one retained runtime reference. EvaluatorManager uses this to
/// create independent evaluator handles on its shared pkl server process.
pub fn initWithRuntime(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    options: Options,
) !Evaluator {
    return initWithOwnedRuntime(io, allocator, runtime, options);
}

fn initWithOwnedRuntime(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    options: Options,
) !Evaluator {
    var self = Evaluator{
        .io = io,
        .allocator = allocator,
        .runtime = runtime,
        .evaluator_id = 0,
    };
    errdefer runtime.release();
    errdefer self.clearLastErrorUnlocked();

    self.evaluator_id = try self.createUnlocked(options);
    errdefer runtime.sendAndFlush(.{
        .close_evaluator = .{ .evaluator_id = self.evaluator_id },
    }) catch {};

    try runtime.registerEvaluator(self.evaluator_id, .{
        .resource_readers = options.resource_readers orelse &.{},
        .module_readers = options.module_readers orelse &.{},
        .logger = options.logger,
    });
    return self;
}

/// Deinitialization is idempotent with respect to an earlier explicit close().
pub fn deinit(self: *Evaluator) void {
    self.close() catch |err| {
        log.warn("Failed to close evaluator {} cleanly: {}.", .{ self.evaluator_id, err });
    };
    self.clearLastErrorUnlocked();
}

/// Close this evaluator. Manager shutdown may happen first; the evaluator keeps
/// the shared runtime alive long enough to send its CloseEvaluator frame safely,
/// then releases that runtime reference immediately.
pub fn close(self: *Evaluator) !void {
    try self.local_mutex.lock(self.io);
    defer self.local_mutex.unlock(self.io);

    if (self.closed) return;
    self.closed = true;

    const runtime = self.runtime orelse return;
    self.runtime = null;
    defer runtime.release();

    runtime.unregisterEvaluator(self.evaluator_id);
    try runtime.sendAndFlush(.{
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

/// Calls on one evaluator remain serialized so lastError and evaluator-local
/// state stay simple. Different evaluators sharing a manager may execute
/// concurrently because Runtime dispatches responses by request ID.
pub fn evaluateExpressionRaw(
    self: *Evaluator,
    module_uri: []const u8,
    expr: ?[]const u8,
) ![]u8 {
    try self.local_mutex.lock(self.io);
    defer self.local_mutex.unlock(self.io);

    if (self.closed) return error.EvaluatorClosed;
    self.clearLastErrorUnlocked();
    const runtime = self.runtime orelse return error.EvaluatorClosed;
    const request_id = try runtime.nextRequestId();

    var envelope = try runtime.request(request_id, .{ .evaluate = .{
        .request_id = request_id,
        .evaluator_id = self.evaluator_id,
        .module_uri = module_uri,
        .expr = expr,
    } });
    defer envelope.deinit(self.allocator);

    return switch (envelope.msg) {
        .evaluate_response => |response| blk: {
            if (response.request_id != request_id) return error.UnexpectedResponseId;
            if (response.evaluator_id != self.evaluator_id) return error.UnexpectedEvaluatorId;
            if (response.@"error") |diagnostic| {
                try self.setLastErrorUnlocked(diagnostic);
                return error.EvaluateFailed;
            }
            const result = response.result orelse return error.MissingEvaluateResult;
            break :blk try self.allocator.dupe(u8, result);
        },
        else => error.UnexpectedMessage,
    };
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
    self.clearLastErrorUnlocked();
    const runtime = self.runtime orelse return error.EvaluatorClosed;
    const request_id = try runtime.nextRequestId();

    var client_resource_readers: ?[]outgoing.ResourceReader = null;
    if (options.resource_readers) |readers| {
        const out_readers = try self.allocator.alloc(outgoing.ResourceReader, readers.len);
        for (readers, 0..) |reader, index| {
            out_readers[index] = .{
                .scheme = reader.scheme,
                .has_hierarchical_uris = reader.has_hierarchical_uris,
                .is_globbable = reader.is_globbable,
            };
        }
        client_resource_readers = out_readers;
    }
    defer if (client_resource_readers) |readers| self.allocator.free(readers);

    var client_module_readers: ?[]outgoing.ModuleReader = null;
    if (options.module_readers) |readers| {
        const out_readers = try self.allocator.alloc(outgoing.ModuleReader, readers.len);
        for (readers, 0..) |reader, index| {
            out_readers[index] = .{
                .scheme = reader.scheme,
                .has_hierarchical_uris = reader.has_hierarchical_uris,
                .is_globbable = reader.is_globbable,
                .is_local = reader.is_local,
            };
        }
        client_module_readers = out_readers;
    }
    defer if (client_module_readers) |readers| self.allocator.free(readers);

    var envelope = try runtime.request(request_id, .{ .create_evaluator = .{
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
    defer envelope.deinit(self.allocator);

    return switch (envelope.msg) {
        .create_evaluator_response => |response| blk: {
            if (response.request_id != request_id) return error.UnexpectedResponseId;
            if (response.@"error") |diagnostic| {
                try self.setLastErrorUnlocked(diagnostic);
                return error.CreateEvaluatorFailed;
            }
            break :blk response.evaluator_id orelse error.MissingEvaluatorId;
        },
        else => error.UnexpectedMessage,
    };
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
