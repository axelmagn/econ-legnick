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
        .use_llvm = true,
    });
    // GUI dependencies - configure imguinz
    const imguinz = b.dependency("imguinz", .{
        .target = target,
        .optimize = optimize,
    });

    const appimgui_dep = imguinz.builder.dependency("appimgui", .{
        .target = target,
        .optimize = optimize,
    });
    const implot_dep = imguinz.builder.dependency("implot", .{
        .target = target,
        .optimize = optimize,
    });

    legnick_sim_gui_exe.root_module.addImport("appimgui", appimgui_dep.module("appimgui"));
    legnick_sim_gui_exe.root_module.addImport("implot", implot_dep.module("implot"));

    b.installArtifact(legnick_sim_gui_exe);
}
