const std = @import("std");
const legnick = @import("legnick");

pub fn main(init: std.process.Init) !void {
    var init_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer init_arena.deinit();
    var step_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer step_arena.deinit();

    var model = try legnick.model.Model.init(init.io, init_arena.allocator(), 100, 1000, 42);
    std.debug.print("model populated!\n", .{});

    const num_steps = 1000;
    var progress = std.Progress.start(init.io, .{
        .root_name = "Simulation Steps",
        .estimated_total_items = num_steps,
    });
    defer progress.end();

    for (0..num_steps) |_| {
        try model.step(step_arena.allocator());
        _ = step_arena.reset(.retain_capacity);
        progress.completeOne();
    }
    model.deinit(init_arena.allocator());
}
