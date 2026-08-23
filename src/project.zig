const std = @import("std");

const message = @import("message");
const codec = message.codec;
const Code = message.Code;
const outgoing = message.outgoing;
const Evaluator = @import("evaluator.zig");
const value = @import("value.zig");

/// The subset of `pkl.Project` needed to configure an evaluator.
/// Extra properties in Pkl's Project object are ignored by the generic decoder.
pub const Project = struct {
    package: ?Package,
    evaluator_settings: EvaluatorSettings,
    resolved_evaluator_settings: EvaluatorSettings,
    project_file_uri: []const u8,
    dependencies: std.StringHashMap(value.Value),

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        if (std.mem.eql(u8, field_name, "evaluator_settings")) return "evaluatorSettings";
        if (std.mem.eql(u8, field_name, "resolved_evaluator_settings")) return "resolvedEvaluatorSettings";
        if (std.mem.eql(u8, field_name, "project_file_uri")) return "projectFileUri";
        return field_name;
    }

    pub fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        value.deinitDecoded(Project, allocator, self);
    }

    pub fn load(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        options: Evaluator.Options,
    ) !Project {
        var evaluator = switch (try Evaluator.init(io, allocator, options)) {
            .evaluator => |evaluator| evaluator,
            // load() keeps its plain error surface; use Evaluator.init
            // directly to receive the server's diagnostic.
            .failed => |failed| {
                failed.deinit(allocator);
                return error.CreateEvaluatorFailed;
            },
        };
        defer evaluator.deinit();

        if (std.mem.eql(u8, std.fs.path.basename(path), "PklProject")) {
            return evaluator.loadFromPath(Project, path);
        }

        const project_path = try std.fs.path.join(allocator, &.{ path, "PklProject" });
        defer allocator.free(project_path);
        return evaluator.loadFromPath(Project, project_path);
    }

    /// Creates an evaluator from Pkl 0.32's resolved evaluator settings and
    /// declared dependencies. Non-null project settings override `base`.
    pub fn newEvaluator(
        self: *const Project,
        io: std.Io,
        allocator: std.mem.Allocator,
        base: Evaluator.Options,
    ) !Evaluator.InitResult {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var options = base;
        try applyResolvedSettings(arena.allocator(), &self.resolved_evaluator_settings, &options);

        const wire_project = try arena.allocator().create(outgoing.Project);
        wire_project.* = try buildWireProject(arena.allocator(), self, true);
        options.project = wire_project;

        // Evaluator.init serializes CreateEvaluator before it returns.
        return Evaluator.init(io, allocator, options);
    }

    /// Creates an evaluator on a shared EvaluatorManager using resolved project settings.
    pub fn newEvaluatorWithManager(
        self: *const Project,
        manager: anytype,
        base: Evaluator.Options,
    ) !Evaluator.InitResult {
        var arena = std.heap.ArenaAllocator.init(manager.allocator);
        defer arena.deinit();

        var options = base;
        try applyResolvedSettings(arena.allocator(), &self.resolved_evaluator_settings, &options);

        const wire_project = try arena.allocator().create(outgoing.Project);
        wire_project.* = try buildWireProject(arena.allocator(), self, true);
        options.project = wire_project;

        return manager.newEvaluator(options);
    }
};

pub const Package = struct {
    uri: []const u8,
};

pub const Checksums = struct {
    sha256: ?[]const u8 = null,
};

pub const RemoteDependency = struct {
    uri: []const u8,
    checksums: ?Checksums,
};

pub const EvaluatorSettings = struct {
    external_properties: ?std.StringHashMap([]const u8),
    env: ?std.StringHashMap([]const u8),
    allowed_modules: ?[]const []const u8,
    allowed_resources: ?[]const []const u8,
    no_cache: ?bool,
    module_path: ?[]const []const u8,
    timeout: ?value.Duration,
    module_cache_dir: ?[]const u8,
    root_dir: ?[]const u8,
    http: ?Http,
    external_module_readers: ?std.StringHashMap(ExternalReader),
    external_resource_readers: ?std.StringHashMap(ExternalReader),
    trace_mode: ?[]const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        if (std.mem.eql(u8, field_name, "external_properties")) return "externalProperties";
        if (std.mem.eql(u8, field_name, "allowed_modules")) return "allowedModules";
        if (std.mem.eql(u8, field_name, "allowed_resources")) return "allowedResources";
        if (std.mem.eql(u8, field_name, "no_cache")) return "noCache";
        if (std.mem.eql(u8, field_name, "module_path")) return "modulePath";
        if (std.mem.eql(u8, field_name, "module_cache_dir")) return "moduleCacheDir";
        if (std.mem.eql(u8, field_name, "root_dir")) return "rootDir";
        if (std.mem.eql(u8, field_name, "external_module_readers")) return "externalModuleReaders";
        if (std.mem.eql(u8, field_name, "external_resource_readers")) return "externalResourceReaders";
        if (std.mem.eql(u8, field_name, "trace_mode")) return "traceMode";
        return field_name;
    }
};

pub const Http = struct {
    ca_certificates: ?[]const u8,
    proxy: ?Proxy,
    rewrites: ?std.StringHashMap([]const u8),
    headers: ?std.StringHashMap(std.StringHashMap(value.Value)),

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        if (std.mem.eql(u8, field_name, "ca_certificates")) return "caCertificates";
        return field_name;
    }
};

pub const Proxy = struct {
    address: ?[]const u8,
    no_proxy: ?[]const []const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        if (std.mem.eql(u8, field_name, "no_proxy")) return "noProxy";
        return field_name;
    }
};

pub const ExternalReader = struct {
    executable: []const u8,
    arguments: ?[]const []const u8,
    working_dir: ?[]const u8,

    pub fn pklFieldName(comptime field_name: []const u8) []const u8 {
        if (std.mem.eql(u8, field_name, "working_dir")) return "workingDir";
        return field_name;
    }
};

fn applyResolvedSettings(
    allocator: std.mem.Allocator,
    settings: *const EvaluatorSettings,
    options: *Evaluator.Options,
) !void {
    if (settings.external_properties) |properties| options.properties = properties;
    if (settings.env) |env| options.env = env;
    if (settings.allowed_modules) |allowed| options.allowed_modules = allowed;
    if (settings.allowed_resources) |allowed| options.allowed_resources = allowed;
    if (settings.module_path) |paths| options.module_paths = paths;
    if (settings.root_dir) |root| options.root_dir = root;
    if (settings.trace_mode) |mode| options.trace_mode = mode;

    if (settings.no_cache orelse false) {
        options.cache_dir = null;
    } else if (settings.module_cache_dir) |cache| {
        options.cache_dir = cache;
    }

    if (settings.timeout) |timeout| options.timeout_seconds = try timeoutSeconds(timeout);

    if (settings.http) |project_http| {
        const http = try allocator.create(outgoing.Http);
        http.* = if (options.http) |base_http| base_http.* else .{};

        if (project_http.ca_certificates) |certs| http.ca_certificates = certs;
        if (project_http.rewrites) |rewrites| http.rewrites = rewrites;
        if (project_http.headers) |headers| http.headers = try buildHeaders(allocator, headers);

        if (project_http.proxy) |project_proxy| {
            const proxy = try allocator.create(outgoing.Proxy);
            proxy.* = if (http.proxy) |base_proxy| base_proxy.* else .{};
            if (project_proxy.address) |address| proxy.address = address;
            if (project_proxy.no_proxy) |no_proxy| proxy.no_proxy = no_proxy;
            http.proxy = proxy;
        }

        options.http = http;
    }

    if (settings.external_module_readers) |readers| {
        options.external_module_readers = try buildExternalReaders(allocator, readers);
    }
    if (settings.external_resource_readers) |readers| {
        options.external_resource_readers = try buildExternalReaders(allocator, readers);
    }
}

fn timeoutSeconds(duration: value.Duration) !i64 {
    const unit_ns: f64 = @floatFromInt(@intFromEnum(duration.unit));
    const seconds = duration.value * unit_ns / 1_000_000_000.0;
    if (seconds < 0.0) return error.InvalidProjectTimeout;
    return @intFromFloat(@ceil(seconds));
}

fn buildHeaders(
    allocator: std.mem.Allocator,
    source: std.StringHashMap(std.StringHashMap(value.Value)),
) !outgoing.Headers {
    var result = outgoing.Headers.init(allocator);
    var patterns = source.iterator();
    while (patterns.next()) |pattern_entry| {
        var headers = outgoing.HeaderMap.init(allocator);
        var iterator = pattern_entry.value_ptr.iterator();
        while (iterator.next()) |header_entry| {
            try headers.put(header_entry.key_ptr.*, try headerValues(allocator, header_entry.value_ptr.*));
        }
        try result.put(pattern_entry.key_ptr.*, headers);
    }
    return result;
}

fn headerValues(allocator: std.mem.Allocator, source: value.Value) ![]const []const u8 {
    return switch (source) {
        .string => |string| blk: {
            const values = try allocator.alloc([]const u8, 1);
            values[0] = string;
            break :blk values;
        },
        .list => |items| blk: {
            const values = try allocator.alloc([]const u8, items.len);
            for (items, 0..) |item, index| {
                values[index] = switch (item) {
                    .string => |string| string,
                    else => return error.InvalidProjectHttpHeaderValue,
                };
            }
            break :blk values;
        },
        else => error.InvalidProjectHttpHeaderValue,
    };
}

fn buildExternalReaders(
    allocator: std.mem.Allocator,
    source: std.StringHashMap(ExternalReader),
) !std.StringHashMap(outgoing.ExternalReader) {
    var result = std.StringHashMap(outgoing.ExternalReader).init(allocator);
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        const reader = entry.value_ptr.*;
        const arguments: ?[][]const u8 = if (reader.arguments) |args| blk: {
            const copy = try allocator.alloc([]const u8, args.len);
            for (args, 0..) |arg, index| copy[index] = arg;
            break :blk copy;
        } else null;
        try result.put(entry.key_ptr.*, .{
            .executable = reader.executable,
            .arguments = arguments,
            .working_dir = reader.working_dir,
        });
    }
    return result;
}

/// Builds the CreateEvaluator wire representation. The root project is
/// encoded with `type = "project"` and no package URI, matching the reference
/// bindings; nested local dependencies keep `type = "local"` plus their
/// package URI, and remote dependencies stay `"remote"`.
fn buildWireProject(
    allocator: std.mem.Allocator,
    project: *const Project,
    is_root: bool,
) !outgoing.Project {
    var dependencies = std.StringHashMap(*outgoing.ProjectOrDependency).init(allocator);
    var iterator = project.dependencies.iterator();

    while (iterator.next()) |entry| {
        const dependency = try allocator.create(outgoing.ProjectOrDependency);
        const object = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => return error.InvalidProjectDependency,
        };

        if (object.properties.contains("projectFileUri")) {
            var local = try value.fromValue(Project, allocator, entry.value_ptr.*);
            dependency.* = .{ .project = try buildWireProject(allocator, &local, false) };
        } else {
            const remote = try value.fromValue(RemoteDependency, allocator, entry.value_ptr.*);
            const checksums: ?*outgoing.Checksums = if (remote.checksums) |checksum| blk: {
                const wire = try allocator.create(outgoing.Checksums);
                wire.* = .{ .sha256 = checksum.sha256 };
                break :blk wire;
            } else null;
            dependency.* = .{ .remote_dependency = .{
                .package_uri = remote.uri,
                .checksums = checksums,
            } };
        }

        try dependencies.put(entry.key_ptr.*, dependency);
    }

    // The reference bindings send no packageUri for the root project, even
    // when the PklProject declares one.
    const package_uri: ?[]const u8 = if (is_root) null else if (project.package) |package| package.uri else null;
    return .{
        .type = if (is_root) "project" else "local",
        .package_uri = package_uri,
        .project_file_uri = project.project_file_uri,
        .dependencies = dependencies,
    };
}

fn dependencyObject(properties: std.StringHashMap(value.Value)) value.Value {
    // module_uri, name, entries, and elements are unused by buildWireProject.
    return .{ .object = .{
        .module_uri = "",
        .name = "",
        .properties = properties,
        .entries = &.{},
        .elements = &.{},
    } };
}

test "wire project uses root and dependency discriminators per protocol" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var local_properties = std.StringHashMap(value.Value).init(arena_allocator);
    try local_properties.put("projectFileUri", .{ .string = "/deps/local/PklProject" });
    try local_properties.put("uri", .{ .string = "pkg:local-dep" });
    try local_properties.put("dependencies", .{ .map = &.{} });

    var checksums_properties = std.StringHashMap(value.Value).init(arena_allocator);
    try checksums_properties.put("sha256", .{ .string = "abc123" });
    var remote_properties = std.StringHashMap(value.Value).init(arena_allocator);
    try remote_properties.put("uri", .{ .string = "pkg:remote-dep" });
    try remote_properties.put("checksums", try dependencyObject(checksums_properties));

    var dependencies = std.StringHashMap(value.Value).init(arena_allocator);
    try dependencies.put("localDep", try dependencyObject(local_properties));
    try dependencies.put("remoteDep", try dependencyObject(remote_properties));

    const project = Project{
        .package = .{ .uri = "app://root-pkg" },
        .evaluator_settings = undefined,
        .resolved_evaluator_settings = undefined,
        .project_file_uri = "/app/PklProject",
        .dependencies = dependencies,
    };

    var wire_root = try buildWireProject(arena_allocator, &project, true);

    // The root is a "project" without a packageUri; its package declaration
    // must not leak into CreateEvaluator.
    try std.testing.expectEqualStrings("project", wire_root.type);
    try std.testing.expectEqual(@as(?[]const u8, null), wire_root.package_uri);

    const wire_local = wire_root.dependencies.get("localDep").?.project;
    try std.testing.expectEqualStrings("local", wire_local.type);
    try std.testing.expectEqualStrings("pkg:local-dep", wire_local.package_uri.?);
    try std.testing.expectEqualStrings("/deps/local/PklProject", wire_local.project_file_uri);

    const wire_remote = wire_root.dependencies.get("remoteDep").?.remote_dependency;
    try std.testing.expectEqualStrings("remote", wire_remote.type);
    try std.testing.expectEqualStrings("pkg:remote-dep", wire_remote.package_uri.?);
    try std.testing.expectEqualStrings("abc123", wire_remote.checksums.?.sha256.?);

    // Golden MessagePack shape of the outgoing CreateEvaluator frame body:
    // camelCase keys, nil optionals omitted, flat dependency discriminators.
    var payload = try (message.Outgoing{
        .create_evaluator = .{ .request_id = 1, .project = &wire_root },
    }).encode(arena_allocator);
    defer payload.free(arena_allocator);

    var frame = try codec.decodeFrame(&payload);
    try std.testing.expectEqual(Code.new_evaluator, frame.code);

    const project_payload = (try frame.body.mapGet("project")) orelse return error.MissingProject;
    const root_type = try ((try project_payload.mapGet("type")) orelse return error.MissingType).asStr();
    try std.testing.expectEqualStrings("project", root_type);
    try std.testing.expect((try project_payload.mapGet("packageUri")) == null);
    try std.testing.expectEqualStrings(
        "/app/PklProject",
        try ((try project_payload.mapGet("projectFileUri")) orelse return error.MissingProjectFileUri).asStr(),
    );

    const deps_payload = (try project_payload.mapGet("dependencies")) orelse return error.MissingDependencies;
    const local_payload = (try deps_payload.mapGet("localDep")) orelse return error.MissingLocalDep;
    try std.testing.expectEqualStrings(
        "local",
        try ((try local_payload.mapGet("type")) orelse return error.MissingType).asStr(),
    );
    try std.testing.expectEqualStrings(
        "pkg:local-dep",
        try ((try local_payload.mapGet("packageUri")) orelse return error.MissingPackageUri).asStr(),
    );

    const remote_payload = (try deps_payload.mapGet("remoteDep")) orelse return error.MissingRemoteDep;
    try std.testing.expectEqualStrings(
        "remote",
        try ((try remote_payload.mapGet("type")) orelse return error.MissingType).asStr(),
    );
    const checksums_payload = (try remote_payload.mapGet("checksums")) orelse return error.MissingChecksums;
    try std.testing.expectEqualStrings(
        "abc123",
        try ((try checksums_payload.mapGet("sha256")) orelse return error.MissingSha256).asStr(),
    );
}

test "timeout conversion rounds fractional durations upward" {
    try std.testing.expectEqual(@as(i64, 2), try timeoutSeconds(.{ .value = 1500, .unit = .ms }));
}

test "project HTTP headers accept scalar and listing values" {
    const allocator = std.testing.allocator;
    var header_values = std.StringHashMap(value.Value).init(allocator);
    defer header_values.deinit();
    try header_values.put("Authorization", .{ .string = "Bearer token" });
    var accept = [_]value.Value{
        .{ .string = "application/json" },
        .{ .string = "text/plain" },
    };
    try header_values.put("Accept", .{ .list = accept[0..] });

    var source = std.StringHashMap(std.StringHashMap(value.Value)).init(allocator);
    defer source.deinit();
    try source.put("https://example.com/**", header_values);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var headers = try buildHeaders(arena.allocator(), source);
    const actual = headers.getPtr("https://example.com/**").?;
    try std.testing.expectEqualStrings("Bearer token", actual.get("Authorization").?[0]);
    try std.testing.expectEqual(@as(usize, 2), actual.get("Accept").?.len);
}
