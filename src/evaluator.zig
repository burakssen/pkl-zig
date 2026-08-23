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

pub const ModuleSource = struct {
    uri: []const u8,
    text: ?[]const u8 = null,

    pub fn fromUri(uri: []const u8) ModuleSource {
        return .{ .uri = uri };
    }

    pub fn fromText(text: []const u8) ModuleSource {
        return .{ .uri = "repl:text", .text = text };
    }

    pub fn fromTextWithUri(uri: []const u8, text: []const u8) ModuleSource {
        return .{ .uri = uri, .text = text };
    }
};

pub const OutputFiles = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMap([]const u8),

    pub fn deinit(self: *OutputFiles) void {
        value.deinitDecoded(std.StringHashMap([]const u8), self.allocator, &self.files);
        self.* = undefined;
    }
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

/// Owns the storage needed by ergonomic evaluator configuration. `build()`
/// returns a borrowed `Options` view that remains valid until `deinit()`.
pub const OptionsBuilder = struct {
    allocator: std.mem.Allocator,
    base: Options,
    allowed_modules: std.ArrayList([]const u8) = .empty,
    allowed_resources: std.ArrayList([]const u8) = .empty,
    module_readers: std.ArrayList(ModuleReader) = .empty,
    resource_readers: std.ArrayList(ResourceReader) = .empty,
    owned_patterns: std.ArrayList([]u8) = .empty,
    pkl_argv: std.ArrayList([]const u8) = .empty,
    env_view: ?std.StringHashMap([]const u8) = null,
    cache_dir: ?[]u8 = null,
    has_allowed_modules: bool = false,
    has_allowed_resources: bool = false,
    has_module_readers: bool = false,
    has_resource_readers: bool = false,

    pub fn init(allocator: std.mem.Allocator, base: Options) !OptionsBuilder {
        var self = OptionsBuilder{
            .allocator = allocator,
            .base = base,
        };
        errdefer self.deinit();

        if (base.allowed_modules) |items| {
            self.has_allowed_modules = true;
            try self.allowed_modules.appendSlice(allocator, items);
        }
        if (base.allowed_resources) |items| {
            self.has_allowed_resources = true;
            try self.allowed_resources.appendSlice(allocator, items);
        }
        if (base.module_readers) |items| {
            self.has_module_readers = true;
            try self.module_readers.appendSlice(allocator, items);
        }
        if (base.resource_readers) |items| {
            self.has_resource_readers = true;
            try self.resource_readers.appendSlice(allocator, items);
        }
        return self;
    }

    /// Mirrors the normal binding defaults using the process environment
    /// supplied by the application. Zig 0.16 intentionally makes environment
    /// access explicit, so callers normally pass `init.environ_map` from main.
    pub fn preconfigured(
        allocator: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
    ) !OptionsBuilder {
        var self = try OptionsBuilder.init(allocator, .{});
        errdefer self.deinit();

        self.env_view = std.StringHashMap([]const u8).init(allocator);
        for (environ.keys(), environ.values()) |key, env_value| {
            try self.env_view.?.put(key, env_value);
        }

        if (environ.get("HOME") orelse environ.get("USERPROFILE")) |home| {
            self.cache_dir = try std.fs.path.join(allocator, &.{ home, ".pkl", "cache" });
        }

        if (environ.get("PKL_EXEC")) |command| {
            var tokens = std.mem.tokenizeAny(u8, command, " \t\r\n");
            while (tokens.next()) |token| try self.pkl_argv.append(allocator, token);
            if (self.pkl_argv.items.len != 0) try self.pkl_argv.append(allocator, "server");
        }
        return self;
    }

    pub fn deinit(self: *OptionsBuilder) void {
        if (self.env_view) |*env| env.deinit();
        if (self.cache_dir) |cache_dir| self.allocator.free(cache_dir);
        for (self.owned_patterns.items) |pattern| self.allocator.free(pattern);
        self.owned_patterns.deinit(self.allocator);
        self.pkl_argv.deinit(self.allocator);
        self.resource_readers.deinit(self.allocator);
        self.module_readers.deinit(self.allocator);
        self.allowed_resources.deinit(self.allocator);
        self.allowed_modules.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addModuleReader(self: *OptionsBuilder, reader: ModuleReader) !void {
        const pattern = try allowedSchemePattern(self.allocator, reader.scheme);
        errdefer self.allocator.free(pattern);

        try self.allowed_modules.append(self.allocator, pattern);
        errdefer self.allowed_modules.items.len -= 1;
        try self.module_readers.append(self.allocator, reader);
        errdefer self.module_readers.items.len -= 1;
        try self.owned_patterns.append(self.allocator, pattern);

        self.has_allowed_modules = true;
        self.has_module_readers = true;
    }

    pub fn addResourceReader(self: *OptionsBuilder, reader: ResourceReader) !void {
        const pattern = try allowedSchemePattern(self.allocator, reader.scheme);
        errdefer self.allocator.free(pattern);

        try self.allowed_resources.append(self.allocator, pattern);
        errdefer self.allowed_resources.items.len -= 1;
        try self.resource_readers.append(self.allocator, reader);
        errdefer self.resource_readers.items.len -= 1;
        try self.owned_patterns.append(self.allocator, pattern);

        self.has_allowed_resources = true;
        self.has_resource_readers = true;
    }

    pub fn build(self: *OptionsBuilder) Options {
        var result = self.base;
        result.allowed_modules = if (self.has_allowed_modules) self.allowed_modules.items else null;
        result.allowed_resources = if (self.has_allowed_resources) self.allowed_resources.items else null;
        result.module_readers = if (self.has_module_readers) self.module_readers.items else null;
        result.resource_readers = if (self.has_resource_readers) self.resource_readers.items else null;
        if (self.env_view) |env| result.env = env;
        if (self.cache_dir) |cache_dir| result.cache_dir = cache_dir;
        if (self.pkl_argv.items.len != 0) result.pkl_argv = self.pkl_argv.items;
        return result;
    }
};

io: std.Io,
allocator: std.mem.Allocator,
runtime: ?*Runtime,
evaluator_id: i64,
local_mutex: std.Io.Mutex = .init,
closed: bool = false,
last_error: ?[]u8 = null,

/// Result of evaluator creation. When the Pkl server rejects creation there
/// is no evaluator instance to hold the diagnostic, so it is surfaced here.
pub const InitResult = union(enum) {
    evaluator: Evaluator,
    failed: Failed,

    pub const Failed = struct {
        diagnostic: []u8,

        /// Frees the diagnostic with the same allocator passed to the
        /// creation call.
        pub fn deinit(self: Failed, allocator: std.mem.Allocator) void {
            allocator.free(self.diagnostic);
        }
    };
};

const CreateOutcome = union(enum) {
    id: i64,
    failed: []u8,
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !InitResult {
    const runtime = try Runtime.init(io, allocator, .{ .pkl_argv = options.pkl_argv });
    return initWithOwnedRuntime(io, allocator, runtime, options);
}

/// Create an evaluator with process environment, conventional cache directory,
/// and `PKL_EXEC` defaults populated automatically.
pub fn initPreconfigured(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !InitResult {
    var options = try OptionsBuilder.preconfigured(allocator, environ);
    defer options.deinit();
    return init(io, allocator, options.build());
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
) !InitResult {
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
) !InitResult {
    return initWithOwnedRuntime(io, allocator, runtime, options);
}

fn initWithOwnedRuntime(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    options: Options,
) !InitResult {
    var self = Evaluator{
        .io = io,
        .allocator = allocator,
        .runtime = runtime,
        .evaluator_id = 0,
    };
    errdefer runtime.release();

    const outcome = try self.createUnlocked(options);
    switch (outcome) {
        .failed => |diagnostic| {
            // No evaluator materialized, so the diagnostic cannot be attached
            // to an instance; hand it to the caller instead.
            self.runtime = null;
            runtime.release();
            return .{ .failed = .{ .diagnostic = diagnostic } };
        },
        .id => |id| self.evaluator_id = id,
    }

    errdefer runtime.sendAndFlush(.{
        .close_evaluator = .{ .evaluator_id = self.evaluator_id },
    }) catch {};

    try runtime.registerEvaluator(self.evaluator_id, .{
        .resource_readers = options.resource_readers orelse &.{},
        .module_readers = options.module_readers orelse &.{},
        .logger = options.logger,
    });
    return .{ .evaluator = self };
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
    return self.evaluateModuleRawSource(.fromUri(module_uri));
}

pub fn evaluateModuleRawSource(self: *Evaluator, source: ModuleSource) ![]u8 {
    return self.evaluateExpressionRawSource(source, null);
}

pub fn evaluateExpressionRaw(
    self: *Evaluator,
    module_uri: []const u8,
    expr: ?[]const u8,
) ![]u8 {
    return self.evaluateExpressionRawSource(.fromUri(module_uri), expr);
}

/// Calls on one evaluator remain serialized so lastError and evaluator-local
/// state stay simple. Different evaluators sharing a manager may execute
/// concurrently because Runtime dispatches responses by request ID.
pub fn evaluateExpressionRawSource(
    self: *Evaluator,
    source: ModuleSource,
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
        .module_uri = source.uri,
        .module_text = source.text,
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

pub fn evaluateModule(self: *Evaluator, comptime T: type, source: ModuleSource) !T {
    return self.evaluateExpression(T, source, null);
}

pub fn evaluateExpression(
    self: *Evaluator,
    comptime T: type,
    source: ModuleSource,
    expression: ?[]const u8,
) !T {
    const bytes = try self.evaluateExpressionRawSource(source, expression);
    defer self.allocator.free(bytes);
    return value.decodeInto(T, self.allocator, bytes);
}

pub fn evaluateOutputText(self: *Evaluator, source: ModuleSource) ![]const u8 {
    return self.evaluateExpression([]const u8, source, "output.text");
}

pub fn evaluateOutputBytes(self: *Evaluator, source: ModuleSource) ![]const u8 {
    return self.evaluateExpression([]const u8, source, "output.bytes");
}

pub fn evaluateOutputValue(self: *Evaluator, comptime T: type, source: ModuleSource) !T {
    return self.evaluateExpression(T, source, "output.value");
}

pub fn evaluateOutputFiles(self: *Evaluator, source: ModuleSource) !OutputFiles {
    return .{
        .allocator = self.allocator,
        .files = try self.evaluateExpression(
            std.StringHashMap([]const u8),
            source,
            "output.files?.toMap()?.mapValues((_, it) -> it.text) ?? Map()",
        ),
    };
}

pub fn evaluateOutputFilesBytes(self: *Evaluator, source: ModuleSource) !OutputFiles {
    return .{
        .allocator = self.allocator,
        .files = try self.evaluateExpression(
            std.StringHashMap([]const u8),
            source,
            "output.files?.toMap()?.mapValues((_, it) -> it.bytes) ?? Map()",
        ),
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
    return self.evaluateModule(T, .fromUri(module_uri));
}

fn createUnlocked(self: *Evaluator, options: Options) !CreateOutcome {
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
                break :blk CreateOutcome{ .failed = try self.allocator.dupe(u8, diagnostic) };
            }
            break :blk CreateOutcome{ .id = response.evaluator_id orelse return error.MissingEvaluatorId };
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

fn allowedSchemePattern(allocator: std.mem.Allocator, scheme: []const u8) ![]u8 {
    var pattern = std.ArrayList(u8).empty;
    defer pattern.deinit(allocator);

    for (scheme) |ch| {
        if (isRegexMeta(ch)) try pattern.append(allocator, '\\');
        try pattern.append(allocator, ch);
    }
    try pattern.append(allocator, ':');
    return pattern.toOwnedSlice(allocator);
}

fn isRegexMeta(ch: u8) bool {
    return switch (ch) {
        '\\', '.', '^', '$', '|', '?', '*', '+', '(', ')', '[', ']', '{', '}' => true,
        else => false,
    };
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

test "OptionsBuilder registers readers and allows their escaped schemes" {
    const allocator = std.testing.allocator;
    const read = struct {
        fn call(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
            return "";
        }
    }.call;

    var builder = try OptionsBuilder.init(allocator, .{
        .allowed_modules = null,
        .allowed_resources = null,
    });
    defer builder.deinit();
    try builder.addModuleReader(.{ .scheme = "mem+test", .read = read });
    try builder.addResourceReader(.{ .scheme = "asset.test", .read = read });

    const options = builder.build();
    try std.testing.expectEqual(@as(usize, 1), options.module_readers.?.len);
    try std.testing.expectEqual(@as(usize, 1), options.resource_readers.?.len);
    try std.testing.expectEqual(@as(usize, 1), options.allowed_modules.?.len);
    try std.testing.expectEqual(@as(usize, 1), options.allowed_resources.?.len);
    try std.testing.expectEqualStrings("mem\\+test:", options.allowed_modules.?[0]);
    try std.testing.expectEqualStrings("asset\\.test:", options.allowed_resources.?[0]);
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
