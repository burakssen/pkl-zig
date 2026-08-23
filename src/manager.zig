const std = @import("std");
const transport_mod = @import("transport");
const Transport = transport_mod.Transport;
const Runtime = @import("runtime.zig");
const Evaluator = @import("evaluator.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;

/// EvaluatorManager owns one shared pkl server runtime and dispenses evaluator
/// handles. Each evaluator retains the runtime, so manager shutdown invalidates
/// new work without leaving existing handles with dangling transport pointers.
pub const EvaluatorManager = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: ?*Runtime,
    mutex: std.Io.Mutex = .init,

    pub const Options = Transport.Options;

    pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !EvaluatorManager {
        const runtime = try Runtime.init(io, allocator, options);
        return .{
            .io = io,
            .allocator = allocator,
            .runtime = runtime,
        };
    }

    /// Start the shared server using the same `PKL_EXEC` resolution as
    /// `Evaluator.initPreconfigured`.
    pub fn initPreconfigured(
        io: std.Io,
        allocator: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
    ) !EvaluatorManager {
        var evaluator_options = try Evaluator.OptionsBuilder.preconfigured(allocator, environ);
        defer evaluator_options.deinit();
        return init(io, allocator, .{ .pkl_argv = evaluator_options.build().pkl_argv });
    }

    pub fn deinit(self: *EvaluatorManager) void {
        self.close();
    }

    pub fn close(self: *EvaluatorManager) void {
        self.mutex.lockUncancelable(self.io);
        const runtime = self.runtime orelse {
            self.mutex.unlock(self.io);
            return;
        };
        self.runtime = null;
        self.mutex.unlock(self.io);

        runtime.closeForManager();
        runtime.release();
    }

    pub fn newEvaluator(self: *EvaluatorManager, options: Evaluator.Options) !Evaluator.InitResult {
        try self.mutex.lock(self.io);
        const runtime = self.runtime orelse {
            self.mutex.unlock(self.io);
            return error.ManagerClosed;
        };
        runtime.retain() catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);

        // initWithRuntime consumes the retained reference on both success and
        // failure, so no manager-side errdefer is needed here.
        return Evaluator.initWithRuntime(self.io, self.allocator, runtime, options);
    }

    /// Create an evaluator with process environment and cache defaults. The
    /// manager's server process has already been resolved by manager init.
    pub fn newPreconfiguredEvaluator(
        self: *EvaluatorManager,
        environ: *const std.process.Environ.Map,
    ) !Evaluator.InitResult {
        var options = try Evaluator.OptionsBuilder.preconfigured(self.allocator, environ);
        defer options.deinit();
        return self.newEvaluator(options.build());
    }

    pub fn newProjectEvaluator(
        self: *EvaluatorManager,
        project: *const Project,
        base: Evaluator.Options,
    ) !Evaluator.InitResult {
        return project.newEvaluatorWithManager(self, base);
    }
};
