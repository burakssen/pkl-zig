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
        allocator.free(self.module_uri);
        allocator.free(self.name);
        var props = self.properties.iterator();
        while (props.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.properties.deinit();
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        for (self.elements) |*elem| elem.deinit(allocator);
        allocator.free(self.elements);
    }
};

pub const Entry = struct {
    key: Value,
    value: Value,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        self.value.deinit(allocator);
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

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list => |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            .map => |entries| {
                for (entries) |*entry| entry.deinit(allocator);
                allocator.free(entries);
            },
            .object => |*object| object.deinit(allocator),
            .pair => |*pair| {
                pair.first.deinit(allocator);
                allocator.destroy(pair.first);
                pair.second.deinit(allocator);
                allocator.destroy(pair.second);
            },
            .string => |str| allocator.free(str),
            .bytes => |bytes| allocator.free(bytes),
            .regex => |regex| allocator.free(regex.pattern),
            .class => |class| {
                if (class.module_uri.len != 0) allocator.free(class.module_uri);
                if (class.name.len != 0) allocator.free(class.name);
            },
            .type_alias => |alias| {
                if (alias.module_uri.len != 0) allocator.free(alias.module_uri);
                if (alias.name.len != 0) allocator.free(alias.name);
            },
            else => {},
        }
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

/// Ownership invariant: decoded Value owns all string/bytes slices via allocator
/// duplicates, so callers can safely deinit the source msgpack payload first.
pub fn fromPayload(allocator: std.mem.Allocator, payload: msgpack.Payload) DecodeError!Value {
    return switch (payload) {
        .nil => .null,
        .bool => |value| .{ .bool = value },
        .int => |value| .{ .int = value },
        .uint => |value| .{ .uint = value },
        .float => |value| .{ .float = value },
        .str => .{ .string = try allocator.dupe(u8, try payload.asStr()) },
        .bin => .{ .bytes = try allocator.dupe(u8, try payload.asBin()) },
        .arr => try fromArrayPayload(allocator, payload),
        .map => try fromMapPayload(allocator, payload),
        else => DecodeError.UnsupportedType,
    };
}

pub fn decodeInto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var value = try decode(allocator, bytes);
    defer value.deinit(allocator);
    return fromValue(T, allocator, value);
}

pub fn fromValue(comptime T: type, allocator: std.mem.Allocator, value: Value) DecodeError!T {
    if (T == Value) return value;
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
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8)
                switch (value) {
                    .string => |str| if (ptr.is_const) try allocator.dupe(u8, str) else DecodeError.UnsupportedType,
                    .bytes => |bytes| if (ptr.is_const) try allocator.dupe(u8, bytes) else try allocator.dupe(u8, bytes),
                    else => DecodeError.UnsupportedType,
                }
            else
                try decodeSlice(T, ptr.child, allocator, value),
            .one => blk: {
                const out = try allocator.create(ptr.child);
                errdefer allocator.destroy(out);
                out.* = try fromValue(ptr.child, allocator, value);
                break :blk out;
            },
            else => DecodeError.UnsupportedType,
        },
        .optional => |opt| if (value == .null) null else try fromValue(opt.child, allocator, value),
        .@"struct" => if (comptime isHashMap(T))
            decodeHashMap(T, allocator, value)
        else if (comptime isPair(T))
            decodePairStruct(T, allocator, value)
        else
            decodeStruct(T, allocator, value),
        .@"enum" => switch (value) {
            .string => |str| if (@hasDecl(T, "parse"))
                try T.parse(str)
            else
                std.meta.stringToEnum(T, str) orelse DecodeError.UnsupportedType,
            else => DecodeError.UnsupportedType,
        },
        else => DecodeError.UnsupportedType,
    };
}

fn decodeSlice(comptime T: type, comptime Elem: type, allocator: std.mem.Allocator, value: Value) DecodeError!T {
    const values = switch (value) {
        .list => |items| items,
        else => return DecodeError.UnsupportedType,
    };
    const out = try allocator.alloc(Elem, values.len);
    errdefer allocator.free(out);
    for (values, 0..) |item, i| {
        out[i] = try fromValue(Elem, allocator, item);
    }
    return out;
}

fn decodeStruct(comptime T: type, allocator: std.mem.Allocator, value: Value) DecodeError!T {
    const object = switch (value) {
        .object => |object| object,
        else => return DecodeError.UnsupportedType,
    };

    var result: T = undefined;
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
    errdefer result.deinit();

    for (entries) |entry| {
        const key = try fromValue(Key, allocator, entry.key);
        errdefer if (Key == []const u8) allocator.free(key);
        const elem = try fromValue(Elem, allocator, entry.value);
        try result.put(key, elem);
    }

    return result;
}

fn decodePairStruct(comptime T: type, allocator: std.mem.Allocator, value: Value) DecodeError!T {
    const pair = switch (value) {
        .pair => |pair| pair,
        else => return DecodeError.UnsupportedType,
    };
    return .{
        .first = try fromValue(pairFirstType(T), allocator, pair.first.*),
        .second = try fromValue(pairSecondType(T), allocator, pair.second.*),
    };
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
    if (len == 0) return .{ .list = &.{} };

    const code_payload = try payload.getArrElement(0);
    const code = code_payload.getInt() catch return decodePlainArray(allocator, payload, len);

    return switch (code) {
        code_object => decodeObject(allocator, payload, len),
        code_map, code_mapping => decodeEntries(allocator, payload, len, 1),
        code_list, code_listing, code_set => decodeList(allocator, payload, len, 1),
        code_duration => .{ .duration = .{
            .value = try (try payload.getArrElement(1)).asFloat(),
            .unit = try DurationUnit.parse(try (try payload.getArrElement(2)).asStr()),
        } },
        code_data_size => .{ .data_size = .{
            .value = try (try payload.getArrElement(1)).asFloat(),
            .unit = try DataSizeUnit.parse(try (try payload.getArrElement(2)).asStr()),
        } },
        code_pair => try decodePair(allocator, payload),
        code_int_seq => .{ .int_seq = .{
            .start = try (try payload.getArrElement(1)).getInt(),
            .end = try (try payload.getArrElement(2)).getInt(),
            .step = try (try payload.getArrElement(3)).getInt(),
        } },
        code_regex => .{ .regex = .{ .pattern = try allocator.dupe(u8, try (try payload.getArrElement(1)).asStr()) } },
        code_class => decodeClass(allocator, payload, len),
        code_type_alias => decodeTypeAlias(allocator, payload, len),
        code_bytes => .{ .bytes = try allocator.dupe(u8, try (try payload.getArrElement(1)).asBin()) },
        else => decodePlainArray(allocator, payload, len),
    };
}

fn decodePlainArray(allocator: std.mem.Allocator, payload: msgpack.Payload, len: usize) DecodeError!Value {
    return decodeList(allocator, payload, len, 0);
}

fn decodeList(allocator: std.mem.Allocator, payload: msgpack.Payload, len: usize, start: usize) DecodeError!Value {
    const items = try allocator.alloc(Value, len - start);
    errdefer allocator.free(items);
    for (items, start..) |*item, i| {
        item.* = try fromPayload(allocator, try payload.getArrElement(i));
    }
    return .{ .list = items };
}

fn decodeEntries(allocator: std.mem.Allocator, payload: msgpack.Payload, len: usize, start: usize) DecodeError!Value {
    const entries = try allocator.alloc(Entry, len - start);
    errdefer allocator.free(entries);
    for (entries, start..) |*entry, i| {
        const pair = try payload.getArrElement(i);
        if ((try pair.getArrLen()) < 2) return DecodeError.InvalidPklValue;
        entry.* = .{
            .key = try fromPayload(allocator, try pair.getArrElement(0)),
            .value = try fromPayload(allocator, try pair.getArrElement(1)),
        };
    }
    return .{ .map = entries };
}

fn decodePair(allocator: std.mem.Allocator, payload: msgpack.Payload) DecodeError!Value {
    const first = try allocator.create(Value);
    errdefer allocator.destroy(first);
    const second = try allocator.create(Value);
    errdefer allocator.destroy(second);

    first.* = try fromPayload(allocator, try payload.getArrElement(1));
    errdefer first.deinit(allocator);
    second.* = try fromPayload(allocator, try payload.getArrElement(2));

    return .{ .pair = .{
        .first = first,
        .second = second,
    } };
}

fn fromMapPayload(allocator: std.mem.Allocator, payload: msgpack.Payload) DecodeError!Value {
    var entries = try allocator.alloc(Entry, payload.map.map.count());
    errdefer allocator.free(entries);
    var i: usize = 0;
    var it = payload.map.map.iterator();
    while (it.next()) |entry| : (i += 1) {
        entries[i] = .{
            .key = try fromPayload(allocator, entry.key_ptr.*),
            .value = try fromPayload(allocator, entry.value_ptr.*),
        };
    }
    return .{ .map = entries };
}

fn decodeObject(allocator: std.mem.Allocator, payload: msgpack.Payload, len: usize) DecodeError!Value {
    if (len < 4) return DecodeError.InvalidPklValue;
    const name = try allocator.dupe(u8, try (try payload.getArrElement(1)).asStr());
    errdefer allocator.free(name);
    const module_uri = try allocator.dupe(u8, try (try payload.getArrElement(2)).asStr());
    errdefer allocator.free(module_uri);
    const members = try payload.getArrElement(3);
    const member_len = try members.getArrLen();

    var object = Object{
        .module_uri = module_uri,
        .name = name,
        .properties = std.StringHashMap(Value).init(allocator),
        .entries = &.{},
        .elements = &.{},
    };
    errdefer object.deinit(allocator);

    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(allocator);
    var elements = std.ArrayList(Value).empty;
    defer elements.deinit(allocator);

    for (0..member_len) |i| {
        const member = try members.getArrElement(i);
        if ((try member.getArrLen()) < 2) return DecodeError.InvalidPklValue;
        const member_code = try (try member.getArrElement(0)).getInt();
        switch (member_code) {
            code_object_member_property => {
                const property_name = try allocator.dupe(u8, try (try member.getArrElement(1)).asStr());
                errdefer allocator.free(property_name);
                try object.properties.put(property_name, try fromPayload(allocator, try member.getArrElement(2)));
            },
            code_object_member_entry => try entries.append(allocator, .{
                .key = try fromPayload(allocator, try member.getArrElement(1)),
                .value = try fromPayload(allocator, try member.getArrElement(2)),
            }),
            code_object_member_element => try elements.append(allocator, try fromPayload(allocator, try member.getArrElement(2))),
            else => return DecodeError.InvalidPklObjectMemberCode,
        }
    }
    object.entries = try entries.toOwnedSlice(allocator);
    object.elements = try elements.toOwnedSlice(allocator);
    return .{ .object = object };
}

fn decodeClass(allocator: std.mem.Allocator, payload: msgpack.Payload, len: usize) DecodeError!Value {
    return .{ .class = if (len > 2) .{
        .name = try allocator.dupe(u8, try (try payload.getArrElement(1)).asStr()),
        .module_uri = try allocator.dupe(u8, try (try payload.getArrElement(2)).asStr()),
    } else .{} };
}

fn decodeTypeAlias(allocator: std.mem.Allocator, payload: msgpack.Payload, len: usize) DecodeError!Value {
    return .{ .type_alias = if (len > 2) .{
        .name = try allocator.dupe(u8, try (try payload.getArrElement(1)).asStr()),
        .module_uri = try allocator.dupe(u8, try (try payload.getArrElement(2)).asStr()),
    } else .{} };
}

test "decode generic object into struct" {
    const allocator = std.testing.allocator;

    var name = try msgpack.Payload.arrPayload(3, allocator);
    defer name.free(allocator);
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
    const bird = try fromValue(Bird, allocator, value);
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
    defer {
        var it = decoded.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        decoded.deinit();
    }

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

    const decoded = try fromValue(Pair([]const u8, i64), allocator, value);
    defer allocator.free(decoded.first);

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
