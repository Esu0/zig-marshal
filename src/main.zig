const std = @import("std");
const zig_marshal = @import("zig_marshal");

const A = union(enum) {
    a: u32,
    b: u8,
    c: u16,
    d,
};


pub fn main(init: std.process.Init) !void {

    const gpa = init.arena.allocator();
    var allocating_writer = std.Io.Writer.Allocating.init(gpa);
    const writer = &allocating_writer.writer;
    const a: A = .{ .a = 100 };
    try zig_marshal.marshal(writer, a);
    try zig_marshal.marshal(writer, &a);
    const written = allocating_writer.written();
    std.debug.print("{any}\n", .{written});

    var reader = std.Io.Reader.fixed(written);
    const val = try zig_marshal.unmarshal(A, &reader);
    const ptr = try zig_marshal.unmarshal(*const A, &reader);
    std.debug.print("val = {any}\n", .{val});
    std.debug.print("ptr = {*}\n", .{ptr});
}
