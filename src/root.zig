const std = @import("std");

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
                if (field.is_comptime) {
                    @compileError("Marshaling unsupported type value");
                }
                try marshal(writer, @field(value, field.name));
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
            @panic("Unimplemented");
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

pub fn unmarshal(comptime T: type, reader: *Reader, value: *T) Reader.Error!void {
    const info = @typeInfo(T);
    switch (info) {
        .@"anyframe", .frame, .comptime_int, .comptime_float, .@"fn", .enum_literal, .noreturn, .null, .type, .undefined => @compileError("Marshaling unsupported type value"),
        .array => |array| {
            for (0..array.len) |idx| {
                value.*[idx] = try unmarshal(array.child, reader);
            }
        },
        .vector => |vector| {
            for (0..vector.len) |idx| {
                value.*[idx] = try unmarshal(vector.child, reader);
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
            if (@hasDecl(T, "marshal")) {
                value.* = try T.unmarshal(reader);
                return;
            }
            inline for (struct_info.fields) |field| {
                if (field.is_comptime) {
                    @compileError("Marshaling unsupported type value");
                }
                try unmarshal(field.type, reader, &@field(value, field.name));
            }
        },
        .@"enum" => |enum_info| {
            if (@hasDecl(T, "marshal")) {
                value.* = try T.unmarshal(reader);
            }
            var int: @TypeOf(@intFromEnum(@as(T, undefined))) = undefined;
            try unmarshal(@TypeOf(int), reader, &int);
            inline for (enum_info.fields) |field| {
                if (int == field.value) {
                    value.* = @as(T, @enumFromInt(field.value));
                    return;
                }
            }
            return Reader.Error.ReadFailed;
        },
        .@"union" => |union_info| {
            if (@hasDecl(T, "marshal")) {
                value.* = try T.unmarshal(reader);
            }
            if (union_info.tag_type == null) {
                @compileError("Untagged Union is not supported.");
            }
            const Tag = union_info.tag_type.?;
            var tag: Tag = undefined;
            try unmarshal(Tag, reader, &tag);
            const tag_info = @typeInfo(Tag).@"enum";
            inline for (tag_info.fields) |tag_field| {
                if (@intFromEnum(tag) == tag_field.value) {
                    var val: @TypeOf(@field(@as(T, undefined), tag_field.name)) = undefined;
                    try unmarshal(@TypeOf(val), reader, &val);
                    value.* = @unionInit(T, tag_field.name, val);
                    return;
                }
            }
            unreachable;
        },
        .int => |int| {
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
            const has_value = try unmarshal(bool, reader);
            if (has_value) {
                var v: optional.child = undefined;
                try unmarshal(optional.child, reader, &v);
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
                return error.ReadFailed;
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
            try unmarshal(bool, reader, &is_err);
            if (is_err) {
                var err: error_union.error_set = undefined;
                try unmarshal(error_union.error_set, reader, &err);
                value.* = err;
            } else {
                var pl: error_union.payload = undefined;
                try unmarshal(error_union.payload, reader, &pl);
                value.* = pl;
            }
        },
        .error_set => |error_set| {
            if (error_set == null) {
                @compileError("Cannot marshal anyerror");
            }
            const set = error_set.?;
            if (set.len == 0) {
                return error.Failed;
            }
            @panic("Unimplemented");
        },
    }
}

const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
test "null pointer" {
    const buf: [8]u8 = @splat(0);
    var reader = Reader.fixed(&buf);
    var p: *const u8 = undefined;
    try expectError(error.ReadFailed, unmarshal(*const u8, &reader, &p));

    reader = Reader.fixed(&buf);
    var ptr: *const allowzero u8 = undefined;
    try unmarshal(*const allowzero u8, &reader, &ptr);
    try expectEqual(0, @intFromPtr(ptr));
}

test "calculate len" {
    const val: u32 = 0;
    const ptr_size = try marshaledLen(&val);
    try expectEqual(@sizeOf(usize), ptr_size);
}
