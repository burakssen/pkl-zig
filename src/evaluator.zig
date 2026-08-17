const std = @import("std");

const message = @import("message");
const Transport = @import("transport");
const value = @import("value.zig");
const log = std.log.scoped(.@"pkl-zig|evaluator");

const Evaluator = @This();

pub const Options = struct {
    pkl_argv: []const []const u8 = &.{ "pkl", "server" },
    allowed_modules: ?[]const []const u8 = &.{ "pkl:", "repl:", "file:", "package:", "projectpackage:", "https:" },
    allowed_resources: ?[]const []const u8 = &.{ "file:", "package:", "projectpackage:", "https:" },
    module_paths: ?[]const []const u8 = null,
    output_format: ?[]const u8 = null,

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
evaluator_id: i64,
next_request_id: i64,
request_mutex: std.Io.Mutex = .init,
last_error: ?[]u8 = null,

pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !Evaluator {
    const transport = try Transport.initWithOptions(io, allocator, .{ .pkl_argv = options.pkl_argv });
    errdefer transport.deinit();

    try transport.start();

    var self = Evaluator{
        .io = io,
        .allocator = allocator,
        .transport = transport,
        .evaluator_id = 0,
        .next_request_id = 1,
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
    try self.request_mutex.lock(self.io);
    defer self.request_mutex.unlock(self.io);

    const transport = self.transport orelse return;

    // Make the state closed before doing any fallible work. Even when flushing
    // the close frame fails, no later operation may dereference this transport.
    self.transport = null;
    defer transport.deinit();

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
    try self.request_mutex.lock(self.io);
    defer self.request_mutex.unlock(self.io);

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
    self.clearLastErrorUnlocked();
    const transport = self.transport orelse return error.EvaluatorClosed;
    const request_id = self.nextRequestIdUnlocked();

    try transport.send(.{ .create_evaluator = .{
        .request_id = request_id,
        .allowed_modules = options.allowed_modules,
        .allowed_resources = options.allowed_resources,
        .module_paths = options.module_paths,
        .output_format = options.output_format,
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

test {
    _ = message;
    _ = log;
}
