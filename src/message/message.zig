const std = @import("std");
const msgpack = @import("msgpack");
const build_options = @import("build_options");

pub const errors = @import("errors.zig");
pub const Code = @import("code.zig").Code;
pub const codec = @import("codec.zig");
pub const incoming = @import("incoming/incoming.zig");
pub const outgoing = @import("outgoing/outgoing.zig");

pub const Incoming = incoming.Message;
pub const Outgoing = outgoing.Message;

fn framePayload(allocator: std.mem.Allocator, code: i64, body: msgpack.Payload) !msgpack.Payload {
    var payload = try msgpack.Payload.arrPayload(2, allocator);
    try payload.setArrElement(0, msgpack.Payload.intToPayload(code));
    try payload.setArrElement(1, body);
    return payload;
}

test "decode CreateEvaluatorResponse" {
    const allocator = std.testing.allocator;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed(&buffer);
    var packer: msgpack.PackerIO = msgpack.PackerIO.init(&reader, &writer);

    var arr = try msgpack.Payload.arrPayload(2, allocator);
    defer arr.free(allocator);

    try arr.setArrElement(0, msgpack.Payload.intToPayload(@intFromEnum(Code.new_evaluator_response)));
    var map = msgpack.Payload.mapPayload(allocator);

    try map.mapPut("requestId", msgpack.Payload.intToPayload(100));
    try map.mapPut("evaluatorId", msgpack.Payload.intToPayload(200));
    try map.mapPut("error", try msgpack.Payload.strToPayload("", allocator));
    try arr.setArrElement(1, map);
    try packer.packer.write(arr);

    reader.seek = 0;
    var payload = try packer.packer.read(allocator);
    defer payload.free(allocator);

    const msg = try Incoming.decode(allocator, &payload);
    switch (msg) {
        .create_evaluator_response => |resp| {
            try std.testing.expectEqual(resp.request_id, 100);
            try std.testing.expectEqual(@as(i64, 200), resp.evaluator_id.?);
            if (resp.@"error") |err| {
                try std.testing.expectEqualStrings(err, "");
            } else {
                try std.testing.expect(true);
            }
        },
        else => try std.testing.expect(false),
    }
}

test "decode EvaluateResponse" {
    const allocator = std.testing.allocator;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed(&buffer);
    var packer: msgpack.PackerIO = msgpack.PackerIO.init(&reader, &writer);

    var arr = try msgpack.Payload.arrPayload(2, allocator);
    defer arr.free(allocator);

    try arr.setArrElement(0, msgpack.Payload.intToPayload(@intFromEnum(Code.evaluate_response)));
    var map = msgpack.Payload.mapPayload(allocator);

    try map.mapPut("requestId", msgpack.Payload.intToPayload(123));
    try map.mapPut("evaluatorId", msgpack.Payload.intToPayload(456));
    try map.mapPut("result", try msgpack.Payload.binToPayload("Hello World!", allocator));
    try map.mapPut("error", try msgpack.Payload.strToPayload("No error", allocator));
    try arr.setArrElement(1, map);
    try packer.packer.write(arr);

    reader.seek = 0;
    var payload = try packer.packer.read(allocator);
    defer payload.free(allocator);

    const msg = try Incoming.decode(allocator, &payload);
    switch (msg) {
        .evaluate_response => |resp| {
            try std.testing.expectEqual(resp.request_id, 123);
            try std.testing.expectEqual(resp.evaluator_id, 456);
            try std.testing.expectEqualStrings(resp.result.?, "Hello World!");
            if (resp.@"error") |err| {
                try std.testing.expectEqualStrings(err, "No error");
            } else {
                try std.testing.expect(false);
            }
        },
        else => try std.testing.expect(false),
    }
}

test "decode EvaluateResponse with null result" {
    const allocator = std.testing.allocator;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed(&buffer);
    var packer: msgpack.PackerIO = msgpack.PackerIO.init(&reader, &writer);

    var arr = try msgpack.Payload.arrPayload(2, allocator);
    defer arr.free(allocator);

    try arr.setArrElement(0, msgpack.Payload.intToPayload(@intFromEnum(Code.evaluate_response)));
    var map = msgpack.Payload.mapPayload(allocator);

    try map.mapPut("requestId", msgpack.Payload.intToPayload(321));
    try map.mapPut("evaluatorId", msgpack.Payload.intToPayload(654));
    try map.mapPut("result", msgpack.Payload{ .nil = {} });
    try map.mapPut("error", try msgpack.Payload.strToPayload("boom", allocator));
    try arr.setArrElement(1, map);
    try packer.packer.write(arr);

    reader.seek = 0;
    var payload = try packer.packer.read(allocator);
    defer payload.free(allocator);

    const msg = try Incoming.decode(allocator, &payload);
    switch (msg) {
        .evaluate_response => |resp| {
            try std.testing.expectEqual(resp.request_id, 321);
            try std.testing.expectEqual(resp.evaluator_id, 654);
            try std.testing.expect(resp.result == null);
            if (resp.@"error") |err| {
                try std.testing.expectEqualStrings(err, "boom");
            } else {
                try std.testing.expect(false);
            }
        },
        else => try std.testing.expect(false),
    }
}

test "codec decodeFrame rejects malformed and unknown frames" {
    const allocator = std.testing.allocator;

    var too_long = try msgpack.Payload.arrPayload(3, allocator);
    defer too_long.free(allocator);
    try std.testing.expectError(errors.DecodeError.InvalidArrayLength, codec.decodeFrame(&too_long));

    const unknown_body = msgpack.Payload.mapPayload(allocator);
    var unknown = try framePayload(allocator, 0x99, unknown_body);
    defer unknown.free(allocator);
    try std.testing.expectError(errors.DecodeError.UnknownMessageCode, codec.decodeFrame(&unknown));
}

test "incoming decode maps every incoming code" {
    const allocator = std.testing.allocator;

    var create_body = msgpack.Payload.mapPayload(allocator);
    try create_body.mapPut("requestId", msgpack.Payload.intToPayload(1));
    var create_frame = try framePayload(allocator, @intFromEnum(Code.new_evaluator_response), create_body);
    defer create_frame.free(allocator);
    try std.testing.expect((try Incoming.decode(allocator, &create_frame)) == .create_evaluator_response);

    var eval_body = msgpack.Payload.mapPayload(allocator);
    try eval_body.mapPut("requestId", msgpack.Payload.intToPayload(1));
    try eval_body.mapPut("evaluatorId", msgpack.Payload.intToPayload(2));
    var eval_frame = try framePayload(allocator, @intFromEnum(Code.evaluate_response), eval_body);
    defer eval_frame.free(allocator);
    try std.testing.expect((try Incoming.decode(allocator, &eval_frame)) == .evaluate_response);

    var log_body = msgpack.Payload.mapPayload(allocator);
    try log_body.mapPut("evaluatorId", msgpack.Payload.intToPayload(2));
    try log_body.mapPut("level", msgpack.Payload.intToPayload(1));
    try log_body.mapPut("message", try msgpack.Payload.strToPayload("message", allocator));
    try log_body.mapPut("frameUri", try msgpack.Payload.strToPayload("file:///a.pkl", allocator));
    var log_frame = try framePayload(allocator, @intFromEnum(Code.evaluate_log), log_body);
    defer log_frame.free(allocator);
    try std.testing.expect((try Incoming.decode(allocator, &log_frame)) == .log);

    var read_body = msgpack.Payload.mapPayload(allocator);
    try read_body.mapPut("requestId", msgpack.Payload.intToPayload(1));
    try read_body.mapPut("evaluatorId", msgpack.Payload.intToPayload(2));
    try read_body.mapPut("uri", try msgpack.Payload.strToPayload("customfs:/resource", allocator));
    var read_frame = try framePayload(allocator, @intFromEnum(Code.evaluate_read), read_body);
    defer read_frame.free(allocator);
    try std.testing.expect((try Incoming.decode(allocator, &read_frame)) == .read_resource);

    var module_body = msgpack.Payload.mapPayload(allocator);
    try module_body.mapPut("requestId", msgpack.Payload.intToPayload(1));
    try module_body.mapPut("evaluatorId", msgpack.Payload.intToPayload(2));
    try module_body.mapPut("uri", try msgpack.Payload.strToPayload("customfs:/module.pkl", allocator));
    var module_frame = try framePayload(allocator, @intFromEnum(Code.evaluate_read_module), module_body);
    defer module_frame.free(allocator);
    try std.testing.expect((try Incoming.decode(allocator, &module_frame)) == .read_module);

    var list_resources_body = msgpack.Payload.mapPayload(allocator);
    try list_resources_body.mapPut("requestId", msgpack.Payload.intToPayload(1));
    try list_resources_body.mapPut("evaluatorId", msgpack.Payload.intToPayload(2));
    try list_resources_body.mapPut("uri", try msgpack.Payload.strToPayload("customfs:/", allocator));
    var list_resources_frame = try framePayload(allocator, @intFromEnum(Code.list_resources_request), list_resources_body);
    defer list_resources_frame.free(allocator);
    try std.testing.expect((try Incoming.decode(allocator, &list_resources_frame)) == .list_resources);

    var list_modules_body = msgpack.Payload.mapPayload(allocator);
    try list_modules_body.mapPut("requestId", msgpack.Payload.intToPayload(1));
    try list_modules_body.mapPut("evaluatorId", msgpack.Payload.intToPayload(2));
    try list_modules_body.mapPut("uri", try msgpack.Payload.strToPayload("customfs:/", allocator));
    var list_modules_frame = try framePayload(allocator, @intFromEnum(Code.list_modules_request), list_modules_body);
    defer list_modules_frame.free(allocator);
    try std.testing.expect((try Incoming.decode(allocator, &list_modules_frame)) == .list_modules);

    var init_module_body = msgpack.Payload.mapPayload(allocator);
    try init_module_body.mapPut("requestId", msgpack.Payload.intToPayload(1));
    try init_module_body.mapPut("scheme", try msgpack.Payload.strToPayload("customfs:", allocator));
    var init_module_frame = try framePayload(allocator, @intFromEnum(Code.initialize_module_reader_request), init_module_body);
    defer init_module_frame.free(allocator);
    try std.testing.expect((try Incoming.decode(allocator, &init_module_frame)) == .initialize_module_reader);

    var init_resource_body = msgpack.Payload.mapPayload(allocator);
    try init_resource_body.mapPut("requestId", msgpack.Payload.intToPayload(1));
    try init_resource_body.mapPut("scheme", try msgpack.Payload.strToPayload("customfs:", allocator));
    var init_resource_frame = try framePayload(allocator, @intFromEnum(Code.initialize_resource_reader_request), init_resource_body);
    defer init_resource_frame.free(allocator);
    try std.testing.expect((try Incoming.decode(allocator, &init_resource_frame)) == .initialize_resource_reader);

    const close_body = msgpack.Payload.mapPayload(allocator);
    var close_frame = try framePayload(allocator, @intFromEnum(Code.close_external_process), close_body);
    defer close_frame.free(allocator);
    try std.testing.expect((try Incoming.decode(allocator, &close_frame)) == .close_external_process);
}

test "outgoing messages map to protocol codes" {
    try std.testing.expectEqual(Code.new_evaluator, (Outgoing{ .create_evaluator = .{ .request_id = 1 } }).code());
    try std.testing.expectEqual(Code.close_evaluator, (Outgoing{ .close_evaluator = .{ .evaluator_id = 1 } }).code());
    try std.testing.expectEqual(Code.evaluate, (Outgoing{ .evaluate = .{ .request_id = 1, .evaluator_id = 2, .module_uri = "file:///a.pkl" } }).code());
    try std.testing.expectEqual(Code.evaluate_read_response, (Outgoing{ .read_resource_response = .{ .request_id = 1, .evaluator_id = 2 } }).code());
    try std.testing.expectEqual(Code.evaluate_read_module_response, (Outgoing{ .read_module_response = .{ .request_id = 1, .evaluator_id = 2 } }).code());
    try std.testing.expectEqual(Code.list_resources_response, (Outgoing{ .list_resources_response = .{ .request_id = 1, .evaluator_id = 2 } }).code());
    try std.testing.expectEqual(Code.list_modules_response, (Outgoing{ .list_modules_response = .{ .request_id = 1, .evaluator_id = 2 } }).code());
    try std.testing.expectEqual(Code.initialize_module_reader_response, (Outgoing{ .initialize_module_reader_response = .{ .request_id = 1 } }).code());
    try std.testing.expectEqual(Code.initialize_resource_reader_response, (Outgoing{ .initialize_resource_reader_response = .{ .request_id = 1 } }).code());
}

test "codec fromPayload decodes required optional and bool fields" {
    const allocator = std.testing.allocator;

    var payload = msgpack.Payload.mapPayload(allocator);
    defer payload.free(allocator);

    try payload.mapPut("scheme", try msgpack.Payload.strToPayload("customfs:", allocator));
    try payload.mapPut("hasHierarchicalUris", msgpack.Payload.boolToPayload(true));
    try payload.mapPut("isGlobbable", msgpack.Payload.boolToPayload(false));
    try payload.mapPut("isLocal", msgpack.Payload.boolToPayload(true));

    const reader = try codec.fromPayload(outgoing.ModuleReader, allocator, &payload);
    try std.testing.expectEqualStrings("customfs:", reader.scheme);
    try std.testing.expect(reader.has_hierarchical_uris);
    try std.testing.expect(!reader.is_globbable);
    try std.testing.expect(reader.is_local);
}

test "codec fromPayload rejects missing required fields and accepts missing optionals" {
    const allocator = std.testing.allocator;

    var missing_required = msgpack.Payload.mapPayload(allocator);
    defer missing_required.free(allocator);
    try std.testing.expectError(errors.DecodeError.MissingField, codec.fromPayload(incoming.ReadResource, allocator, &missing_required));

    var response_payload = msgpack.Payload.mapPayload(allocator);
    defer response_payload.free(allocator);
    try response_payload.mapPut("requestId", msgpack.Payload.intToPayload(1));
    const response = try codec.fromPayload(incoming.CreateEvaluatorResponse, allocator, &response_payload);
    try std.testing.expectEqual(@as(i64, 1), response.request_id);
    try std.testing.expect(response.evaluator_id == null);
    try std.testing.expect(response.@"error" == null);
}

test "codec fromPayload decodes nested structs and slices" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var payload = msgpack.Payload.mapPayload(allocator);
    defer payload.free(allocator);

    try payload.mapPut("requestId", msgpack.Payload.intToPayload(5));
    try payload.mapPut("evaluatorId", msgpack.Payload.intToPayload(9));

    var elements = try msgpack.Payload.arrPayload(2, allocator);
    var first = msgpack.Payload.mapPayload(allocator);
    try first.mapPut("name", try msgpack.Payload.strToPayload("a.pkl", allocator));
    try first.mapPut("isDirectory", msgpack.Payload.boolToPayload(false));
    try elements.setArrElement(0, first);

    var second = msgpack.Payload.mapPayload(allocator);
    try second.mapPut("name", try msgpack.Payload.strToPayload("pkg", allocator));
    try second.mapPut("isDirectory", msgpack.Payload.boolToPayload(true));
    try elements.setArrElement(1, second);

    try payload.mapPut("pathElements", elements);

    const response = try codec.fromPayload(outgoing.ListModulesResponse, arena_allocator, &payload);
    try std.testing.expectEqual(@as(i64, 5), response.request_id);
    try std.testing.expectEqual(@as(i64, 9), response.evaluator_id);
    try std.testing.expectEqual(@as(usize, 2), response.path_elements.?.len);
    try std.testing.expectEqualStrings("a.pkl", response.path_elements.?[0].name);
    try std.testing.expect(!response.path_elements.?[0].is_directory);
    try std.testing.expectEqualStrings("pkg", response.path_elements.?[1].name);
    try std.testing.expect(response.path_elements.?[1].is_directory);
}

test "codec toPayload and fromPayload handle string hash maps" {
    const allocator = std.testing.allocator;

    var source = std.StringHashMap([]const u8).init(allocator);
    defer source.deinit();
    try source.put("one", "eins");
    try source.put("two", "zwei");

    var payload = try codec.toPayload(allocator, source);
    defer payload.free(allocator);

    var decoded = try codec.fromPayload(std.StringHashMap([]const u8), allocator, &payload);
    defer decoded.deinit();

    try std.testing.expectEqualStrings("eins", decoded.get("one").?);
    try std.testing.expectEqualStrings("zwei", decoded.get("two").?);
}

test "codec toPayload uses protocol string and binary field encodings" {
    const allocator = std.testing.allocator;

    var resource = try codec.toPayload(allocator, outgoing.ReadResourceResponse{
        .request_id = 1,
        .evaluator_id = 2,
        .contents = "bytes",
    });
    defer resource.free(allocator);
    const resource_contents = (try resource.mapGet("contents")).?;
    try std.testing.expect(resource_contents == .bin);
    try std.testing.expectEqualStrings("bytes", try resource_contents.asBin());

    var module = try codec.toPayload(allocator, outgoing.ReadModuleResponse{
        .request_id = 1,
        .evaluator_id = 2,
        .contents = "module text",
    });
    defer module.free(allocator);
    const module_contents = (try module.mapGet("contents")).?;
    try std.testing.expect(module_contents == .str);
    try std.testing.expectEqualStrings("module text", try module_contents.asStr());
}

test "codec toPayload protocol edge field encoding checklist" {
    const allocator = std.testing.allocator;

    var http_payload = try codec.toPayload(allocator, outgoing.Http{
        .ca_certificates = "pem-bytes",
    });
    defer http_payload.free(allocator);
    const ca_certificates = (try http_payload.mapGet("caCertificates")).?;
    try std.testing.expect(ca_certificates == .bin);
    try std.testing.expectEqualStrings("pem-bytes", try ca_certificates.asBin());

    var evaluator_payload = try codec.toPayload(allocator, outgoing.CreateEvaluator{
        .request_id = 9,
        .trace_mode = "verbose",
    });
    defer evaluator_payload.free(allocator);
    try std.testing.expectEqualStrings("verbose", try (try evaluator_payload.mapGet("traceMode")).?.asStr());

    var error_payload = try codec.toPayload(allocator, outgoing.ReadModuleResponse{
        .request_id = 1,
        .evaluator_id = 2,
        .@"error" = "boom",
    });
    defer error_payload.free(allocator);
    try std.testing.expectEqualStrings("boom", try (try error_payload.mapGet("error")).?.asStr());
    try std.testing.expect((try error_payload.mapGet("Error")) == null);
}

test "codec toPayload encodes nested CreateEvaluator fields and omits null optionals" {
    const allocator = std.testing.allocator;

    const evaluator = outgoing.CreateEvaluator{
        .request_id = 135,
        .allowed_modules = &.{ "pkl:", "file:" },
        .client_module_readers = &.{
            .{
                .scheme = "customfs:",
                .has_hierarchical_uris = true,
                .is_globbable = true,
                .is_local = true,
            },
        },
    };

    var payload = try codec.toPayload(allocator, evaluator);
    defer payload.free(allocator);

    try std.testing.expect((try payload.mapGet("rootDir")) == null);

    const allowed_modules = (try payload.mapGet("allowedModules")).?;
    try std.testing.expectEqual(@as(usize, 2), try allowed_modules.getArrLen());
    try std.testing.expectEqualStrings("pkl:", try (try allowed_modules.getArrElement(0)).asStr());

    const module_readers = (try payload.mapGet("clientModuleReaders")).?;
    try std.testing.expectEqual(@as(usize, 1), try module_readers.getArrLen());
    const reader = try module_readers.getArrElement(0);
    try std.testing.expectEqualStrings("customfs:", try (try reader.mapGet("scheme")).?.asStr());
    try std.testing.expect((try reader.mapGet("isLocal")).?.bool);
}

test "codec toPayload encodes project dependency wire shape" {
    const allocator = std.testing.allocator;

    var dependencies = std.StringHashMap(*outgoing.ProjectOrDependency).init(allocator);
    defer dependencies.deinit();

    var checksums = outgoing.Checksums{ .sha256 = "abc123" };
    var dependency = outgoing.ProjectOrDependency{
        .remote_dependency = .{
            .package_uri = "package://example.com/demo@1.0.0",
            .checksums = &checksums,
        },
    };
    try dependencies.put("demo", &dependency);

    var project = outgoing.Project{
        .package_uri = "package://example.com/root@1.0.0",
        .project_file_uri = "file:///repo/PklProject",
        .dependencies = dependencies,
    };

    var payload = try codec.toPayload(allocator, outgoing.CreateEvaluator{
        .request_id = 7,
        .project = &project,
    });
    defer payload.free(allocator);

    const project_payload = (try payload.mapGet("project")).?;
    try std.testing.expectEqualStrings("local", try (try project_payload.mapGet("type")).?.asStr());
    try std.testing.expectEqualStrings("file:///repo/PklProject", try (try project_payload.mapGet("projectFileUri")).?.asStr());

    const dependencies_payload = (try project_payload.mapGet("dependencies")).?;
    const dependency_payload = (try dependencies_payload.mapGet("demo")).?;
    try std.testing.expectEqualStrings("remote", try (try dependency_payload.mapGet("type")).?.asStr());

    const checksums_payload = (try dependency_payload.mapGet("checksums")).?;
    try std.testing.expectEqualStrings("abc123", try (try checksums_payload.mapGet("sha256")).?.asStr());
}

test "pkl server session: init -> response" {
    if (!build_options.integration_tests) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // 1. Setup the Child Process
    var process: std.process.Child = try std.process.spawn(
        std.testing.io,
        .{
            .argv = &.{ "pkl", "server" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        },
    );
    defer if (process.id != null) process.kill(std.testing.io);

    {
        var write_buffer: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&write_buffer);

        var read_buffer: [1024]u8 = undefined;
        var reader: std.Io.Reader = .fixed(&read_buffer);

        var packer = msgpack.PackerIO.init(&reader, &writer);

        // Prepare Data
        const ce = outgoing.CreateEvaluator{
            .request_id = 135,
            .allowed_modules = &.{ "pkl:", "repl:", "file:", "customfs:" },
            .client_module_readers = &.{
                .{
                    .scheme = "customfs:",
                    .has_hierarchical_uris = true,
                    .is_globbable = true,
                    .is_local = true,
                },
            },
        };
        var msg = Outgoing{ .create_evaluator = ce };

        var payload = try msg.encode(allocator);
        defer payload.free(allocator);

        try packer.write(payload);

        const bytes_to_send = writer.buffered();

        if (process.stdin) |*stdin| {
            var buffer: [1024]u8 = undefined;
            var stdin_writer = stdin.writer(std.testing.io, &buffer);
            const w = &stdin_writer.interface;
            try w.writeAll(bytes_to_send);
            try w.flush();
            stdin.close(std.testing.io);
            process.stdin = null;
        }
    }

    {
        if (process.stdout) |*stdout| {
            var write_buffer: [1024]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&write_buffer);

            var read_buffer: [1024]u8 = undefined;
            var stdout_reader = stdout.reader(std.testing.io, &read_buffer);
            const reader = &stdout_reader.interface;

            var packer = msgpack.PackerIO.init(reader, &writer);
            var payload = try packer.read(allocator);
            defer payload.free(allocator);

            const message = try Incoming.decode(allocator, &payload);
            switch (message) {
                .create_evaluator_response => |resp| {
                    try std.testing.expectEqual(resp.request_id, 135);
                    try std.testing.expect(resp.evaluator_id != null);
                    try std.testing.expect(resp.evaluator_id.? != 0);
                },
                else => {},
            }
        }
    }

    switch (try process.wait(std.testing.io)) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => try std.testing.expect(false),
    }
}
