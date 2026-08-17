const std = @import("std");
const msgpack = @import("msgpack");

pub const DecodeError = anyerror;

const code_object = 0x01;
const code_map = 0x02;
const code_mapping = 0x03;
const code_list = 0x04;
const code_listing = 0x05;
const code_set = 0x06;
const code_duration = 0x07;
const code_data_size = 0x08;
const code_pair = 0x09;
const code_int_seq = 0x0a;
const code_regex = 0x0b;
const code_class = 0x0c;
const code_type_alias = 0x0d;
const code_function = 0x0e;
const code_bytes = 0x0f;

const code_object_member_property = 0x10;
const code_object_member_entry = 0x11;
const code_object_member_element = 0x12;

pub const Object = struct {
    module_uri: []const u8,
    name: []const u8,
    properties: std.StringHashMap(Value),
    entries: []Entry,
    elements: []Value,

    pub fn deinit(self: *Object, allocator: std.mem.Allocator) void {
        if (self.module_uri.len != 0) allocator.free(self.module_uri);
        if (self.name.len != 0) allocator.free(self.name);

        var props = self.properties.iterator();
        while (props.next()) |entry| {
            if (entry.key_ptr.*.len != 0) allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.properties.deinit();

        for (self.entries) |*entry| entry.deinit(allocator);
        if (self.entries.len != 0) allocator.free(self.entries);

        for (self.elements) |*element| element.deinit(allocator);
        if (self.elements.len != 0) allocator.free(self.elements);

        self.* = undefined;
    }

    pub fn clone(self: Object, allocator: std.mem.Allocator) !Object {
        var result = blk: {
            const module_uri = if (self.module_uri.len == 0)
                ""
            else
                try allocator.dupe(u8, self.module_uri);
            errdefer if (module_uri.len != 0) allocator.free(module_uri);

            const name = if (self.name.len == 0)
                ""
            else
                try allocator.dupe(u8, self.name);
            errdefer if (name.len != 0) allocator.free(name);

            break :blk Object{
                .module_uri = module_uri,
                .name = name,
                .properties = std.StringHashMap(Value).init(allocator),
                .entries = &.{},
                .elements = &.{},
            };
        };
        errdefer result.deinit(allocator);

        var props = self.properties.iterator();
        while (props.next()) |entry| {
            const key = if (entry.key_ptr.*.len == 0)
                ""
            else
                try allocator.dupe(u8, entry.key_ptr.*);
            errdefer if (key.len != 0) allocator.free(key);

            var cloned_value = try entry.value_ptr.clone(allocator);
            errdefer cloned_value.deinit(allocator);

            try result.properties.put(key, cloned_value);
        }

        result.entries = try cloneEntries(allocator, self.entries);
        result.elements = try cloneValues(allocator, self.elements);
        return result;
    }
};

pub const Entry = struct {
    key: Value,
    value: Value,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        self.value.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: Entry, allocator: std.mem.Allocator) !Entry {
        var key = try self.key.clone(allocator);
        errdefer key.deinit(allocator);

        var value = try self.value.clone(allocator);
        errdefer value.deinit(allocator);

        return .{ .key = key, .value = value };
    }
};

pub fn Pair(comptime A: type, comptime B: type) type {
    return struct {
        first: A,
        second: B,
    };
}

pub const Regex = struct {
    pattern: []const u8,
};

pub const Class = struct {
    module_uri: []const u8 = "",
    name: []const u8 = "",
};

pub const TypeAlias = struct {
    module_uri: []const u8 = "",
    name: []const u8 = "",
};

/// Pkl functions are opaque in pkl-binary. The encoding carries only the
/// function marker and intentionally exposes no callable representation.
pub const Function = struct {};

pub const IntSeq = struct {
    start: i64,
    end: i64,
    step: i64,
};

pub const Duration = struct {
    value: f64,
    unit: DurationUnit,
};

pub const DurationUnit = enum(i64) {
    ns = 1,
    us = 1000,
    ms = 1000 * 1000,
    s = 1000 * 1000 * 1000,
    min = 60 * 1000 * 1000 * 1000,
    h = 60 * 60 * 1000 * 1000 * 1000,
    d = 24 * 60 * 60 * 1000 * 1000 * 1000,

    pub fn parse(value: []const u8) DecodeError!DurationUnit {
        if (std.mem.eql(u8, value, "ns")) return .ns;
        if (std.mem.eql(u8, value, "us")) return .us;
        if (std.mem.eql(u8, value, "ms")) return .ms;
        if (std.mem.eql(u8, value, "s")) return .s;
        if (std.mem.eql(u8, value, "min")) return .min;
        if (std.mem.eql(u8, value, "h")) return .h;
        if (std.mem.eql(u8, value, "d")) return .d;
        return DecodeError.UnknownDurationUnit;
    }
};

pub const DataSize = struct {
    value: f64,
    unit: DataSizeUnit,
};

pub const DataSizeUnit = enum(i64) {
    b = 1,
    kb = 1000,
    kib = 1024,
    mb = 1000 * 1000,
    mib = 1024 * 1024,
    gb = 1000 * 1000 * 1000,
    gib = 1024 * 1024 * 1024,
    tb = 1000 * 1000 * 1000 * 1000,
    tib = 1024 * 1024 * 1024 * 1024,
    pb = 1000 * 1000 * 1000 * 1000 * 1000,
    pib = 1024 * 1024 * 1024 * 1024 * 1024,

    pub fn parse(value: []const u8) DecodeError!DataSizeUnit {
        if (std.mem.eql(u8, value, "b")) return .b;
        if (std.mem.eql(u8, value, "kb")) return .kb;
        if (std.mem.eql(u8, value, "kib")) return .kib;
        if (std.mem.eql(u8, value, "mb")) return .mb;
        if (std.mem.eql(u8, value, "mib")) return .mib;
        if (std.mem.eql(u8, value, "gb")) return .gb;
        if (std.mem.eql(u8, value, "gib")) return .gib;
        if (std.mem.eql(u8, value, "tb")) return .tb;
        if (std.mem.eql(u8, value, "tib")) return .tib;
        if (std.mem.eql(u8, value, "pb")) return .pb;
        if (std.mem.eql(u8, value, "pib")) return .pib;
        return DecodeError.UnknownDataSizeUnit;
    }
};

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    bytes: []const u8,
    list: []Value,
    map: []Entry,
    object: Object,
    pair: Pair(*Value, *Value),
    duration: Duration,
    data_size: DataSize,
    int_seq: IntSeq,
    regex: Regex,
    class: Class,
    type_alias: TypeAlias,
    function: Function,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list => |items| {
                for (items) |*item| item.deinit(allocator);
                if (items.len != 0) allocator.free(items);
            },
            .map => |entries| {
                for (entries) |*entry| entry.deinit(allocator);
                if (entries.len != 0) allocator.free(entries);
            },
            .object => |*object| object.deinit(allocator),
            .pair => |pair| {
                pair.first.deinit(allocator);
                allocator.destroy(pair.first);
                pair.second.deinit(allocator);
                allocator.destroy(pair.second);
            },
            .string => |string| if (string.len != 0) allocator.free(string),
            .bytes => |bytes| if (bytes.len != 0) allocator.free(bytes),
            .regex => |regex| if (regex.pattern.len != 0) allocator.free(regex.pattern),
            .class => |class| deinitClass(allocator, class),
            .type_alias => |alias| deinitTypeAlias(allocator, alias),
            else => {},
        }
        self.* = undefined;
    }

    /// Deep-copy an owning Value. The returned value can be deinitialized
    /// independently of the source with the same allocator.
    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .null => .null,
            .bool => |value| .{ .bool = value },
            .int => |value| .{ .int = value },
            .uint => |value| .{ .uint = value },
            .float => |value| .{ .float = value },
            .string => |value| .{ .string = try cloneBytes(allocator, value) },
            .bytes => |value| .{ .bytes = try cloneBytes(allocator, value) },
            .list => |items| .{ .list = try cloneValues(allocator, items) },
            .map => |entries| .{ .map = try cloneEntries(allocator, entries) },
            .object => |object| .{ .object = try object.clone(allocator) },
            .pair => |pair| .{ .pair = try clonePair(allocator, pair) },
            .duration => |value| .{ .duration = value },
            .data_size => |value| .{ .data_size = value },
            .int_seq => |value| .{ .int_seq = value },
            .regex => |regex| .{ .regex = .{ .pattern = try cloneBytes(allocator, regex.pattern) } },
            .class => |class| .{ .class = try cloneClass(allocator, class) },
            .type_alias => |alias| .{ .type_alias = try cloneTypeAlias(allocator, alias) },
            .function => .{ .function = .{} },
        };
    }
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Value {
    var writer_buffer: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buffer);
    var reader = std.Io.Reader.fixed(bytes);
    var packer = msgpack.PackerIO.init(&reader, &writer);
    var payload = try packer.read(allocator);
    defer payload.free(allocator);
    return fromPayload(allocator, payload);
}

/// Ownership invariant: every owning slice reachable from the returned Value
/// belongs to `allocator` (except canonical empty slices). It is independent of
/// the source MessagePack payload and must eventually be passed to Value.deinit.
pub fn fromPayload(allocator: std.mem.Allocator, payload: msgpack.Payload) DecodeError!Value {
    return switch (payload) {
        .nil => .null,
        .bool => |value| .{ .bool = value },
        .int => |value| .{ .int = value },
        .uint => |value| .{ .uint = value },
        .float => |value| .{ .float = value },
        .str => .{ .string = try cloneBytes(allocator, try payload.asStr()) },
        .bin => .{ .bytes = try cloneBytes(allocator, try payload.asBin()) },
        .arr => try fromArrayPayload(allocator, payload),
        .map => try fromMapPayload(allocator, payload),
        else => DecodeError.UnsupportedType,
    };
}

/// Decode pkl-binary directly into T. If T is Value, ownership of the decoded
/// Value is transferred directly to the caller. Otherwise the temporary Value
/// is destroyed after `fromValue` has built an independent typed result.
pub fn decodeInto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    if (T == Value) return decode(allocator, bytes);

    var value = try decode(allocator, bytes);
    defer value.deinit(allocator);
    return fromValue(T, allocator, value);
}

/// Convert a decoded Value to a typed Zig value. Any allocation reachable from
/// the returned value is independent of `value` and belongs to `allocator`.
pub fn fromValue(comptime T: type, allocator: std.mem.Allocator, value: Value) DecodeError!T {
    if (T == Value) return value.clone(allocator);
    if (T == Object) return switch (value) {
        .object => |object| object.clone(allocator),
        else => DecodeError.UnsupportedType,
    };
    if (T == Regex) return switch (value) {
        .regex => |regex| .{ .pattern = try cloneBytes(allocator, regex.pattern) },
        else => DecodeError.UnsupportedType,
    };
    if (T == Class) return switch (value) {
        .class => |class| cloneClass(allocator, class),
        else => DecodeError.UnsupportedType,
    };
    if (T == TypeAlias) return switch (value) {
        .type_alias => |alias| cloneTypeAlias(allocator, alias),
        else => DecodeError.UnsupportedType,
    };
    if (T == Function) return if (value == .function) .{} else DecodeError.UnsupportedType;
    if (T == IntSeq) return if (value == .int_seq) value.int_seq else DecodeError.UnsupportedType;
    if (T == Duration) return if (value == .duration) value.duration else DecodeError.UnsupportedType;
    if (T == DataSize) return if (value == .data_size) value.data_size else DecodeError.UnsupportedType;
    if (T == DurationUnit) return switch (value) {
        .string => |unit| try DurationUnit.parse(unit),
        else => DecodeError.UnsupportedType,
    };
    if (T == DataSizeUnit) return switch (value) {
        .string => |unit| try DataSizeUnit.parse(unit),
        else => DecodeError.UnsupportedType,
    };

    return switch (@typeInfo(T)) {
        .bool => if (value == .bool) value.bool else DecodeError.UnsupportedType,
        .int => switch (value) {
            .int => |int| std.math.cast(T, int) orelse DecodeError.UnsupportedType,
            .uint => |uint| std.math.cast(T, uint) orelse DecodeError.UnsupportedType,
            else => DecodeError.UnsupportedType,
        },
        .float => switch (value) {
            .float => |float| @as(T, @floatCast(float)),
            .int => |int| @as(T, @floatFromInt(int)),
            .uint => |uint| @as(T, @floatFromInt(uint)),
            else => DecodeError.UnsupportedType,
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (pointer.child == u8)
                switch (value) {
                    .string => |string| if (pointer.is_const)
                        try allocator.dupe(u8, string)
                    else
                        DecodeError.UnsupportedType,
                    .bytes => |bytes| try allocator.dupe(u8, bytes),
                    else => DecodeError.UnsupportedType,
                }
            else
                try decodeSlice(T, pointer.child, allocator, value),
            .one => blk: {
                const out = try allocator.create(pointer.child);
                errdefer allocator.destroy(out);
                out.* = try fromValue(pointer.child, allocator, value);
                break :blk out;
            },
            else => DecodeError.UnsupportedType,
        },
        .optional => |optional| if (value == .null)
            null
        else
            try fromValue(optional.child, allocator, value),
        .@"struct" => if (comptime isHashMap(T))
            decodeHashMap(T, allocator, value)
        else if (comptime isPair(T))
            decodePairStruct(T, allocator, value)
        else
            decodeStruct(T, allocator, value),
        .@"enum" => switch (value) {
            .string => |string| if (@hasDecl(T, "parse"))
                try T.parse(string)
            else
                std.meta.stringToEnum(T, string) orelse DecodeError.UnsupportedType,
            else => DecodeError.UnsupportedType,
        },
        else => DecodeError.UnsupportedType,
    };
}

/// Recursively destroy a typed result produced by decodeInto/fromValue.
/// This deliberately does not call user-defined `deinit` methods, so generated
/// structs can implement `deinit` by delegating here without recursion.
pub fn deinitDecoded(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    if (T == Value) {
        value.deinit(allocator);
        return;
    }
    if (T == Object) {
        value.deinit(allocator);
        return;
    }
    if (T == Regex) {
        if (value.pattern.len != 0) allocator.free(value.pattern);
        value.* = undefined;
        return;
    }
    if (T == Class) {
        deinitClass(allocator, value.*);
        value.* = undefined;
        return;
    }
    if (T == TypeAlias) {
        deinitTypeAlias(allocator, value.*);
        value.* = undefined;
        return;
    }
    if (T == Function or T == IntSeq or T == Duration or T == DataSize or T == DurationUnit or T == DataSizeUnit) {
        return;
    }

    switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                const slice = value.*;
                for (0..slice.len) |index| {
                    const item: *pointer.child = @constCast(&slice[index]);
                    deinitDecoded(pointer.child, allocator, item);
                }
                if (slice.len != 0) allocator.free(slice);
                value.* = undefined;
            },
            .one => {
                const child: *pointer.child = @constCast(value.*);
                deinitDecoded(pointer.child, allocator, child);
                allocator.destroy(child);
                value.* = undefined;
            },
            else => {},
        },
        .optional => |optional| {
            if (value.*) |*child| deinitDecoded(optional.child, allocator, child);
            value.* = null;
        },
        .array => |array| {
            for (&value.*) |*item| deinitDecoded(array.child, allocator, item);
        },
        .@"struct" => {
            if (comptime isHashMap(T)) {
                const Key = hashMapKeyType(T);
                const Elem = hashMapValueType(T);
                var iterator = value.iterator();
                while (iterator.next()) |entry| {
                    deinitDecoded(Key, allocator, @constCast(entry.key_ptr));
                    deinitDecoded(Elem, allocator, entry.value_ptr);
                }
                value.deinit();
                value.* = undefined;
                return;
            }

            inline for (std.meta.fields(T)) |field| {
                deinitDecoded(field.type, allocator, &@field(value.*, field.name));
            }
            value.* = undefined;
        },
        else => {},
    }
}

fn decodeSlice(
    comptime T: type,
    comptime Elem: type,
    allocator: std.mem.Allocator,
    value: Value,
) DecodeError!T {
    const values = switch (value) {
        .list => |items| items,
        else => return DecodeError.UnsupportedType,
    };

    const out = try allocator.alloc(Elem, values.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |*item| deinitDecoded(Elem, allocator, item);
        if (out.len != 0) allocator.free(out);
    }

    for (values, 0..) |item, index| {
        out[index] = try fromValue(Elem, allocator, item);
        initialized += 1;
    }
    return out;
}

fn decodeStruct(comptime T: type, allocator: std.mem.Allocator, value: Value) DecodeError!T {
    const object = switch (value) {
        .object => |object| object,
        else => return DecodeError.UnsupportedType,
    };

    var result: T = undefined;
    var initialized: usize = 0;
    errdefer {
        inline for (std.meta.fields(T), 0..) |field, index| {
            if (index < initialized) {
                deinitDecoded(field.type, allocator, &@field(result, field.name));
            }
        }
    }

    inline for (std.meta.fields(T)) |field| {
        const pkl_name = comptime if (@hasDecl(T, "pklFieldName"))
            T.pklFieldName(field.name)
        else
            field.name;

        if (object.properties.get(pkl_name)) |property| {
            @field(result, field.name) = try fromValue(field.type, allocator, property);
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            return DecodeError.MissingField;
        }
        initialized += 1;
    }

    return result;
}

fn decodeHashMap(comptime T: type, allocator: std.mem.Allocator, value: Value) DecodeError!T {
    const entries = switch (value) {
        .map => |entries| entries,
        else => return DecodeError.UnsupportedType,
    };

    const Key = hashMapKeyType(T);
    const Elem = hashMapValueType(T);

    var result = T.init(allocator);
    errdefer deinitDecoded(T, allocator, &result);

    for (entries) |entry| {
        var key = try fromValue(Key, allocator, entry.key);
        errdefer deinitDecoded(Key, allocator, &key);

        var element = try fromValue(Elem, allocator, entry.value);
        errdefer deinitDecoded(Elem, allocator, &element);

        try result.put(key, element);
    }

    return result;
}

fn decodePairStruct(comptime T: type, allocator: std.mem.Allocator, value: Value) DecodeError!T {
    const pair = switch (value) {
        .pair => |pair| pair,
        else => return DecodeError.UnsupportedType,
    };

    const First = pairFirstType(T);
    const Second = pairSecondType(T);

    var first = try fromValue(First, allocator, pair.first.*);
    errdefer deinitDecoded(First, allocator, &first);

    const second = try fromValue(Second, allocator, pair.second.*);
    return .{ .first = first, .second = second };
}

fn isHashMap(comptime T: type) bool {
    return std.mem.startsWith(u8, @typeName(T), "hash_map.HashMap(");
}

fn hashMapKeyType(comptime T: type) type {
    const KV = @field(T, "KV");
    const info = @typeInfo(KV).@"struct";
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, "key")) return field.type;
    }
    @compileError("Unable to determine HashMap key type: " ++ @typeName(T));
}

fn hashMapValueType(comptime T: type) type {
    const KV = @field(T, "KV");
    const info = @typeInfo(KV).@"struct";
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, "value")) return field.type;
    }
    @compileError("Unable to determine HashMap value type: " ++ @typeName(T));
}

fn isPair(comptime T: type) bool {
    const info = @typeInfo(T).@"struct";
    return info.fields.len == 2 and
        std.mem.eql(u8, info.fields[0].name, "first") and
        std.mem.eql(u8, info.fields[1].name, "second");
}

fn pairFirstType(comptime T: type) type {
    return @typeInfo(T).@"struct".fields[0].type;
}

fn pairSecondType(comptime T: type) type {
    return @typeInfo(T).@"struct".fields[1].type;
}

fn fromArrayPayload(allocator: std.mem.Allocator, payload: msgpack.Payload) DecodeError!Value {
    const len = try payload.getArrLen();
    if (len == 0) return DecodeError.InvalidPklValue;

    const code_payload = try payload.getArrElement(0);
    const code = code_payload.getInt() catch return decodePlainArray(allocator, payload, len);

    return switch (code) {
        code_object => decodeObject(allocator, payload, len),
        code_map, code_mapping => decodeMapWrapper(allocator, payload, len),
        code_list, code_listing, code_set => decodeListWrapper(allocator, payload, len),
        code_duration => decodeDuration(payload, len),
        code_data_size => decodeDataSize(payload, len),
        code_pair => decodePair(allocator, payload, len),
        code_int_seq => decodeIntSeq(payload, len),
        code_regex => decodeRegex(allocator, payload, len),
        code_class => decodeClass(allocator, payload, len),
        code_type_alias => decodeTypeAlias(allocator, payload, len),
        code_function => .{ .function = .{} },
        code_bytes => decodeBytes(allocator, payload, len),
        else => DecodeError.UnknownPklType,
    };
}

/// This compatibility path is intentionally used only when the first element
/// is not an integer type marker. An unknown integer marker is never silently
/// reinterpreted as a list.
fn decodePlainArray(
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
    len: usize,
) DecodeError!Value {
    return decodeListPayload(allocator, payload, len);
}

fn decodeListWrapper(
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
    len: usize,
) DecodeError!Value {
    if (len < 2) return DecodeError.InvalidPklValue;
    const items_payload = try payload.getArrElement(1);
    const item_count = try items_payload.getArrLen();
    return decodeListPayload(allocator, items_payload, item_count);
}

fn decodeListPayload(
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
    len: usize,
) DecodeError!Value {
    if (len == 0) return .{ .list = &.{} };

    const items = try allocator.alloc(Value, len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(items);
    }

    for (items, 0..) |*item, index| {
        item.* = try fromPayload(allocator, try payload.getArrElement(index));
        initialized += 1;
    }
    return .{ .list = items };
}

fn decodeMapWrapper(
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
    len: usize,
) DecodeError!Value {
    if (len < 2) return DecodeError.InvalidPklValue;
    return fromMapPayload(allocator, try payload.getArrElement(1));
}

fn decodeDuration(payload: msgpack.Payload, len: usize) DecodeError!Value {
    if (len < 3) return DecodeError.InvalidPklValue;
    return .{ .duration = .{
        .value = try (try payload.getArrElement(1)).asFloat(),
        .unit = try DurationUnit.parse(try (try payload.getArrElement(2)).asStr()),
    } };
}

fn decodeDataSize(payload: msgpack.Payload, len: usize) DecodeError!Value {
    if (len < 3) return DecodeError.InvalidPklValue;
    return .{ .data_size = .{
        .value = try (try payload.getArrElement(1)).asFloat(),
        .unit = try DataSizeUnit.parse(try (try payload.getArrElement(2)).asStr()),
    } };
}

fn decodeIntSeq(payload: msgpack.Payload, len: usize) DecodeError!Value {
    if (len < 4) return DecodeError.InvalidPklValue;
    return .{ .int_seq = .{
        .start = try (try payload.getArrElement(1)).getInt(),
        .end = try (try payload.getArrElement(2)).getInt(),
        .step = try (try payload.getArrElement(3)).getInt(),
    } };
}

fn decodeRegex(
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
    len: usize,
) DecodeError!Value {
    if (len < 2) return DecodeError.InvalidPklValue;
    return .{ .regex = .{
        .pattern = try cloneBytes(allocator, try (try payload.getArrElement(1)).asStr()),
    } };
}

fn decodeBytes(
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
    len: usize,
) DecodeError!Value {
    if (len < 2) return DecodeError.InvalidPklValue;
    return .{ .bytes = try cloneBytes(allocator, try (try payload.getArrElement(1)).asBin()) };
}

fn decodePair(
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
    len: usize,
) DecodeError!Value {
    if (len < 3) return DecodeError.InvalidPklValue;

    const first = try allocator.create(Value);
    errdefer allocator.destroy(first);
    first.* = try fromPayload(allocator, try payload.getArrElement(1));
    errdefer first.deinit(allocator);

    const second = try allocator.create(Value);
    errdefer allocator.destroy(second);
    second.* = try fromPayload(allocator, try payload.getArrElement(2));

    return .{ .pair = .{ .first = first, .second = second } };
}

fn fromMapPayload(allocator: std.mem.Allocator, payload: msgpack.Payload) DecodeError!Value {
    if (payload != .map) return DecodeError.UnsupportedType;

    const count = payload.map.map.count();
    if (count == 0) return .{ .map = &.{} };

    const entries = try allocator.alloc(Entry, count);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    var iterator = payload.map.map.iterator();
    while (iterator.next()) |entry| {
        var key = try fromPayload(allocator, entry.key_ptr.*);
        errdefer key.deinit(allocator);

        var value = try fromPayload(allocator, entry.value_ptr.*);
        errdefer value.deinit(allocator);

        entries[initialized] = .{ .key = key, .value = value };
        initialized += 1;
    }

    return .{ .map = entries };
}

fn decodeObject(
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
    len: usize,
) DecodeError!Value {
    if (len < 4) return DecodeError.InvalidPklValue;

    const members = try payload.getArrElement(3);
    const member_len = try members.getArrLen();

    var object = blk: {
        const name_source = try (try payload.getArrElement(1)).asStr();
        const name = if (name_source.len == 0) "" else try allocator.dupe(u8, name_source);
        errdefer if (name.len != 0) allocator.free(name);

        const module_uri_source = try (try payload.getArrElement(2)).asStr();
        const module_uri = if (module_uri_source.len == 0) "" else try allocator.dupe(u8, module_uri_source);
        errdefer if (module_uri.len != 0) allocator.free(module_uri);

        break :blk Object{
            .module_uri = module_uri,
            .name = name,
            .properties = std.StringHashMap(Value).init(allocator),
            .entries = &.{},
            .elements = &.{},
        };
    };
    errdefer object.deinit(allocator);

    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
    }

    var elements = std.ArrayList(Value).empty;
    defer elements.deinit(allocator);
    errdefer {
        for (elements.items) |*element| element.deinit(allocator);
    }

    for (0..member_len) |index| {
        const member = try members.getArrElement(index);
        if ((try member.getArrLen()) < 3) return DecodeError.InvalidPklValue;

        const member_code = try (try member.getArrElement(0)).getInt();
        switch (member_code) {
            code_object_member_property => {
                const property_source = try (try member.getArrElement(1)).asStr();
                const property_name = if (property_source.len == 0)
                    ""
                else
                    try allocator.dupe(u8, property_source);
                errdefer if (property_name.len != 0) allocator.free(property_name);

                var property_value = try fromPayload(allocator, try member.getArrElement(2));
                errdefer property_value.deinit(allocator);

                if (object.properties.getPtr(property_name)) |old_value| {
                    old_value.deinit(allocator);
                    old_value.* = property_value;
                    if (property_name.len != 0) allocator.free(property_name);
                } else {
                    try object.properties.put(property_name, property_value);
                }
            },
            code_object_member_entry => {
                var key = try fromPayload(allocator, try member.getArrElement(1));
                errdefer key.deinit(allocator);

                var value = try fromPayload(allocator, try member.getArrElement(2));
                errdefer value.deinit(allocator);

                try entries.append(allocator, .{ .key = key, .value = value });
            },
            code_object_member_element => {
                var element = try fromPayload(allocator, try member.getArrElement(2));
                errdefer element.deinit(allocator);
                try elements.append(allocator, element);
            },
            else => return DecodeError.InvalidPklObjectMemberCode,
        }
    }

    object.entries = try entries.toOwnedSlice(allocator);
    object.elements = try elements.toOwnedSlice(allocator);
    return .{ .object = object };
}

fn decodeClass(
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
    len: usize,
) DecodeError!Value {
    if (len < 3) return DecodeError.InvalidPklValue;

    const name_source = try (try payload.getArrElement(1)).asStr();
    const name = if (name_source.len == 0) "" else try allocator.dupe(u8, name_source);
    errdefer if (name.len != 0) allocator.free(name);

    const module_uri_source = try (try payload.getArrElement(2)).asStr();
    const module_uri = if (module_uri_source.len == 0) "" else try allocator.dupe(u8, module_uri_source);

    return .{ .class = .{ .name = name, .module_uri = module_uri } };
}

fn decodeTypeAlias(
    allocator: std.mem.Allocator,
    payload: msgpack.Payload,
    len: usize,
) DecodeError!Value {
    if (len < 3) return DecodeError.InvalidPklValue;

    const name_source = try (try payload.getArrElement(1)).asStr();
    const name = if (name_source.len == 0) "" else try allocator.dupe(u8, name_source);
    errdefer if (name.len != 0) allocator.free(name);

    const module_uri_source = try (try payload.getArrElement(2)).asStr();
    const module_uri = if (module_uri_source.len == 0) "" else try allocator.dupe(u8, module_uri_source);

    return .{ .type_alias = .{ .name = name, .module_uri = module_uri } };
}

fn cloneBytes(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (source.len == 0) return "";
    return allocator.dupe(u8, source);
}

fn cloneClass(allocator: std.mem.Allocator, source: Class) !Class {
    const module_uri = try cloneBytes(allocator, source.module_uri);
    errdefer if (module_uri.len != 0) allocator.free(module_uri);

    const name = try cloneBytes(allocator, source.name);
    return .{ .module_uri = module_uri, .name = name };
}

fn cloneTypeAlias(allocator: std.mem.Allocator, source: TypeAlias) !TypeAlias {
    const module_uri = try cloneBytes(allocator, source.module_uri);
    errdefer if (module_uri.len != 0) allocator.free(module_uri);

    const name = try cloneBytes(allocator, source.name);
    return .{ .module_uri = module_uri, .name = name };
}

fn deinitClass(allocator: std.mem.Allocator, value: Class) void {
    if (value.module_uri.len != 0) allocator.free(value.module_uri);
    if (value.name.len != 0) allocator.free(value.name);
}

fn deinitTypeAlias(allocator: std.mem.Allocator, value: TypeAlias) void {
    if (value.module_uri.len != 0) allocator.free(value.module_uri);
    if (value.name.len != 0) allocator.free(value.name);
}

fn cloneValues(allocator: std.mem.Allocator, source: []const Value) ![]Value {
    if (source.len == 0) return &.{};

    const result = try allocator.alloc(Value, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(result);
    }

    for (source, 0..) |item, index| {
        result[index] = try item.clone(allocator);
        initialized += 1;
    }
    return result;
}

fn cloneEntries(allocator: std.mem.Allocator, source: []const Entry) ![]Entry {
    if (source.len == 0) return &.{};

    const result = try allocator.alloc(Entry, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*entry| entry.deinit(allocator);
        allocator.free(result);
    }

    for (source, 0..) |entry, index| {
        result[index] = try entry.clone(allocator);
        initialized += 1;
    }
    return result;
}

fn clonePair(
    allocator: std.mem.Allocator,
    source: Pair(*Value, *Value),
) !Pair(*Value, *Value) {
    const first = try allocator.create(Value);
    errdefer allocator.destroy(first);
    first.* = try source.first.clone(allocator);
    errdefer first.deinit(allocator);

    const second = try allocator.create(Value);
    errdefer allocator.destroy(second);
    second.* = try source.second.clone(allocator);

    return .{ .first = first, .second = second };
}

test "fromValue returns an independent Value clone" {
    const allocator = std.testing.allocator;

    var source: Value = .{ .string = try allocator.dupe(u8, "hello") };
    defer source.deinit(allocator);

    var cloned = try fromValue(Value, allocator, source);
    defer cloned.deinit(allocator);

    try std.testing.expect(cloned == .string);
    try std.testing.expectEqualStrings("hello", cloned.string);
    try std.testing.expect(@intFromPtr(source.string.ptr) != @intFromPtr(cloned.string.ptr));
}

test "decode typed runtime wrappers" {
    const allocator = std.testing.allocator;

    var class_value: Value = .{ .class = .{
        .module_uri = try allocator.dupe(u8, "file:///config.pkl"),
        .name = try allocator.dupe(u8, "Config#Thing"),
    } };
    defer class_value.deinit(allocator);

    var class = try fromValue(Class, allocator, class_value);
    defer deinitDecoded(Class, allocator, &class);

    try std.testing.expectEqualStrings("file:///config.pkl", class.module_uri);
    try std.testing.expectEqualStrings("Config#Thing", class.name);
}

test "typed slice cleanup is transactional" {
    const allocator = std.testing.allocator;

    var items = [_]Value{
        .{ .string = "owned-after-conversion" },
        .{ .int = 42 },
    };
    const value: Value = .{ .list = items[0..] };

    try std.testing.expectError(
        DecodeError.UnsupportedType,
        fromValue([]const []const u8, allocator, value),
    );
}

test "typed struct cleanup is transactional" {
    const allocator = std.testing.allocator;

    var properties = std.StringHashMap(Value).init(allocator);
    defer properties.deinit();
    try properties.put("name", .{ .string = "Bird" });

    const value: Value = .{ .object = .{
        .module_uri = "",
        .name = "",
        .properties = properties,
        .entries = &.{},
        .elements = &.{},
    } };

    const Bird = struct {
        name: []const u8,
        age: i64,
    };

    try std.testing.expectError(DecodeError.MissingField, fromValue(Bird, allocator, value));
}

test "typed HashMap cleanup is transactional" {
    const allocator = std.testing.allocator;

    var entries = [_]Entry{
        .{ .key = .{ .string = "ok" }, .value = .{ .string = "value" } },
        .{ .key = .{ .int = 1 }, .value = .{ .string = "bad" } },
    };
    const value: Value = .{ .map = entries[0..] };

    try std.testing.expectError(
        DecodeError.UnsupportedType,
        fromValue(std.StringHashMap([]const u8), allocator, value),
    );
}

test "typed Pair cleanup is transactional" {
    const allocator = std.testing.allocator;

    var first: Value = .{ .string = "name" };
    var second: Value = .{ .bool = true };
    const value: Value = .{ .pair = .{ .first = &first, .second = &second } };

    try std.testing.expectError(
        DecodeError.UnsupportedType,
        fromValue(Pair([]const u8, i64), allocator, value),
    );
}

test "decode pkl list wrapper payload" {
    const allocator = std.testing.allocator;

    var items = try msgpack.Payload.arrPayload(2, allocator);
    try items.setArrElement(0, msgpack.Payload.intToPayload(1));
    try items.setArrElement(1, msgpack.Payload.intToPayload(2));

    var payload = try msgpack.Payload.arrPayload(2, allocator);
    defer payload.free(allocator);
    try payload.setArrElement(0, msgpack.Payload.intToPayload(code_list));
    try payload.setArrElement(1, items);

    var value = try fromPayload(allocator, payload);
    defer value.deinit(allocator);

    try std.testing.expect(value == .list);
    try std.testing.expectEqual(@as(usize, 2), value.list.len);
    try std.testing.expectEqual(@as(i64, 1), value.list[0].int);
    try std.testing.expectEqual(@as(i64, 2), value.list[1].int);
}

test "decode pkl map wrapper payload" {
    const allocator = std.testing.allocator;

    var map_payload = msgpack.Payload.mapPayload(allocator);
    try map_payload.mapPut("city", try msgpack.Payload.strToPayload("London", allocator));

    var payload = try msgpack.Payload.arrPayload(2, allocator);
    defer payload.free(allocator);
    try payload.setArrElement(0, msgpack.Payload.intToPayload(code_map));
    try payload.setArrElement(1, map_payload);

    var value = try fromPayload(allocator, payload);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    try std.testing.expectEqual(@as(usize, 1), value.map.len);
    try std.testing.expectEqualStrings("city", value.map[0].key.string);
    try std.testing.expectEqualStrings("London", value.map[0].value.string);
}

test "decode function marker without silently treating it as a list" {
    const allocator = std.testing.allocator;

    var payload = try msgpack.Payload.arrPayload(1, allocator);
    defer payload.free(allocator);
    try payload.setArrElement(0, msgpack.Payload.intToPayload(code_function));

    const value = try fromPayload(allocator, payload);
    try std.testing.expect(value == .function);
}

test "unknown integer pkl marker is rejected" {
    const allocator = std.testing.allocator;

    var payload = try msgpack.Payload.arrPayload(1, allocator);
    defer payload.free(allocator);
    try payload.setArrElement(0, msgpack.Payload.intToPayload(0x7f));

    try std.testing.expectError(DecodeError.UnknownPklType, fromPayload(allocator, payload));
}

test "decode generic object into struct" {
    const allocator = std.testing.allocator;

    var name = try msgpack.Payload.arrPayload(3, allocator);
    try name.setArrElement(0, msgpack.Payload.intToPayload(code_object_member_property));
    try name.setArrElement(1, try msgpack.Payload.strToPayload("name", allocator));
    try name.setArrElement(2, try msgpack.Payload.strToPayload("Bird", allocator));

    var members = try msgpack.Payload.arrPayload(1, allocator);
    try members.setArrElement(0, name);

    var object = try msgpack.Payload.arrPayload(4, allocator);
    defer object.free(allocator);
    try object.setArrElement(0, msgpack.Payload.intToPayload(code_object));
    try object.setArrElement(1, try msgpack.Payload.strToPayload("Bird", allocator));
    try object.setArrElement(2, try msgpack.Payload.strToPayload("file:///bird.pkl", allocator));
    try object.setArrElement(3, members);

    var value = try fromPayload(allocator, object);
    defer value.deinit(allocator);

    const Bird = struct { name: []const u8 };
    var bird = try fromValue(Bird, allocator, value);
    defer deinitDecoded(Bird, allocator, &bird);

    try std.testing.expectEqualStrings("Bird", bird.name);
}

test "decode map into StringHashMap" {
    const allocator = std.testing.allocator;

    var entries = [_]Entry{
        .{
            .key = .{ .string = "city" },
            .value = .{ .string = "London" },
        },
    };
    const value: Value = .{ .map = entries[0..] };

    var decoded = try fromValue(std.StringHashMap([]const u8), allocator, value);
    defer deinitDecoded(@TypeOf(decoded), allocator, &decoded);

    try std.testing.expectEqualStrings("London", decoded.get("city").?);
}

test "decode typed pair" {
    const allocator = std.testing.allocator;

    var first: Value = .{ .string = "name" };
    var second: Value = .{ .int = 42 };
    const value: Value = .{ .pair = .{
        .first = &first,
        .second = &second,
    } };

    var decoded = try fromValue(Pair([]const u8, i64), allocator, value);
    defer deinitDecoded(@TypeOf(decoded), allocator, &decoded);

    try std.testing.expectEqualStrings("name", decoded.first);
    try std.testing.expectEqual(@as(i64, 42), decoded.second);
}

test "decode code_bytes duplicates payload-backed data" {
    const allocator = std.testing.allocator;

    var payload = try msgpack.Payload.arrPayload(2, allocator);
    defer payload.free(allocator);
    try payload.setArrElement(0, msgpack.Payload.intToPayload(code_bytes));
    try payload.setArrElement(1, try msgpack.Payload.binToPayload("abc", allocator));
    const source = try (try payload.getArrElement(1)).asBin();

    var decoded = try fromPayload(allocator, payload);
    defer decoded.deinit(allocator);

    try std.testing.expect(decoded == .bytes);
    try std.testing.expectEqualStrings("abc", decoded.bytes);
    try std.testing.expect(@intFromPtr(source.ptr) != @intFromPtr(decoded.bytes.ptr));
}
