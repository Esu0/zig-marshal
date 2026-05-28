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

pub fn unmarshal(comptime T: type, reader: *Reader) Reader.Error!T {
    const info = @typeInfo(T);
    switch (info) {
        .@"anyframe", .frame, .comptime_int, .comptime_float, .@"fn", .enum_literal, .noreturn, .null, .type, .undefined => @compileError("Marshaling unsupported type value"),
        .array => |array| {
            var value: T = undefined;
            for (0..array.len) |idx| {
                value[idx] = try unmarshal(array.child, reader);
            }
            return value;
        },
        .vector => |vector| {
            var value: T = undefined;
            for (0..vector.len) |idx| {
                value[idx] = try unmarshal(vector.child, reader);
            }
            return value;
        },
        .@"opaque" => {
            if (@hasDecl(T, "unmarshal")) {
                return try T.unmarshal(reader);
            }
            @compileError("Marshaling unsupported type value");
        },
        .@"struct" => |struct_info| {
            if (@hasDecl(T, "marshal")) {
                return try T.unmarshal(reader);
            }
            var value: T = undefined;
            inline for (struct_info.fields) |field| {
                if (field.is_comptime) {
                    @compileError("Marshaling unsupported type value");
                }
                @field(value, field.name) = try unmarshal(field.type, reader);
            }
            return value;
        },
        .@"enum" => |enum_info| {
            if (@hasDecl(T, "marshal")) {
                return try T.unmarshal(reader);
            }
            const int = try unmarshal(@TypeOf(@intFromEnum(@as(T, undefined))), reader);
            inline for (enum_info.fields) |field| {
                if (int == field.value) {
                    return @as(T, @enumFromInt(field.value));
                }
            }
            return Reader.Error.ReadFailed;
        },
        .@"union" => |union_info| {
            if (@hasDecl(T, "marshal")) {
                return try T.unmarshal(reader);
            }
            if (union_info.tag_type == null) {
                @compileError("Untagged Union is not supported.");
            }
            const Tag = union_info.tag_type.?;
            const tag = @intFromEnum(try unmarshal(Tag, reader));
            const tag_info = @typeInfo(Tag).@"enum";
            inline for (tag_info.fields) |tag_field| {
                if (tag == tag_field.value) {
                    return @unionInit(T, tag_field.name, try unmarshal(@TypeOf(@field(@as(T, undefined), tag_field.name)), reader));
                }
            }
            unreachable;
        },
        .int => |int| {
            var buf: [std.math.divCeil(usize, int.bits, 8) catch unreachable]u8 = undefined;
            try reader.readSliceAll(&buf);
            return std.mem.readPackedInt(T, &buf, 0, .little);
        },
        .float => {
            const size = @sizeOf(T);
            var buf: [size]u8 = undefined;
            try reader.readSliceAll(&buf);
            return std.mem.bytesAsValue(T, buf).*;
        },
        .bool => {
            var byte: [1]u8 = undefined;
            try reader.readSliceAll(&byte);
            return (byte[0] & 1) != 0;
        },
        .optional => |optional| {
            const has_value = try unmarshal(bool, reader);
            if (has_value) {
                return try unmarshal(optional.child, reader);
            } else {
                return null;
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
                return if (pointer.sentinel()) |sentinel| {
                    return many[0..size : sentinel];
                } else {
                    return many[0..size];
                };
            } else {
                return @as(T, @ptrFromInt(int));
            }
        },
        .error_union => |error_union| {
            const is_err = try unmarshal(bool, reader);
            if (is_err) {
                return try unmarshal(error_union.error_set, reader);
            } else {
                return try unmarshal(error_union.payload, reader);
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
    try expectError(error.ReadFailed, unmarshal(*const u8, &reader));

    reader = Reader.fixed(&buf);
    const ptr = try unmarshal(*const allowzero u8, &reader);
    try expectEqual(0, @intFromPtr(ptr));
}
