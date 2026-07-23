const std = @import("std");
const msgpack = @import("msgpack");

const errors = @import("errors.zig");
const Code = @import("code.zig").Code;

pub const Frame = struct {
    code: Code,
    body: msgpack.Payload,
};

pub fn decodeFrame(payload: *msgpack.Payload) !Frame {
    const len = try payload.getArrLen();
    if (len != 2) return errors.DecodeError.InvalidArrayLength;

    const code_payload = try payload.getArrElement(0);
    const code = std.enums.fromInt(Code, try code_payload.getInt()) orelse {
        return errors.DecodeError.UnknownMessageCode;
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

/// Converts a snake_case string to camelCase.
/// Special case for "error" field.
pub fn snakeToCamel(comptime input: []const u8) []const u8 {
    if (std.mem.eql(u8, input, "error")) return "error";

    comptime var out_len = 0;
    comptime var i = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '_') out_len += 1;
    }

    comptime var output: [out_len]u8 = undefined;
    i = 0;
    comptime var out_idx = 0;
    comptime var next_upper = false;

    while (i < input.len) : (i += 1) {
        if (input[i] == '_') {
            next_upper = true;
        } else {
            if (next_upper) {
                output[out_idx] = std.ascii.toUpper(input[i]);
                next_upper = false;
            } else {
                output[out_idx] = input[i];
            }
            out_idx += 1;
        }
    }

    const final = output;
    return &final;
}

/// Decodes a msgpack map payload into a struct of type T.
/// Ownership invariant: returned scalar []const u8/[]u8 fields borrow from the
/// input payload storage, so callers must keep the backing payload alive.
pub fn fromPayload(comptime T: type, allocator: std.mem.Allocator, payload: *msgpack.Payload) !T {
    return fromPayloadValue(T, allocator, payload.*);
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
            if (len != array_info.len) return errors.DecodeError.InvalidArrayLength;
            var result: T = undefined;
            for (&result, 0..) |*item, i| {
                const elem = try payload.getArrElement(i);
                item.* = try fromPayloadValue(array_info.child, allocator, elem);
            }
            break :blk result;
        },
        else => @compileError("Unsupported type for decoding: " ++ @typeName(T)),
    };
}

fn fromPayloadStruct(comptime T: type, allocator: std.mem.Allocator, payload: msgpack.Payload) !T {
    if (payload != .map) return error.NotMap;
    var result: T = undefined;

    inline for (std.meta.fields(T)) |field| {
        const key = comptime snakeToCamel(field.name);
        const maybe_field_payload = try payload.mapGet(key);

        if (maybe_field_payload) |field_payload| {
            @field(result, field.name) = try fromPayloadValue(field.type, allocator, field_payload);
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            return errors.DecodeError.MissingField;
        }
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
                if (!pointer_info.is_const) return errors.DecodeError.InvalidType;
                return try payload.asStr();
            }

            const len = try payload.getArrLen();
            const slice = try allocator.alloc(pointer_info.child, len);
            errdefer allocator.free(slice);

            for (slice, 0..) |*item, i| {
                const elem = try payload.getArrElement(i);
                item.* = try fromPayloadValue(pointer_info.child, allocator, elem);
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
    return std.math.cast(T, value) orelse errors.DecodeError.InvalidType;
}

fn decodeFloat(comptime T: type, payload: msgpack.Payload) !T {
    const value = try payload.asFloat();
    return @floatCast(value);
}

fn fromPayloadStringHashMap(comptime T: type, allocator: std.mem.Allocator, payload: msgpack.Payload) !T {
    if (payload != .map) return error.NotMap;

    const Value = stringHashMapValueType(T);
    var result = T.init(allocator);
    errdefer result.deinit();

    var it = payload.map.map.iterator();
    while (it.next()) |entry| {
        const key = try entry.key_ptr.asStr();
        const value = try fromPayloadValue(Value, allocator, entry.value_ptr.*);
        try result.put(key, value);
    }

    return result;
}

/// Encodes a value into a msgpack payload.
pub fn toPayload(allocator: std.mem.Allocator, value: anytype) (errors.EncodeError || std.mem.Allocator.Error)!msgpack.Payload {
    return toPayloadValue(allocator, value, false);
}

fn toPayloadValue(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime encode_u8_slice_as_bin: bool,
) (errors.EncodeError || std.mem.Allocator.Error)!msgpack.Payload {
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
        .int => msgpack.Payload.intToPayload(std.math.cast(i64, value) orelse return errors.EncodeError.EncodeFailure),
        .float => msgpack.Payload.floatToPayload(@floatCast(value)),
        .bool => msgpack.Payload.boolToPayload(value),
        .pointer => |ptr_info| encodePointer(allocator, value, ptr_info, encode_u8_slice_as_bin),
        .array => toPayloadValue(allocator, value[0..], encode_u8_slice_as_bin),
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
                        return errors.EncodeError.EncodeFailure;
                    };
                }
                return msgpack.Payload.strToPayload(value, allocator) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    return errors.EncodeError.EncodeFailure;
                };
            }

            var arr = msgpack.Payload.arrPayload(value.len, allocator) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return errors.EncodeError.EncodeFailure;
            };
            errdefer arr.free(allocator);

            for (value, 0..) |item, i| {
                const item_payload = try toPayloadValue(allocator, item, false);
                arr.setArrElement(i, item_payload) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    return errors.EncodeError.ArrayElementSetFailed;
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
        return errors.EncodeError.MapPutFailed;
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
    const KV = @field(T, "KV");
    const info = @typeInfo(KV).@"struct";
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, "value")) {
            return field.type;
        }
    }
    @compileError("Unable to determine StringHashMap value type: " ++ @typeName(T));
}
