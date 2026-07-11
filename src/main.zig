const std = @import("std");
const legnick = @import("legnick");

pub fn main(init: std.process.Init) !void {
    var init_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer init_arena.deinit();
    var step_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer step_arena.deinit();

    var model = try legnick.model.Model.init(init_arena.allocator(), 100, 1000, 42);
    std.debug.print("model populated!\n", .{});

    for (0..1000) |_| {
        try model.step(step_arena.allocator());
        _ = step_arena.reset(.retain_capacity);
    }
}
