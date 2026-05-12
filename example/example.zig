const std = @import("std");

const pkl = @import("pkl");
const message = pkl.message;
const Transport = pkl.Transport;

pub const std_options: std.Options = .{
    .logFn = struct {
        pub fn logFn(
            comptime level: std.log.Level,
            comptime scope: @EnumLiteral(),
            comptime format: []const u8,
            args: anytype,
        ) void {
            const prefix = if (scope == .default) "" else @tagName(scope);
            const color = comptime switch (level) {
                .err => "\x1b[31m",
                .warn => "\x1b[33m",
                .info => "\x1b[90m",
                .debug => "\x1b[36m",
            };
            const reset = "\x1b[0m";
            const bold = "\x1b[1m";

            const fmt = color ++ bold ++ "[" ++ prefix ++ "]" ++ reset ++ " " ++ format ++ "\n";

            if (level == .err) {
                const stderr_file = std.Io.File.stderr();
                var stderr_writer = stderr_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                const stderr = &stderr_writer.interface;
                nosuspend stderr.print(fmt, args) catch return;
            } else {
                const stdout_file = std.Io.File.stdout();
                var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                const stdout = &stdout_writer.interface;
                nosuspend stdout.print(fmt, args) catch return;
            }
        }
    }.logFn,
};

const log = std.log.scoped(.@"pkl-zig|example");

pub fn main(init: std.process.Init) !void {
    var transport = try Transport.init(init.io, init.gpa);
    defer transport.deinit();

    try transport.start();

    const module_uri = try fileUriFromPath(init, "example/myModule.pkl");
    defer init.gpa.free(module_uri);

    var example = Example{
        .init = init,
        .transport = transport,
        .evaluator_id = try createEvaluator(init, transport),
    };
    defer transport.send(.{ .close_evaluator = .{ .evaluator_id = example.evaluator_id } }) catch {};

    std.debug.print("created evaluator {}\n", .{example.evaluator_id});
    try example.evaluate(module_uri);
    try example.serveUntilEvaluateResponse();
}

const Example = struct {
    init: std.process.Init,
    transport: *Transport,
    evaluator_id: i64,

    fn evaluate(self: *Example, module_uri: []const u8) !void {
        try self.transport.send(.{
            .evaluate = .{
                .request_id = 9805131,
                .evaluator_id = self.evaluator_id,
                .module_uri = module_uri,
            },
        });
    }

    fn serveUntilEvaluateResponse(self: *Example) !void {
        while (true) {
            var envelope = try self.transport.recv();
            defer envelope.deinit(self.init.gpa);

            switch (envelope.msg) {
                .initialize_module_reader => |request| {
                    try self.transport.send(.{
                        .initialize_module_reader_response = .{
                            .request_id = request.request_id,
                            .spec = .{
                                .scheme = "customfs",
                                .has_hierarchical_uris = true,
                                .is_globbable = true,
                                .is_local = true,
                            },
                        },
                    });
                },
                .list_modules => |request| try self.respondToListModules(request),
                .read_module => |request| try self.respondToReadModule(request),
                .log => |entry| log.warn("pkl log({}): {s}\n", .{ entry.level, entry.message }),
                .evaluate_response => |response| {
                    if (response.@"error") |err| {
                        std.debug.print("evaluate error: {s}\n", .{err});
                        return error.EvaluateFailed;
                    }

                    const result = response.result orelse return error.MissingEvaluateResult;
                    std.debug.print("evaluation result: {} bytes\n", .{result.len});
                    return;
                },
                else => return error.UnexpectedMessage,
            }
        }
    }

    fn respondToListModules(
        self: *Example,
        request: message.incoming.ListModules,
    ) !void {
        if (!std.mem.eql(u8, request.uri, "customfs:/")) {
            try self.transport.send(.{
                .list_modules_response = .{
                    .request_id = request.request_id,
                    .evaluator_id = self.evaluator_id,
                    .@"error" = "unknown custom module listing uri",
                },
            });
            return;
        }

        try self.transport.send(.{
            .list_modules_response = .{
                .request_id = request.request_id,
                .evaluator_id = self.evaluator_id,
                .path_elements = &.{.{
                    .name = "foo.pkl",
                    .is_directory = false,
                }},
            },
        });
    }

    fn respondToReadModule(
        self: *Example,
        request: message.incoming.ReadModule,
    ) !void {
        if (!std.mem.eql(u8, request.uri, "customfs:/foo.pkl")) {
            try self.transport.send(.{
                .read_module_response = .{
                    .request_id = request.request_id,
                    .evaluator_id = self.evaluator_id,
                    .@"error" = "unknown custom module uri",
                },
            });
            return;
        }

        const contents = try std.Io.Dir.cwd().readFileAlloc(
            self.init.io,
            "example/foo.pkl",
            self.init.gpa,
            .limited(1024),
        );
        defer self.init.gpa.free(contents);

        try self.transport.send(.{
            .read_module_response = .{
                .request_id = request.request_id,
                .evaluator_id = self.evaluator_id,
                .contents = contents,
            },
        });
    }
};

fn createEvaluator(init: std.process.Init, transport: *Transport) !i64 {
    try transport.send(.{
        .create_evaluator = .{
            .request_id = 135,
            .allowed_modules = &.{ "pkl:", "repl:", "file:", "customfs:" },
            .client_module_readers = &.{.{
                .scheme = "customfs",
                .has_hierarchical_uris = true,
                .is_globbable = true,
                .is_local = true,
            }},
        },
    });

    var envelope = try transport.recv();
    defer envelope.deinit(init.gpa);

    return switch (envelope.msg) {
        .create_evaluator_response => |response| {
            if (response.@"error") |err| {
                std.debug.print("create evaluator error: {s}\n", .{err});
                return error.CreateEvaluatorFailed;
            }
            return response.evaluator_id orelse error.MissingEvaluatorId;
        },
        else => error.UnexpectedMessage,
    };
}

fn fileUriFromPath(init: std.process.Init, path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);

    return std.fmt.allocPrint(init.gpa, "file://{s}/{s}", .{ cwd, path });
}
