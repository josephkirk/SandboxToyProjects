const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var list = try std.ArrayList(i32).initCapacity(allocator, 10);
    defer list.deinit();
    try list.append(allocator, 10);
    std.debug.print("Items: {d}\n", .{list.items.len});
}
