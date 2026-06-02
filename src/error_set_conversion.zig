const std = @import("std");

pub fn Int(comptime ErrorSet: type) type {
    const error_set_len = @typeInfo(ErrorSet).error_set.?.len;
    return std.meta.Int(.unsigned, std.math.log2_int_ceil(usize, error_set_len));
}

pub fn intFromError(comptime ErrorSet: type, error_set: ErrorSet) Int(ErrorSet) {
    const table = errorSetTable(ErrorSet)[1];
    const idx = std.sort.binarySearch(struct { ErrorSet, usize }, table, error_set, struct {fn compare(val: ErrorSet, x: struct { ErrorSet, usize }) std.math.Order {
        return std.math.order(@intFromError(val), @intFromError(x[0]));
    }}.compare) orelse unreachable;
    return @intCast(table[idx][1]);
}

pub fn errorFromInt(comptime ErrorSet: type, val: Int(ErrorSet)) ErrorSet {
    const table = errorSetTable(ErrorSet)[0];
    if (ErrorSet == error{}) @panic("Unexpected Error ID");
    if (val > table.len) @panic("Unexpected error ID");
    return table[val];
}

pub fn comptimeSort(
    comptime T: type,
    comptime items: []const T,
    comptime lessThanFn: fn (lhs: T, rhs: T) bool
) [items.len]T {
    var list: [items.len]T = undefined;
    inline for (0.., items) |idx, item| {
        list[idx] = item;
    }
    std.mem.sort(T, list[0..], {}, struct {fn lessThan(_: void, lhs: T, rhs: T) bool {
        return lessThanFn(lhs, rhs);
    }}.lessThan);
    return list;
}

pub fn errorSetTable(comptime ErrorSet: type) struct { []const ErrorSet, []const struct { ErrorSet, usize } } {
    const list = @typeInfo(ErrorSet).error_set orelse @compileError("Conversion of c_int between anyerror is not supported.");
    const Type = std.builtin.Type;
    const sorted = comptime comptimeSort(Type.Error, list, struct {fn lessThan(lhs: Type.Error, rhs: Type.Error) bool {
        return std.mem.order(u8, lhs.name, rhs.name) == .lt;
    }}.lessThan);
    comptime var int_to_error: []const ErrorSet = &.{};
    comptime var error_to_int: []const struct {ErrorSet, usize} = &.{};

    inline for (0.., sorted) |idx, err| {
        const err_val = @field(ErrorSet, err.name);
        int_to_error = int_to_error ++ [_]ErrorSet{err_val};
        error_to_int = error_to_int ++ [_]struct {ErrorSet, usize}{.{err_val, idx}};
    }

    // 内部表現の数値でソート
    // インデックスを取得するにはこれを用いて二分探索する
    error_to_int = &comptime comptimeSort(struct {ErrorSet, usize}, error_to_int, struct {fn lessThan(lhs: struct {ErrorSet, usize}, rhs: struct {ErrorSet, usize}) bool {
        return @intFromError(lhs[0]) < @intFromError(rhs[0]);
    }}.lessThan);
    return .{int_to_error, error_to_int};
}
