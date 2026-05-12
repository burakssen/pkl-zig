const std = @import("std");
const msgpack = @import("msgpack");

const message = @import("message");
const Code = message.Code;
const codec = message.codec;
const errors = message.errors;
const types = @import("types.zig");

pub const CreateEvaluatorResponse = types.CreateEvaluatorResponse;
pub const EvaluateResponse = types.EvaluateResponse;
pub const Log = types.Log;
pub const ReadResource = types.ReadResource;
pub const ReadModule = types.ReadModule;
pub const ListResources = types.ListResources;
pub const ListModules = types.ListModules;
pub const InitializeModuleReader = types.InitializeModuleReader;
pub const InitializeResourceReader = types.InitializeResourceReader;
pub const CloseExternalProcess = types.CloseExternalProcess;

const log = std.log.scoped(.@"pkl-zig|message|incoming");

/// Represents any message received from Pkl.
pub const Message = union(enum) {
    create_evaluator_response: types.CreateEvaluatorResponse,
    evaluate_response: types.EvaluateResponse,
    log: types.Log,
    read_resource: types.ReadResource,
    read_module: types.ReadModule,
    list_resources: types.ListResources,
    list_modules: types.ListModules,
    initialize_module_reader: types.InitializeModuleReader,
    initialize_resource_reader: types.InitializeResourceReader,
    close_external_process: types.CloseExternalProcess,

    pub fn decode(allocator: std.mem.Allocator, payload: *msgpack.Payload) !Message {
        log.debug("Decoding incoming message.", .{});
        var frame = try codec.decodeFrame(payload);
        log.debug("Decoded incoming message code: {s}.", .{@tagName(frame.code)});

        return switch (frame.code) {
            .new_evaluator_response => .{ .create_evaluator_response = try codec.fromPayload(types.CreateEvaluatorResponse, allocator, &frame.body) },
            .evaluate_response => .{ .evaluate_response = try codec.fromPayload(types.EvaluateResponse, allocator, &frame.body) },
            .evaluate_log => .{ .log = try codec.fromPayload(types.Log, allocator, &frame.body) },
            .evaluate_read => .{ .read_resource = try codec.fromPayload(types.ReadResource, allocator, &frame.body) },
            .evaluate_read_module => .{ .read_module = try codec.fromPayload(types.ReadModule, allocator, &frame.body) },
            .list_resources_request => .{ .list_resources = try codec.fromPayload(types.ListResources, allocator, &frame.body) },
            .list_modules_request => .{ .list_modules = try codec.fromPayload(types.ListModules, allocator, &frame.body) },
            .initialize_module_reader_request => .{ .initialize_module_reader = try codec.fromPayload(types.InitializeModuleReader, allocator, &frame.body) },
            .initialize_resource_reader_request => .{ .initialize_resource_reader = try codec.fromPayload(types.InitializeResourceReader, allocator, &frame.body) },
            .close_external_process => .{ .close_external_process = try codec.fromPayload(types.CloseExternalProcess, allocator, &frame.body) },
            else => errors.DecodeError.UnknownMessageCode,
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
