const std = @import("std");
const Transport = @import("transport");
const Evaluator = @import("evaluator.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;

// EvaluatorManager owns one Transport and dispenses Evaluator handles.
// No complex thread pools; just serialized message routing on the transport.

pub const EvaluatorManager = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: ?*Transport,
    mutex: std.Io.Mutex = .init,

    pub const Options = Transport.Options;

    pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !EvaluatorManager {
        const transport = try Transport.initWithOptions(io, allocator, options);
        errdefer transport.deinit();

        try transport.start();

        return .{
            .io = io,
            .allocator = allocator,
            .transport = transport,
        };
    }

    pub fn deinit(self: *EvaluatorManager) void {
        self.close();
    }

    pub fn close(self: *EvaluatorManager) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.transport) |transport| {
            self.transport = null;
            transport.deinit();
        }
    }

    pub fn newEvaluator(self: *EvaluatorManager, options: Evaluator.Options) !Evaluator {
        const transport = self.transport orelse return error.ManagerClosed;
        return Evaluator.initWithTransport(self.io, self.allocator, transport, &self.mutex, options);
    }

    pub fn newProjectEvaluator(
        self: *EvaluatorManager,
        project: *const Project,
        base: Evaluator.Options,
    ) !Evaluator {
        return project.newEvaluatorWithManager(self, base);
    }
};
