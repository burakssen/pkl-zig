// consolidated message codec with error definitions and lean reflection helpers
const std = @import("std");
const msgpack = @import("msgpack");

const Code = @import("code.zig").Code;

/// Errors that can occur during message decoding.
pub const DecodeError = error{
    UnknownMessageCode,
    InvalidArrayLength,
    DecodeFailure,
    MissingField,
    InvalidType,
};

/// Errors that can occur during message encoding.
pub const EncodeError = error{
    EncodeFailure,
    UnsupportedType,
    MapPutFailed,
    ArrayElementSetFailed,
};

pub const Frame = struct {
    code: Code,
    body: msgpack.Payload,
};

pub fn decodeFrame(payload: *msgpack.Payload) !Frame {
    const len = try payload.getArrLen();
    if (len != 2) return DecodeError.InvalidArrayLength;
    const code_payload = try payload.getArrElement(0);
    const code = std.enums.fromInt(Code, try code_payload.getInt()) orelse {
        return DecodeError.UnknownMessageCode;
    };

    return .{
        .code = code,
        .body = try payload.getArrElement(1),
    };
}

pub fn encodeFrame(allocator: std.mem.Allocator, code: Code, body: msgpack.Payload) !msgpack.Payload {
    var body_payload = body;
    errdefer body_payload.free(allocator);
    var payload = try msgpack.Payload.arrPayload(2, allocator);
    errdefer payload.free(allocator);

    try payload.setArrElement(0, msgpack.Payload.intToPayload(@intFromEnum(code)));
    try payload.setArrElement(1, body_payload);
    return payload;
}

/// Converts a snake_case string to camelCase at comptime.
/// Special case for "error" field.
pub fn snakeToCamel(comptime input: []const u8) []const u8 {
    if (std.mem.eql(u8, input, "error")) return "error";
    comptime {
        var output: [input.len]u8 = undefined;
        var out_idx: usize = 0;
        var capitalize_next = false;

        for (input) |c| {
            if (c == '_') {
                capitalize_next = true;
            } else {
                output[out_idx] = if (capitalize_next) std.ascii.toUpper(c) else c;
                capitalize_next = false;
                out_idx += 1;
            }
        }

        const final = output[0..out_idx].*;
        return &final;
    }
}

/// Decodes a msgpack map payload into a value of type T.
///
/// Ownership invariant:
/// - scalar []const u8/[]u8 fields borrow from the input payload storage;
/// - non-byte slices, one-pointers, and StringHashMap storage are allocated
///   with `allocator` and owned by the decoded result;
/// - on failure, every allocation created by this decode is released;
/// - on success, call `deinitDecoded` when the decoded value is no longer
///   needed if T can contain codec-owned allocations.
pub fn fromPayload(comptime T: type, allocator: std.mem.Allocator, payload: *msgpack.Payload) !T {
    return fromPayloadValue(T, allocator, payload.*);
}

/// Recursively releases allocations owned by a value returned from
/// `fromPayload`.
///
/// Scalar []const u8/[]u8 values are borrowed from the source msgpack payload
/// and are deliberately not freed here. StringHashMap keys are borrowed as
/// well; map values are recursively deinitialized.
pub fn deinitDecoded(comptime T: type, allocator: std.mem.Allocator, value: T) void {
    if (comptime isStringHashMap(T)) {
        const Value = stringHashMapValueType(T);
        var map = value;
        var it = map.iterator();
        while (it.next()) |entry| {
            deinitDecoded(Value, allocator, entry.value_ptr.*);
        }
        map.deinit();
        return;
    }

    switch (@typeInfo(T)) {
        .@"struct" => {
            inline for (std.meta.fields(T)) |field| {
                deinitDecoded(field.type, allocator, @field(value, field.name));
            }
        },
        .optional => |optional_info| {
            if (value) |child| {
                deinitDecoded(optional_info.child, allocator, child);
            }
        },
        .pointer => |pointer_info| switch (pointer_info.size) {
            .slice => {
                if (pointer_info.child == u8) return;

                for (value) |item| {
                    deinitDecoded(pointer_info.child, allocator, item);
                }
                allocator.free(value);
            },
            .one => {
                deinitDecoded(pointer_info.child, allocator, value.*);
                allocator.destroy(value);
            },
            else => {},
        },
        .array => |array_info| {
            for (value) |item| {
                deinitDecoded(array_info.child, allocator, item);
            }
        },
        else => {},
    }
}

fn fromPayloadValue(comptime T: type, allocator: std.mem.Allocator, payload: msgpack.Payload) !T {
    if (comptime isStringHashMap(T)) {
        return fromPayloadStringHashMap(T, allocator, payload);
    }
    return switch (@typeInfo(T)) {
        .@"struct" => fromPayloadStruct(T, allocator, payload),
        .int => decodeInt(T, payload),
        .bool => try payload.asBool(),
        .float => decodeFloat(T, payload),
        .optional => |optional_info| blk: {
            if (payload.isNil()) break :blk null;
            break :blk try fromPayloadValue(optional_info.child, allocator, payload);
        },
        .pointer => |pointer_info| decodePointer(T, pointer_info, allocator, payload),
        .array => |array_info| blk: {
            const len = try payload.getArrLen();
            if (len != array_info.len) return DecodeError.InvalidArrayLength;

            var result: T = undefined;
            var initialized: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < initialized) : (i += 1) {
                    deinitDecoded(array_info.child, allocator, result[i]);
                }
            }

            for (&result, 0..) |*item, i| {
                const elem = try payload.getArrElement(i);
                item.* = try fromPayloadValue(array_info.child, allocator, elem);
                initialized += 1;
            }
            break :blk result;
        },
        else => @compileError("Unsupported type for decoding: " ++ @typeName(T)),
    };
}

fn fromPayloadStruct(comptime T: type, allocator: std.mem.Allocator, payload: msgpack.Payload) !T {
    if (payload != .map) return error.NotMap;

    var result: T = undefined;
    var initialized: usize = 0;
    errdefer {
        inline for (std.meta.fields(T), 0..) |field, field_index| {
            if (field_index < initialized) {
                deinitDecoded(field.type, allocator, @field(result, field.name));
            }
        }
    }

    inline for (std.meta.fields(T)) |field| {
        const key = comptime snakeToCamel(field.name);
        const maybe_field_payload = try payload.mapGet(key);
        if (maybe_field_payload) |field_payload| {
            @field(result, field.name) = try fromPayloadValue(field.type, allocator, field_payload);
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            return DecodeError.MissingField;
        }
        initialized += 1;
    }

    return result;
}

fn decodePointer(
    comptime T: type,
    comptime pointer_info: std.builtin.Type.Pointer,
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
) !T {
    switch (pointer_info.size) {
        .slice => {
            if (pointer_info.child == u8) {
                if (payload == .bin) return try payload.asBin();
                if (!pointer_info.is_const) return DecodeError.InvalidType;
                return try payload.asStr();
            }

            const len = try payload.getArrLen();
            const slice = try allocator.alloc(pointer_info.child, len);
            var initialized: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < initialized) : (i += 1) {
                    deinitDecoded(pointer_info.child, allocator, slice[i]);
                }
                allocator.free(slice);
            }

            for (slice, 0..) |*item, i| {
                const elem = try payload.getArrElement(i);
                item.* = try fromPayloadValue(pointer_info.child, allocator, elem);
                initialized += 1;
            }
            return slice;
        },
        .one => {
            const ptr = try allocator.create(pointer_info.child);
            errdefer allocator.destroy(ptr);
            ptr.* = try fromPayloadValue(pointer_info.child, allocator, payload);
            return ptr;
        },
        else => @compileError("Unsupported pointer type for decoding: " ++ @typeName(T)),
    }
}

fn decodeInt(comptime T: type, payload: msgpack.Payload) !T {
    const value = try payload.getInt();
    return std.math.cast(T, value) orelse DecodeError.InvalidType;
}

fn decodeFloat(comptime T: type, payload: msgpack.Payload) !T {
    const value = try payload.asFloat();
    return @floatCast(value);
}

fn fromPayloadStringHashMap(comptime T: type, allocator: std.mem.Allocator, payload: msgpack.Payload) !T {
    if (payload != .map) return error.NotMap;

    const Value = stringHashMapValueType(T);
    var result = T.init(allocator);
    errdefer deinitDecoded(T, allocator, result);

    var it = payload.map.map.iterator();
    while (it.next()) |entry| {
        const key = try entry.key_ptr.asStr();
        const value = try fromPayloadValue(Value, allocator, entry.value_ptr.*);
        errdefer deinitDecoded(Value, allocator, value);
        try result.put(key, value);
    }

    return result;
}

/// Encodes a value into a msgpack payload.
pub fn toPayload(allocator: std.mem.Allocator, value: anytype) (EncodeError || std.mem.Allocator.Error)!msgpack.Payload {
    return toPayloadValue(allocator, value, false);
}

fn toPayloadValue(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime encode_u8_slice_as_bin: bool,
) (EncodeError || std.mem.Allocator.Error)!msgpack.Payload {
    const T = @TypeOf(value);
    if (comptime isStringHashMap(T)) {
        var map = msgpack.Payload.mapPayload(allocator);
        errdefer map.free(allocator);

        var it = value.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            const v_payload = try toPayloadValue(allocator, v, false);
            try mapPut(&map, allocator, k, v_payload);
        }

        return map;
    }
    return switch (@typeInfo(T)) {
        .@"struct" => encodeStruct(allocator, value),
        .int => msgpack.Payload.intToPayload(std.math.cast(i64, value) orelse return EncodeError.EncodeFailure),
        .float => msgpack.Payload.floatToPayload(@floatCast(value)),
        .bool => msgpack.Payload.boolToPayload(value),
        .pointer => |ptr_info| encodePointer(allocator, value, ptr_info, encode_u8_slice_as_bin),
        .array => encodeArray(allocator, value, encode_u8_slice_as_bin),
        .@"union" => encodeUnion(allocator, value, encode_u8_slice_as_bin),
        .optional => {
            if (value) |v| {
                return toPayloadValue(allocator, v, encode_u8_slice_as_bin);
            }
            return msgpack.Payload.nilToPayload();
        },
        else => @compileError("Unsupported type for encoding: " ++ @typeName(T)),
    };
}

fn encodeArray(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime encode_u8_slice_as_bin: bool,
) !msgpack.Payload {
    const T = @TypeOf(value);
    const array_info = @typeInfo(T).array;

    if (array_info.child == u8) {
        const bytes: []const u8 = &value;
        if (encode_u8_slice_as_bin) {
            return msgpack.Payload.binToPayload(bytes, allocator) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return EncodeError.EncodeFailure;
            };
        }
        return msgpack.Payload.strToPayload(bytes, allocator) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return EncodeError.EncodeFailure;
        };
    }

    var arr = msgpack.Payload.arrPayload(array_info.len, allocator) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return EncodeError.EncodeFailure;
    };
    errdefer arr.free(allocator);

    for (value, 0..) |item, i| {
        const item_payload = try toPayloadValue(allocator, item, false);
        arr.setArrElement(i, item_payload) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return EncodeError.ArrayElementSetFailed;
        };
    }

    return arr;
}

fn encodeUnion(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime encode_u8_slice_as_bin: bool,
) !msgpack.Payload {
    return switch (value) {
        inline else => |payload| toPayloadValue(allocator, payload, encode_u8_slice_as_bin),
    };
}

fn encodeStruct(allocator: std.mem.Allocator, value: anytype) !msgpack.Payload {
    const T = @TypeOf(value);
    var map = msgpack.Payload.mapPayload(allocator);
    errdefer map.free(allocator);
    inline for (std.meta.fields(T)) |field| {
        const field_val = @field(value, field.name);
        const key = comptime snakeToCamel(field.name);
        const field_is_bin = comptime isBinField(T, field.name);
        if (@typeInfo(field.type) == .optional) {
            if (field_val) |v| {
                const v_payload = try toPayloadValue(allocator, v, field_is_bin);
                try mapPut(&map, allocator, key, v_payload);
            }
        } else {
            const field_payload = try toPayloadValue(allocator, field_val, field_is_bin);
            try mapPut(&map, allocator, key, field_payload);
        }
    }

    return map;
}

fn encodePointer(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime ptr_info: std.builtin.Type.Pointer,
    comptime encode_u8_slice_as_bin: bool,
) !msgpack.Payload {
    switch (ptr_info.size) {
        .slice => {
            if (ptr_info.child == u8) {
                if (encode_u8_slice_as_bin) {
                    return msgpack.Payload.binToPayload(value, allocator) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                        return EncodeError.EncodeFailure;
                    };
                }
                return msgpack.Payload.strToPayload(value, allocator) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    return EncodeError.EncodeFailure;
                };
            }
            var arr = msgpack.Payload.arrPayload(value.len, allocator) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return EncodeError.EncodeFailure;
            };
            errdefer arr.free(allocator);
            for (value, 0..) |item, i| {
                const item_payload = try toPayloadValue(allocator, item, false);
                arr.setArrElement(i, item_payload) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    return EncodeError.ArrayElementSetFailed;
                };
            }
            return arr;
        },
        .one => return toPayloadValue(allocator, value.*, encode_u8_slice_as_bin),
        else => @compileError("Unsupported pointer type for encoding: " ++ @typeName(@TypeOf(value))),
    }
}

fn mapPut(map: *msgpack.Payload, allocator: std.mem.Allocator, key: []const u8, value: msgpack.Payload) !void {
    errdefer value.free(allocator);
    map.mapPut(key, value) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return EncodeError.MapPutFailed;
    };
}

fn isBinField(comptime Parent: type, comptime field_name: []const u8) bool {
    const parent_name = @typeName(Parent);
    return (std.mem.endsWith(u8, parent_name, ".EvaluateResponse") and std.mem.eql(u8, field_name, "result")) or
        (std.mem.endsWith(u8, parent_name, ".ReadResourceResponse") and std.mem.eql(u8, field_name, "contents")) or
        (std.mem.endsWith(u8, parent_name, ".Http") and std.mem.eql(u8, field_name, "ca_certificates"));
}

fn isStringHashMap(comptime T: type) bool {
    return std.mem.startsWith(u8, @typeName(T), "hash_map.HashMap(") and
        std.mem.indexOf(u8, @typeName(T), "hash_map.StringContext") != null;
}

fn stringHashMapValueType(comptime T: type) type {
    if (@hasDecl(T, "Value")) return T.Value;
    const KV = @field(T, "KV");
    const info = @typeInfo(KV).@"struct";
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, "value")) {
            return field.type;
        }
    }
    @compileError("Unable to determine StringHashMap value type: " ++ @typeName(T));
}

test "toPayload encodes fixed arrays without pointer recursion" {
    const allocator = std.testing.allocator;

    const values = [_]u16{ 1, 2, 3 };
    var payload = try toPayload(allocator, values);
    defer payload.free(allocator);

    try std.testing.expectEqual(@as(usize, 3), try payload.getArrLen());
    try std.testing.expectEqual(@as(i64, 1), try (try payload.getArrElement(0)).getInt());
    try std.testing.expectEqual(@as(i64, 2), try (try payload.getArrElement(1)).getInt());
    try std.testing.expectEqual(@as(i64, 3), try (try payload.getArrElement(2)).getInt());
}

test "fromPayload cleans partially decoded struct fields on failure" {
    const allocator = std.testing.allocator;

    const Target = struct {
        rows: [][]u16,
        required: u8,
    };
    const Source = struct {
        rows: []const []const i64,
    };

    const row = [_]i64{ 1, 2, 3 };
    const rows = [_][]const i64{row[0..]};
    const source = Source{ .rows = rows[0..] };

    var payload = try toPayload(allocator, source);
    defer payload.free(allocator);

    try std.testing.expectError(
        DecodeError.MissingField,
        fromPayload(Target, allocator, &payload),
    );
}

test "fromPayload cleans nested slice elements on failure" {
    const allocator = std.testing.allocator;

    const first = [_]i64{ 1, 2 };
    const second = [_]i64{70_000};
    const rows = [_][]const i64{ first[0..], second[0..] };

    var payload = try toPayload(allocator, rows);
    defer payload.free(allocator);

    try std.testing.expectError(
        DecodeError.InvalidType,
        fromPayload([][]u16, allocator, &payload),
    );
}

test "fromPayload cleans partially decoded arrays on failure" {
    const allocator = std.testing.allocator;

    const first = [_]i64{ 1, 2 };
    const second = [_]i64{70_000};
    const rows = [_][]const i64{ first[0..], second[0..] };

    var payload = try toPayload(allocator, rows);
    defer payload.free(allocator);

    try std.testing.expectError(
        DecodeError.InvalidType,
        fromPayload([2][]u16, allocator, &payload),
    );
}

test "fromPayload cleans StringHashMap values on failure" {
    const allocator = std.testing.allocator;

    const good = [_]i64{ 1, 2 };
    const bad = [_]i64{70_000};

    var source = std.StringHashMap([]const i64).init(allocator);
    defer source.deinit();
    try source.put("good", good[0..]);
    try source.put("bad", bad[0..]);

    var payload = try toPayload(allocator, source);
    defer payload.free(allocator);

    try std.testing.expectError(
        DecodeError.InvalidType,
        fromPayload(std.StringHashMap([]u16), allocator, &payload),
    );
}

test "deinitDecoded releases successful generic decode allocations" {
    const allocator = std.testing.allocator;

    const first = [_]i64{ 1, 2 };
    const second = [_]i64{ 3, 4 };
    const rows = [_][]const i64{ first[0..], second[0..] };

    var payload = try toPayload(allocator, rows);
    defer payload.free(allocator);

    const decoded = try fromPayload([][]u16, allocator, &payload);
    defer deinitDecoded([][]u16, allocator, decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, decoded[0]);
    try std.testing.expectEqualSlices(u16, &.{ 3, 4 }, decoded[1]);
}
