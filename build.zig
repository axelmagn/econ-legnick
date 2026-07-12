const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const legnick_mod = b.addModule("legnick", .{
        .root_source_file = b.path("src/legnick/root.zig"),
        .target = b.graph.host,
    });
    const legnick_lib = b.addLibrary(.{
        .name = "legnick",
        .root_module = legnick_mod,
    });
    b.installArtifact(legnick_lib);

    // Headless CLI executable
    const legnick_sim_exe = b.addExecutable(.{
        .name = "legnick_sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "legnick", .module = legnick_mod }},
        }),
    });
    b.installArtifact(legnick_sim_exe);

    // GUI executable
    const legnick_sim_gui_exe = b.addExecutable(.{
        .name = "legnick_sim_gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui/gui_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "legnick", .module = legnick_mod }},
        }),
    });

    // GUI dependencies - configure zgui with glfw_opengl3 backend
    const zgui = b.dependency("zgui", .{
        .shared = false,
        .with_implot = true,
        .backend = .glfw_opengl3,
    });
    const zglfw = b.dependency("zglfw", .{});
    const zopengl = b.dependency("zopengl", .{});

    legnick_sim_gui_exe.root_module.addImport("zgui", zgui.module("root"));
    legnick_sim_gui_exe.root_module.addImport("zglfw", zglfw.module("root"));
    legnick_sim_gui_exe.root_module.addImport("zopengl", zopengl.module("root"));

    legnick_sim_gui_exe.root_module.linkLibrary(zgui.artifact("imgui"));
    legnick_sim_gui_exe.root_module.linkLibrary(zglfw.artifact("glfw"));

    b.installArtifact(legnick_sim_gui_exe);
}
