const std = @import("std");
const msgpack = @import("msgpack");

const Code = @import("code.zig").Code;
const codec = @import("codec.zig");

const log = std.log.scoped(.@"pkl-zig|message|incoming");

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

/// Represents any message received from Pkl.
pub const Message = union(enum) {
    create_evaluator_response: CreateEvaluatorResponse,
    evaluate_response: EvaluateResponse,
    log: Log,
    read_resource: ReadResource,
    read_module: ReadModule,
    list_resources: ListResources,
    list_modules: ListModules,
    initialize_module_reader: InitializeModuleReader,
    initialize_resource_reader: InitializeResourceReader,
    close_external_process: CloseExternalProcess,

    pub fn decode(allocator: std.mem.Allocator, payload: *msgpack.Payload) !Message {
        log.debug("Decoding incoming message.", .{});
        var frame = try codec.decodeFrame(payload);
        log.debug("Decoded incoming message code: {s}.", .{@tagName(frame.code)});

        return switch (frame.code) {
            .new_evaluator_response => .{ .create_evaluator_response = try codec.fromPayload(CreateEvaluatorResponse, allocator, &frame.body) },
            .evaluate_response => .{ .evaluate_response = try codec.fromPayload(EvaluateResponse, allocator, &frame.body) },
            .evaluate_log => .{ .log = try codec.fromPayload(Log, allocator, &frame.body) },
            .evaluate_read => .{ .read_resource = try codec.fromPayload(ReadResource, allocator, &frame.body) },
            .evaluate_read_module => .{ .read_module = try codec.fromPayload(ReadModule, allocator, &frame.body) },
            .list_resources_request => .{ .list_resources = try codec.fromPayload(ListResources, allocator, &frame.body) },
            .list_modules_request => .{ .list_modules = try codec.fromPayload(ListModules, allocator, &frame.body) },
            .initialize_module_reader_request => .{ .initialize_module_reader = try codec.fromPayload(InitializeModuleReader, allocator, &frame.body) },
            .initialize_resource_reader_request => .{ .initialize_resource_reader = try codec.fromPayload(InitializeResourceReader, allocator, &frame.body) },
            .close_external_process => .{ .close_external_process = try codec.fromPayload(CloseExternalProcess, allocator, &frame.body) },
            else => codec.DecodeError.UnknownMessageCode,
        };
    }

    pub fn code(self: Message) Code {
        return switch (self) {
            .create_evaluator_response => .new_evaluator_response,
            .evaluate_response => .evaluate_response,
            .log => .evaluate_log,
            .read_resource => .evaluate_read,
            .read_module => .evaluate_read_module,
            .list_resources => .list_resources_request,
            .list_modules => .list_modules_request,
            .initialize_module_reader => .initialize_module_reader_request,
            .initialize_resource_reader => .initialize_resource_reader_request,
            .close_external_process => .close_external_process,
        };
    }
};
