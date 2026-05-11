/// Response message for a CreateEvaluator request.
pub const CreateEvaluatorResponse = struct {
    request_id: i64,
    evaluator_id: ?i64 = null,
    @"error": ?[]const u8 = null,
};

/// Response message for an Evaluate request.
pub const EvaluateResponse = struct {
    request_id: i64,
    evaluator_id: i64,
    result: ?[]u8 = null,
    @"error": ?[]const u8 = null,
};

/// Log message sent from Pkl during evaluation.
pub const Log = struct {
    evaluator_id: i64,
    level: i32,
    message: []const u8,
    frame_uri: []const u8,
};

/// Request from Pkl to read a resource.
pub const ReadResource = struct {
    request_id: i64,
    evaluator_id: i64,
    uri: []const u8,
};

/// Request from Pkl to read a module.
pub const ReadModule = struct {
    request_id: i64,
    evaluator_id: i64,
    uri: []const u8,
};

/// Request from Pkl to list resources in a directory.
pub const ListResources = struct {
    request_id: i64,
    evaluator_id: i64,
    uri: []const u8,
};

/// Request from Pkl to list modules in a directory.
pub const ListModules = struct {
    request_id: i64,
    evaluator_id: i64,
    uri: []const u8,
};

/// Request from Pkl to initialize a module reader.
pub const InitializeModuleReader = struct {
    request_id: i64,
    scheme: []const u8,
};

/// Request from Pkl to initialize a resource reader.
pub const InitializeResourceReader = struct {
    request_id: i64,
    scheme: []const u8,
};

/// Message sent by Pkl indicating the external process should close.
pub const CloseExternalProcess = struct {};
