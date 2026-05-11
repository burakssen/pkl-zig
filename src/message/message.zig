const std = @import("std");
const msgpack = @import("msgpack");

pub const errors = @import("errors.zig");
pub const utils = @import("utils.zig");

const incoming = @import("incoming/incoming.zig");
const outgoing = @import("outgoing/outgoing.zig");

const Message = struct {
    pub const Incoming = incoming.IncomingMessage;
    pub const Outgoing = outgoing.OutgoingMessage;
};

test "decode CreateEvaluatorResponse" {
    const allocator = std.testing.allocator;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed(&buffer);
    var packer: msgpack.PackerIO = msgpack.PackerIO.init(&reader, &writer);

    var arr = try msgpack.Payload.arrPayload(2, allocator);
    defer arr.free(allocator);

    try arr.setArrElement(0, msgpack.Payload.intToPayload(@intFromEnum(incoming.code.Code.new_evaluator_response)));
    var map = msgpack.Payload.mapPayload(allocator);

    try map.mapPut("requestId", msgpack.Payload.intToPayload(100));
    try map.mapPut("evaluatorId", msgpack.Payload.intToPayload(200));
    try map.mapPut("error", try msgpack.Payload.strToPayload("", allocator));
    try arr.setArrElement(1, map);
    try packer.packer.write(arr);

    reader.seek = 0;
    var payload = try packer.packer.read(allocator);
    defer payload.free(allocator);

    const msg = try incoming.IncomingMessage.decode(allocator, &payload);
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

    try arr.setArrElement(0, msgpack.Payload.intToPayload(@intFromEnum(incoming.code.Code.evaluate_response)));
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

    const msg = try incoming.IncomingMessage.decode(allocator, &payload);
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

    try arr.setArrElement(0, msgpack.Payload.intToPayload(@intFromEnum(incoming.code.Code.evaluate_response)));
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

    const msg = try incoming.IncomingMessage.decode(allocator, &payload);
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

test "utils FromPayload decodes required optional and bool fields" {
    const allocator = std.testing.allocator;

    var payload = msgpack.Payload.mapPayload(allocator);
    defer payload.free(allocator);

    try payload.mapPut("scheme", try msgpack.Payload.strToPayload("customfs:", allocator));
    try payload.mapPut("hasHierarchicalUris", msgpack.Payload.boolToPayload(true));
    try payload.mapPut("isGlobbable", msgpack.Payload.boolToPayload(false));
    try payload.mapPut("isLocal", msgpack.Payload.boolToPayload(true));

    const reader = try utils.FromPayload(outgoing.types.ModuleReader, allocator, &payload);
    try std.testing.expectEqualStrings("customfs:", reader.scheme);
    try std.testing.expect(reader.has_hierarchical_uris);
    try std.testing.expect(!reader.is_globbable);
    try std.testing.expect(reader.is_local);
}

test "utils FromPayload rejects missing required fields and accepts missing optionals" {
    const allocator = std.testing.allocator;

    var missing_required = msgpack.Payload.mapPayload(allocator);
    defer missing_required.free(allocator);
    try std.testing.expectError(errors.DecodeError.MissingField, utils.FromPayload(incoming.types.ReadResource, allocator, &missing_required));

    var response_payload = msgpack.Payload.mapPayload(allocator);
    defer response_payload.free(allocator);
    try response_payload.mapPut("requestId", msgpack.Payload.intToPayload(1));
    const response = try utils.FromPayload(incoming.types.CreateEvaluatorResponse, allocator, &response_payload);
    try std.testing.expectEqual(@as(i64, 1), response.request_id);
    try std.testing.expect(response.evaluator_id == null);
    try std.testing.expect(response.@"error" == null);
}

test "utils FromPayload decodes nested structs and slices" {
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

    const response = try utils.FromPayload(outgoing.types.ListModulesResponse, arena_allocator, &payload);
    try std.testing.expectEqual(@as(i64, 5), response.request_id);
    try std.testing.expectEqual(@as(i64, 9), response.evaluator_id);
    try std.testing.expectEqual(@as(usize, 2), response.path_elements.?.len);
    try std.testing.expectEqualStrings("a.pkl", response.path_elements.?[0].name);
    try std.testing.expect(!response.path_elements.?[0].is_directory);
    try std.testing.expectEqualStrings("pkg", response.path_elements.?[1].name);
    try std.testing.expect(response.path_elements.?[1].is_directory);
}

test "utils ToPayload and FromPayload handle string hash maps" {
    const allocator = std.testing.allocator;

    var source = std.StringHashMap([]const u8).init(allocator);
    defer source.deinit();
    try source.put("one", "eins");
    try source.put("two", "zwei");

    var payload = try utils.ToPayload(allocator, source);
    defer payload.free(allocator);

    var decoded = try utils.FromPayload(std.StringHashMap([]const u8), allocator, &payload);
    defer decoded.deinit();

    try std.testing.expectEqualStrings("eins", decoded.get("one").?);
    try std.testing.expectEqualStrings("zwei", decoded.get("two").?);
}

test "utils ToPayload uses protocol string and binary field encodings" {
    const allocator = std.testing.allocator;

    var resource = try utils.ToPayload(allocator, outgoing.types.ReadResourceResponse{
        .request_id = 1,
        .evaluator_id = 2,
        .contents = "bytes",
    });
    defer resource.free(allocator);
    const resource_contents = (try resource.mapGet("contents")).?;
    try std.testing.expect(resource_contents == .bin);
    try std.testing.expectEqualStrings("bytes", try resource_contents.asBin());

    var module = try utils.ToPayload(allocator, outgoing.types.ReadModuleResponse{
        .request_id = 1,
        .evaluator_id = 2,
        .contents = "module text",
    });
    defer module.free(allocator);
    const module_contents = (try module.mapGet("contents")).?;
    try std.testing.expect(module_contents == .str);
    try std.testing.expectEqualStrings("module text", try module_contents.asStr());
}

test "utils ToPayload encodes nested CreateEvaluator fields and omits null optionals" {
    const allocator = std.testing.allocator;

    const evaluator = outgoing.types.CreateEvaluator{
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

    var payload = try utils.ToPayload(allocator, evaluator);
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

test "pkl server session: init -> response" {
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
        const ce = outgoing.types.CreateEvaluator{
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
        var msg = outgoing.OutgoingMessage{ .create_evaluator = ce };

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

            const message = try incoming.IncomingMessage.decode(allocator, &payload);
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
