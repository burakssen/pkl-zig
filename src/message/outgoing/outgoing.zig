const std = @import("std");
const msgpack = @import("msgpack");

const message = @import("message");
const Code = message.Code;
const codec = message.codec;
const types = @import("types.zig");

pub const ResourceReader = types.ResourceReader;
pub const ModuleReader = types.ModuleReader;
pub const Checksums = types.Checksums;
pub const Project = types.Project;
pub const ProjectOrDependency = types.ProjectOrDependency;
pub const RemoteDependency = types.RemoteDependency;
pub const Proxy = types.Proxy;
pub const HeaderMap = types.HeaderMap;
pub const Headers = types.Headers;
pub const Http = types.Http;
pub const ExternalReader = types.ExternalReader;
pub const CreateEvaluator = types.CreateEvaluator;
pub const CloseEvaluator = types.CloseEvaluator;
pub const Evaluate = types.Evaluate;
pub const ReadResourceResponse = types.ReadResourceResponse;
pub const ReadModuleResponse = types.ReadModuleResponse;
pub const PathElement = types.PathElement;
pub const ListResourcesResponse = types.ListResourcesResponse;
pub const ListModulesResponse = types.ListModulesResponse;
pub const InitializeModuleReaderResponse = types.InitializeModuleReaderResponse;
pub const InitializeResourceReaderResponse = types.InitializeResourceReaderResponse;

const log = std.log.scoped(.@"pkl-zig|message|outgoing");

/// Represents any message sent to Pkl.
pub const Message = union(enum) {
    create_evaluator: types.CreateEvaluator,
    close_evaluator: types.CloseEvaluator,
    evaluate: types.Evaluate,
    read_resource_response: types.ReadResourceResponse,
    read_module_response: types.ReadModuleResponse,
    list_resources_response: types.ListResourcesResponse,
    list_modules_response: types.ListModulesResponse,
    initialize_module_reader_response: types.InitializeModuleReaderResponse,
    initialize_resource_reader_response: types.InitializeResourceReaderResponse,

    /// Encodes an outgoing message into a msgpack payload frame.
    pub fn encode(self: Message, allocator: std.mem.Allocator) !msgpack.Payload {
        log.debug("Encoding outgoing message of type {s}.", .{@tagName(self)});
        const body = switch (self) {
            .create_evaluator => |msg| try codec.toPayload(allocator, msg),
            .close_evaluator => |msg| try codec.toPayload(allocator, msg),
            .evaluate => |msg| try codec.toPayload(allocator, msg),
            .read_resource_response => |msg| try codec.toPayload(allocator, msg),
            .read_module_response => |msg| try codec.toPayload(allocator, msg),
            .list_resources_response => |msg| try codec.toPayload(allocator, msg),
            .list_modules_response => |msg| try codec.toPayload(allocator, msg),
            .initialize_module_reader_response => |msg| try codec.toPayload(allocator, msg),
            .initialize_resource_reader_response => |msg| try codec.toPayload(allocator, msg),
        };

        return codec.encodeFrame(allocator, self.code(), body);
    }

    pub fn code(self: Message) Code {
        return switch (self) {
            .create_evaluator => .new_evaluator,
            .close_evaluator => .close_evaluator,
            .evaluate => .evaluate,
            .read_resource_response => .evaluate_read_response,
            .read_module_response => .evaluate_read_module_response,
            .list_resources_response => .list_resources_response,
            .list_modules_response => .list_modules_response,
            .initialize_module_reader_response => .initialize_module_reader_response,
            .initialize_resource_reader_response => .initialize_resource_reader_response,
        };
    }
};
