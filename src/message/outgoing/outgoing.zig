const std = @import("std");
const msgpack = @import("msgpack");

const message = @import("message");
const utils = message.utils;
const errors = message.errors;

pub const code = @import("code.zig");
pub const types = @import("types.zig");

const log = std.log.scoped(.@"pkl-zig|message|outgoing");

/// Represents any message sent to Pkl.
pub const OutgoingMessage = union(enum) {
    create_evaluator: types.CreateEvaluator,
    close_evaluator: types.CloseEvaluator,
    evaluate: types.Evaluate,
    read_resource_response: types.ReadResourceResponse,
    read_module_response: types.ReadModuleResponse,
    list_resources_response: types.ListResourcesResponse,
    list_modules_response: types.ListModulesResponse,
    initialize_module_reader_response: types.InitializeModuleReaderResponse,
    initialize_resource_reader_response: types.InitializeResourceReaderResponse,

    /// Encodes an OutgoingMessage into a msgpack payload.
    pub fn encode(self: OutgoingMessage, allocator: std.mem.Allocator) !msgpack.Payload {
        log.debug("Encoding OutgoingMessage of type [{s}] to payload.", .{@tagName(self)});
        var body_payload: msgpack.Payload = undefined;
        var code_val: code.Code = undefined;

        switch (self) {
            .create_evaluator => |msg| {
                code_val = .new_evaluator;
                body_payload = try utils.ToPayload(allocator, msg);
            },
            .close_evaluator => |msg| {
                code_val = .close_evaluator;
                body_payload = try utils.ToPayload(allocator, msg);
            },
            .evaluate => |msg| {
                code_val = .evaluate;
                body_payload = try utils.ToPayload(allocator, msg);
            },
            .read_resource_response => |msg| {
                code_val = .evaluate_read_response;
                body_payload = try utils.ToPayload(allocator, msg);
            },
            .read_module_response => |msg| {
                code_val = .evaluate_read_module_response;
                body_payload = try utils.ToPayload(allocator, msg);
            },
            .list_resources_response => |msg| {
                code_val = .list_resources_response;
                body_payload = try utils.ToPayload(allocator, msg);
            },
            .list_modules_response => |msg| {
                code_val = .list_modules_response;
                body_payload = try utils.ToPayload(allocator, msg);
            },
            .initialize_module_reader_response => |msg| {
                code_val = .initialize_module_reader_response;
                body_payload = try utils.ToPayload(allocator, msg);
            },
            .initialize_resource_reader_response => |msg| {
                code_val = .initialize_resource_reader_response;
                body_payload = try utils.ToPayload(allocator, msg);
            },
        }

        log.debug("Successfully encoded OutgoingMessage.", .{});

        var payload = try msgpack.Payload.arrPayload(2, allocator);
        try payload.setArrElement(0, msgpack.Payload.intToPayload(@intFromEnum(code_val)));
        try payload.setArrElement(1, body_payload);
        log.debug("Constructed final payload for OutgoingMessage.", .{});
        return payload;
    }
};
