const std = @import("std");

pub fn build(b: *std.Build) void {
    const legnick_mod = b.addModule("legnick", .{
        .root_source_file = b.path("src/legnick/root.zig"),
        .target = b.graph.host,
    });
    const legnick_lib = b.addLibrary(.{
        .name = "legnick",
        .root_module = legnick_mod,
    });
    b.installArtifact(legnick_lib);

    const legnick_sim_exe = b.addExecutable(.{
        .name = "legnick_sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "legnick", .module = legnick_mod }},
        }),
    });
    b.installArtifact(legnick_sim_exe);
}
