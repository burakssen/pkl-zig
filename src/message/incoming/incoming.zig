const std = @import("std");
const msgpack = @import("msgpack");

const message = @import("message");
const utils = message.utils;
const errors = message.errors;

pub const code = @import("code.zig");
pub const types = @import("types.zig");

const log = std.log.scoped(.@"pkl-zig|message|incoming");

/// Represents any message received from Pkl.
pub const IncomingMessage = union(enum) {
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

    pub fn decode(allocator: std.mem.Allocator, payload: *msgpack.Payload) !IncomingMessage {
        log.debug("Decoding IncomingMessage from payload.", .{});
        // 1. Decode the outer array length (e.g., [code, body])
        const len = try payload.getArrLen();
        if (len < 2) return errors.DecodeError.InvalidArrayLength;

        // 2. Decode the integer code
        const code_payload = try payload.getArrElement(0);

        // 3. Safely convert integer to Enum
        const code_val = std.enums.fromInt(code.Code, try code_payload.getInt()) orelse {
            return errors.DecodeError.UnknownMessageCode;
        };

        log.debug("Decoded message code: [{s}.{s}] = {d}.", .{ @typeName(@TypeOf(code_val)), @tagName(code_val), code_val });

        // 4. Get the body payload (the second element in the array)
        var body_payload = try payload.getArrElement(1);

        // 5. Switch on the code to decode the specific payload
        switch (code_val) {
            .new_evaluator_response => return .{ .create_evaluator_response = try utils.FromPayload(types.CreateEvaluatorResponse, allocator, &body_payload) },
            .evaluate_response => return .{ .evaluate_response = try utils.FromPayload(types.EvaluateResponse, allocator, &body_payload) },
            .evaluate_log => return .{ .log = try utils.FromPayload(types.Log, allocator, &body_payload) },
            .evaluate_read => return .{ .read_resource = try utils.FromPayload(types.ReadResource, allocator, &body_payload) },
            .evaluate_read_module => return .{ .read_module = try utils.FromPayload(types.ReadModule, allocator, &body_payload) },
            .list_resources_request => return .{ .list_resources = try utils.FromPayload(types.ListResources, allocator, &body_payload) },
            .list_modules_request => return .{ .list_modules = try utils.FromPayload(types.ListModules, allocator, &body_payload) },
            .initialize_module_reader_request => return .{ .initialize_module_reader = try utils.FromPayload(types.InitializeModuleReader, allocator, &body_payload) },
            .initialize_resource_reader_request => return .{ .initialize_resource_reader = try utils.FromPayload(types.InitializeResourceReader, allocator, &body_payload) },
            .close_external_process => return .{ .close_external_process = try utils.FromPayload(types.CloseExternalProcess, allocator, &body_payload) },
        }

        log.debug("Successfully decoded IncomingMessage.", .{});
    }
};
