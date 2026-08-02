const std = @import("std");
const error_set_conv = @import("error_set_conversion.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

pub fn marshal(writer: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .@"anyframe", .frame, .comptime_int, .comptime_float, .@"fn", .enum_literal, .noreturn, .null, .type, .undefined => @compileError("Marshaling unsupported type value"),
        .array => {
            for (value) |elem| try marshal(writer, elem);
        },
        .vector => {
            for (value) |elem| try marshal(writer, elem);
        },
        .@"opaque" => {
            if (@hasDecl(T, "marshal")) {
                try value.marshal(writer);
                return;
            }
            @compileError("Marshaling unsupported type value");
        },
        .@"struct" => |struct_info| {
            if (@hasDecl(T, "marshal")) {
                try value.marshal(writer);
                return;
            }
            inline for (struct_info.fields) |field| {
                if (!field.is_comptime) {
                    try marshal(writer, @field(value, field.name));
                }
            }
        },
        .@"enum" => {
            if (@hasDecl(T, "marshal")) {
                try value.marshal(writer);
                return;
            }
            try marshal(writer, @intFromEnum(value));
        },
        .@"union" => |union_info| {
            if (@hasDecl(T, "marshal")) {
                try value.marshal(writer);
                return;
            }
            if (union_info.tag_type == null) {
                @compileError("Untagged Union is not supported.");
            }
            const Tag = union_info.tag_type.?;
            const tag_info = @typeInfo(Tag).@"enum";
            const tag = @intFromEnum(value);
            inline for (tag_info.fields) |tag_field| {
                if (tag == tag_field.value) {
                    try marshal(writer, std.meta.activeTag(value));
                    try marshal(writer, @field(value, tag_field.name));
                }
            }
            return;
        },
        .int => |int| {
            if (int.bits == 0) return;
            var buf: [std.math.divCeil(usize, int.bits, 8) catch unreachable]u8 = undefined;
            std.mem.writePackedInt(T, &buf, 0, value, .little);
            try writer.writeAll(&buf);
        },
        .float => {
            const bytes = std.mem.asBytes(&value);
            try writer.writeAll(bytes);
        },
        .bool => {
            try writer.writeByte(@intFromBool(value));
        },
        .optional => {
            if (value) |v| {
                try writer.writeByte(1);
                try marshal(writer, v);
            } else {
                try writer.writeByte(0);
            }
        },
        .void => {},
        .pointer => |pointer| {
            if (pointer.size == .slice) {
                try writer.writeInt(usize, @intFromPtr(value.ptr), .little);
                try writer.writeInt(usize, value.len, .little);
            } else {
                try writer.writeInt(usize, @intFromPtr(value), .little);
            }
        },
        .error_union => {
            const v = value catch |err| {
                try writer.writeByte(1);
                try marshal(writer, err);
                return;
            };
            try writer.writeByte(0);
            try marshal(writer, v);
        },
        .error_set => |error_set| {
            if (error_set == null) {
                @compileError("Cannot marshal anyerror");
            }
            const set = error_set.?;
            if (set.len == 0) {
                unreachable;
            }
            const int = error_set_conv.intFromError(T, value);
            // std.debug.print("marshal error set: {d}\n", .{int});
            try marshal(writer, int);
        },
    }
}

pub fn marshaledLen(value: anytype) Writer.Error!usize {
    var discarding_writer = Writer.Discarding.init(&.{});
    try marshal(&discarding_writer.writer, value);
    const len = discarding_writer.fullCount();
    if (len > std.math.maxInt(usize)) return error.WriteFailed;
    return @intCast(len);
}

pub fn marshalAlloc(gpa: Allocator, value: anytype) Allocator.Error![]u8 {
    const len = marshaledLen(value) catch return Allocator.Error.OutOfMemory;
    const buf = try gpa.alloc(u8, len);
    var writer = Writer.fixed(buf);
    marshal(&writer, value) catch unreachable;
    std.debug.assert(writer.buffered().len == buf.len);
    return buf;
}

pub const UnmarshalError = Reader.Error || Allocator.Error || error {
    UnmarshalFailed,
};

pub fn unmarshal(comptime T: type, reader: *Reader, value: *T, gpa_opt: ?Allocator) UnmarshalError!void {
    const info = @typeInfo(T);
    switch (info) {
        .@"anyframe", .frame, .comptime_int, .comptime_float, .@"fn", .enum_literal, .noreturn, .null, .type, .undefined => @compileError("Marshaling unsupported type value"),
        .array => |array| {
            for (0..array.len) |idx| {
                try unmarshal(array.child, reader, &value[idx], gpa_opt);
            }
        },
        .vector => |vector| {
            for (0..vector.len) |idx| {
                try unmarshal(vector.child, reader, &value[idx], gpa_opt);
            }
            return value;
        },
        .@"opaque" => {
            if (@hasDecl(T, "unmarshal")) {
                value.* = try T.unmarshal(reader);
                return;
            }
            @compileError("Marshaling unsupported type value");
        },
        .@"struct" => |struct_info| {
            if (@hasDecl(T, "unmarshal")) {
                const MarshalFn = @TypeOf(T.unmarshal);
                const fn_info = @typeInfo(MarshalFn).@"fn";
                if (fn_info.params.len == 1) {
                    value.* = try T.unmarshal(reader);
                } else if (fn_info.params.len == 2) {
                    if (gpa_opt) |gpa| {
                        value.* = try T.unmarshal(reader, gpa);
                    } else {
                        return UnmarshalError.UnmarshalFailed;
                    }
                } else {
                    @compileError("Unmarshal function must have 1 or 2 args.");
                }
                return;
            }
            inline for (struct_info.fields) |field| {
                if (!field.is_comptime) {
                    try unmarshal(field.type, reader, &@field(value, field.name), gpa_opt);
                }
            }
        },
        .@"enum" => |enum_info| {
            if (@hasDecl(T, "unmarshal")) {
                const MarshalFn = @TypeOf(T.unmarshal);
                const fn_info = @typeInfo(MarshalFn).@"fn";
                if (fn_info.params.len == 1) {
                    value.* = try T.unmarshal(reader);
                } else if (fn_info.params.len == 2) {
                    if (gpa_opt) |gpa| {
                        value.* = try T.unmarshal(reader, gpa);
                    } else {
                        return UnmarshalError.UnmarshalFailed;
                    }
                } else {
                    @compileError("Unmarshal function must have 1 or 2 args.");
                }
                return;
            }
            var int: @TypeOf(@intFromEnum(@as(T, undefined))) = undefined;
            try unmarshal(@TypeOf(int), reader, &int, null);
            inline for (enum_info.fields) |field| {
                if (int == field.value) {
                    value.* = @as(T, @enumFromInt(field.value));
                    return;
                }
            }
            return error.UnmarshalFailed;
        },
        .@"union" => |union_info| {
            if (@hasDecl(T, "unmarshal")) {
                const MarshalFn = @TypeOf(T.unmarshal);
                const fn_info = @typeInfo(MarshalFn).@"fn";
                if (fn_info.params.len == 1) {
                    value.* = try T.unmarshal(reader);
                } else if (fn_info.params.len == 2) {
                    if (gpa_opt) |gpa| {
                        value.* = try T.unmarshal(reader, gpa);
                    } else {
                        return UnmarshalError.UnmarshalFailed;
                    }
                } else {
                    @compileError("Unmarshal function must have 1 or 2 args.");
                }
                return;
            }
            if (union_info.tag_type == null) {
                @compileError("Untagged Union is not supported.");
            }
            const Tag = union_info.tag_type.?;
            var tag: Tag = undefined;
            try unmarshal(Tag, reader, &tag, gpa_opt);
            const tag_info = @typeInfo(Tag).@"enum";
            inline for (tag_info.fields) |tag_field| {
                if (@intFromEnum(tag) == tag_field.value) {
                    var val: @TypeOf(@field(@as(T, undefined), tag_field.name)) = undefined;
                    try unmarshal(@TypeOf(val), reader, &val, gpa_opt);
                    value.* = @unionInit(T, tag_field.name, val);
                    return;
                }
            }
            unreachable;
        },
        .int => |int| {
            if (int.bits == 0) {
                value.* = 0;
                return;
            }
            var buf: [std.math.divCeil(usize, int.bits, 8) catch unreachable]u8 = undefined;
            try reader.readSliceAll(&buf);
            value.* = std.mem.readPackedInt(T, &buf, 0, .little);
        },
        .float => {
            const size = @sizeOf(T);
            var buf: [size]u8 = undefined;
            try reader.readSliceAll(&buf);
            value.* = std.mem.bytesAsValue(T, buf).*;
        },
        .bool => {
            var byte: [1]u8 = undefined;
            try reader.readSliceAll(&byte);
            value.* = (byte[0] & 1) != 0;
        },
        .optional => |optional| {
            var has_value: bool = undefined;
            try unmarshal(bool, reader, &has_value, null);
            if (has_value) {
                var v: optional.child = undefined;
                try unmarshal(optional.child, reader, &v, gpa_opt);
                value.* = v;
            } else {
                value.* = null;
            }
        },
        .void => {},
        .pointer => |pointer| {
            var buf: [@sizeOf(usize)]u8 = undefined;
            try reader.readSliceAll(&buf);
            const int = std.mem.readInt(usize, &buf, .little);
            if (!pointer.is_allowzero and int == 0) {
                return error.UnmarshalFailed;
            }
            if (pointer.size == .slice) {
                try reader.readSliceAll(&buf);
                const size = std.mem.readInt(usize, &buf, .little);
                const Many = @Pointer(.many, .{
                    .@"addrspace" = pointer.address_space,
                    .@"align" = pointer.alignment,
                    .@"allowzero" = pointer.is_allowzero,
                    .@"const" = pointer.is_const,
                    .@"volatile" = pointer.is_volatile,
                }, pointer.child, null);
                const many: Many = @ptrFromInt(int);
                value.* = if (pointer.sentinel()) |sentinel|
                    many[0..size : sentinel]
                else
                    many[0..size];
            } else {
                value.* = @ptrFromInt(int);
            }
        },
        .error_union => |error_union| {
            var is_err: bool = undefined;
            try unmarshal(bool, reader, &is_err, null);
            if (is_err) {
                var err: error_union.error_set = undefined;
                try unmarshal(error_union.error_set, reader, &err, null);
                value.* = err;
            } else {
                var pl: error_union.payload = undefined;
                try unmarshal(error_union.payload, reader, &pl, gpa_opt);
                value.* = pl;
            }
        },
        .error_set => |error_set| {
            if (error_set == null) {
                @compileError("Cannot marshal anyerror");
            }
            const set = error_set.?;
            if (set.len == 0) {
                return error.UnmarshalFailed;
            }
            const Int = error_set_conv.Int(T);
            var int: Int = undefined;
            try unmarshal(Int, reader, &int, null);
            // std.debug.print("unmarshal error set: {d}\n", .{int});
            value.* = error_set_conv.errorFromInt(T, int);
        },
    }
}

pub fn DynamicArray(comptime T: type) type {
    const gMarshal = marshal;
    const gUnmarshal = unmarshal;
    return struct {
        const Self = @This();
        slice: []T,

        pub fn marshal(self: Self, writer: *Writer) Writer.Error!void {
            try gMarshal(writer, self.slice.len);
            for (self.slice) |elem| {
                try gMarshal(writer, elem);
            }
        }

        pub fn unmarshal(reader: *Reader, gpa: Allocator) UnmarshalError!Self {
            var len: usize = undefined;
            try gUnmarshal(usize, reader, &len, null);
            const slice = try gpa.alloc(T, len);
            for (0..len) |idx| {
                try gUnmarshal(T, reader, &slice[idx], gpa);
            }
            return .{ .slice = slice };
        }

        pub fn free(self: Self, gpa: Allocator) void {
            gpa.free(self.slice);
        }
    };
}

const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
test "null pointer" {
    const buf: [8]u8 = @splat(0);
    var reader = Reader.fixed(&buf);
    var p: *const u8 = undefined;
    try expectError(error.UnmarshalFailed, unmarshal(*const u8, &reader, &p, null));

    reader = Reader.fixed(&buf);
    var ptr: *const allowzero u8 = undefined;
    try unmarshal(*const allowzero u8, &reader, &ptr, null);
    try expectEqual(0, @intFromPtr(ptr));
}

test "calculate len" {
    const val: u32 = 0;
    const ptr_size = try marshaledLen(&val);
    try expectEqual(@sizeOf(usize), ptr_size);
}

test "error union" {
    const gpa = std.testing.allocator;
    const Error = error {
        AAA,
        A,
        B,
        C,
    };
    var val: [2]Error!u32 = .{12345, Error.AAA};
    _ = &val;
    const buf = try marshalAlloc(gpa, val);
    defer gpa.free(buf);
    var reader = Reader.fixed(buf);
    var result: [2]Error!u32 = undefined;
    try unmarshal(@TypeOf(result), &reader, &result, null);
    try expectEqual(val, result);
}

test "single error set" {
    const gpa = std.testing.allocator;
    const Error = error {
        OnlyOne,
    };
    var val: [2]Error!u32 = .{ 12345, Error.OnlyOne };
    _ = &val;
    const buf = try marshalAlloc(gpa, val);
    defer gpa.free(buf);
    var reader = Reader.fixed(buf);
    var result: [2]Error!u32 = undefined;
    try unmarshal(@TypeOf(result), &reader, &result, null);
    try expectEqual(val, result);
}

test "empty error set" {
    const gpa = std.testing.allocator;

    const Error = error{};
    var val: Error!u32 = 12345;
    _ = &val;
    const buf = try marshalAlloc(gpa, val);
    defer gpa.free(buf);
    var reader = Reader.fixed(buf);
    var result: Error!u32 = undefined;
    try unmarshal(@TypeOf(result), &reader, &result, null);
    try expectEqual(val, result);
}

test "struct has void field" {
    const gpa = std.testing.allocator;

    const T = struct {
        a: void,
        b: [0]u32,
        c: u8,
    };
    var val: T = .{
        .a = {},
        .b = .{},
        .c = 100,
    };
    _ = &val;
    const buf = try marshalAlloc(gpa, val);
    defer gpa.free(buf);
    var reader = Reader.fixed(buf);
    var result: T = undefined;
    try unmarshal(@TypeOf(result), &reader, &result, null);
    try expectEqual(val, result);
}

test "dynamic array" {
    const gpa = std.testing.allocator;
    var pcg = std.Random.Pcg.init(std.testing.random_seed);
    const rng = pcg.random();
    const T = struct {
        a: void,
        b: [0]u32,
        c: ?usize,
    };
    const val: DynamicArray(T) = .{
        .slice = try gpa.alloc(T, 4),
    };
    defer val.free(gpa);
    for (0..val.slice.len) |i| {
        val.slice[i] = .{
            .a = {},
            .b = .{},
            .c = if (rng.boolean()) rng.int(usize) else null,
        };
    }

    const buf = try marshalAlloc(gpa, val);
    defer gpa.free(buf);
    var reader: Reader = .fixed(buf);
    var result: DynamicArray(T) = undefined;
    try unmarshal(DynamicArray(T), &reader, &result, gpa);
    defer result.free(gpa);
    try expectEqualSlices(T, val.slice, result.slice);
}
