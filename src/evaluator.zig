const std = @import("std");

const message = @import("message");
const Transport = @import("transport");

const Evaluator = @This();

pub const Options = struct {
    pkl_argv: []const []const u8 = &.{ "pkl", "server" },
    allowed_modules: ?[]const []const u8 = &.{ "pkl:", "repl:", "file:", "package:", "projectpackage:", "https:" },
    allowed_resources: ?[]const []const u8 = &.{ "file:", "package:", "projectpackage:", "https:" },
    module_paths: ?[]const []const u8 = null,
    output_format: ?[]const u8 = null,
};

io: std.Io,
allocator: std.mem.Allocator,
transport: *Transport,
evaluator_id: i64,
next_request_id: i64,

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
    self.evaluator_id = try self.create(options);
    return self;
}

pub fn deinit(self: *Evaluator) void {
    self.transport.send(.{ .close_evaluator = .{ .evaluator_id = self.evaluator_id } }) catch {};
    self.transport.deinit();
}

pub fn evaluateModuleRaw(self: *Evaluator, module_uri: []const u8) ![]u8 {
    return self.evaluateExpressionRaw(module_uri, null);
}

pub fn evaluateExpressionRaw(self: *Evaluator, module_uri: []const u8, expr: ?[]const u8) ![]u8 {
    const request_id = self.nextRequestId();
    try self.transport.send(.{ .evaluate = .{
        .request_id = request_id,
        .evaluator_id = self.evaluator_id,
        .module_uri = module_uri,
        .expr = expr,
    } });

    while (true) {
        var envelope = try self.transport.recv();
        defer envelope.deinit(self.allocator);

        switch (envelope.msg) {
            .evaluate_response => |response| {
                if (response.request_id != request_id) continue;
                if (response.@"error") |_| return error.EvaluateFailed;
                const result = response.result orelse return error.MissingEvaluateResult;
                return try self.allocator.dupe(u8, result);
            },
            .log => {},
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
    return @import("value.zig").decodeInto(T, self.allocator, bytes);
}

fn create(self: *Evaluator, options: Options) !i64 {
    const request_id = self.nextRequestId();
    try self.transport.send(.{ .create_evaluator = .{
        .request_id = request_id,
        .allowed_modules = options.allowed_modules,
        .allowed_resources = options.allowed_resources,
        .module_paths = options.module_paths,
        .output_format = options.output_format,
    } });

    while (true) {
        var envelope = try self.transport.recv();
        defer envelope.deinit(self.allocator);

        switch (envelope.msg) {
            .create_evaluator_response => |response| {
                if (response.request_id != request_id) continue;
                if (response.@"error") |_| return error.CreateEvaluatorFailed;
                return response.evaluator_id orelse error.MissingEvaluatorId;
            },
            .log => {},
            .close_external_process => return error.ExternalProcessClosed,
            else => return error.UnexpectedMessage,
        }
    }
}

fn nextRequestId(self: *Evaluator) i64 {
    const request_id = self.next_request_id;
    self.next_request_id += 1;
    return request_id;
}

pub fn fileUriFromPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "file:")) return allocator.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "file://{s}/{s}", .{ cwd, path });
}

test {
    _ = message;
}
