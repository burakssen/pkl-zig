const std = @import("std");

/// Describes a resource reader provided by the client.
pub const ResourceReader = struct {
    scheme: []const u8,
    has_hierarchical_uris: bool = false,
    is_globbable: bool = false,
};

/// Describes a module reader provided by the client.
pub const ModuleReader = struct {
    scheme: []const u8,
    has_hierarchical_uris: bool = false,
    is_globbable: bool = false,
    is_local: bool = false,
};

/// Checksums for a remote project dependency.
pub const Checksums = struct {
    sha256: []const u8,
};

/// Local project settings passed to the evaluator.
pub const Project = struct {
    type: []const u8 = "local",
    package_uri: ?[]const u8 = null,
    project_file_uri: []const u8,
    dependencies: std.StringHashMap(*ProjectOrDependency),
};

/// Remote dependency settings passed as part of a project.
pub const RemoteDependency = struct {
    type: []const u8 = "remote",
    package_uri: ?[]const u8 = null,
    checksums: ?*Checksums = null,
};

/// Represents a local project or remote dependency.
pub const ProjectOrDependency = union(enum) {
    project: Project,
    remote_dependency: RemoteDependency,
};

/// Proxy settings for HTTP requests.
pub const Proxy = struct {
    address: ?[]const u8 = null,
    no_proxy: ?[]const []const u8 = null,
};

/// HTTP client settings for Pkl.
pub const Http = struct {
    ca_certificates: ?[]const u8 = null,
    proxy: ?*Proxy = null,
    rewrites: ?std.StringHashMap([]const u8) = null,
};

/// Describes an external reader command.
pub const ExternalReader = struct {
    executable: []const u8,
    arguments: ?[][]const u8 = null,
};

/// Request to create a new Pkl evaluator.
pub const CreateEvaluator = struct {
    request_id: i64,
    client_resource_readers: ?[]const ResourceReader = null,
    client_module_readers: ?[]const ModuleReader = null,
    external_reader_commands: ?[]const []const []const u8 = null,
    module_paths: ?[]const []const u8 = null,
    env: ?std.StringHashMap([]const u8) = null,
    properties: ?std.StringHashMap([]const u8) = null,
    output_format: ?[]const u8 = null,
    allowed_modules: ?[]const []const u8 = null,
    allowed_resources: ?[]const []const u8 = null,
    root_dir: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    project: ?*Project = null,
    http: ?*Http = null,
    timeout_seconds: ?i64 = null,
    external_module_readers: ?std.StringHashMap(ExternalReader) = null,
    external_resource_readers: ?std.StringHashMap(ExternalReader) = null,
    trace_mode: ?[]const u8 = null,
};

/// Request to close a Pkl evaluator.
pub const CloseEvaluator = struct {
    evaluator_id: i64,
};

/// Request to evaluate a Pkl module.
pub const Evaluate = struct {
    request_id: i64,
    evaluator_id: i64,
    module_uri: []const u8,
    module_text: ?[]const u8 = null,
    expr: ?[]const u8 = null,
};

/// Response to a ReadResource request.
pub const ReadResourceResponse = struct {
    request_id: i64,
    evaluator_id: i64,
    contents: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Response to a ReadModule request.
pub const ReadModuleResponse = struct {
    request_id: i64,
    evaluator_id: i64,
    contents: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Represents a file or directory element in a directory listing.
pub const PathElement = struct {
    name: []const u8,
    is_directory: bool,
};

/// Response to a ListResources request.
pub const ListResourcesResponse = struct {
    request_id: i64,
    evaluator_id: i64,
    path_elements: ?[]PathElement = null,
    @"error": ?[]const u8 = null,
};

/// Response to a ListModules request.
pub const ListModulesResponse = struct {
    request_id: i64,
    evaluator_id: i64,
    path_elements: ?[]const PathElement = null,
    @"error": ?[]const u8 = null,
};

/// Response to an InitializeModuleReader request.
pub const InitializeModuleReaderResponse = struct {
    request_id: i64,
    spec: ?ModuleReader = null,
};

/// Response to an InitializeResourceReader request.
pub const InitializeResourceReaderResponse = struct {
    request_id: i64,
    spec: ?ResourceReader = null,
};
