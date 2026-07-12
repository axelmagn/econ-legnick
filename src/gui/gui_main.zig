const std = @import("std");
const legnick = @import("legnick");
const glfw = @import("zglfw");
const gl = @import("zopengl");
const zgui = @import("zgui");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var init_arena = std.heap.ArenaAllocator.init(allocator);
    defer init_arena.deinit();
    var step_arena = std.heap.ArenaAllocator.init(allocator);
    defer step_arena.deinit();

    // Initialize GLFW
    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.context_version_major, 3);
    glfw.windowHint(.context_version_minor, 3);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);

    const window = try glfw.Window.create(1280, 720, "Legnick Macroeconomic Simulation", null, null);
    defer window.destroy();

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1); // v-sync

    // Initialize OpenGL
    try gl.loadCoreProfile(glfw.getProcAddress, 3, 3);
    const gld = gl.bindings;

    // Initialize ImGui
    zgui.init(allocator);
    defer zgui.deinit();

    zgui.plot.init();
    defer zgui.plot.deinit();

    // Initialize the zgui built-in GLFW + OpenGL backend
    zgui.backend.initWithGlSlVersion(window, "#version 150");
    defer zgui.backend.deinit();

    // Initialize Simulation Model
    var model = try legnick.model.Model.init(init.io, init_arena.allocator(), 100, 1000, 42);
    defer model.deinit(init_arena.allocator());

    // GUI State
    var run_sim = false;
    var step_count: usize = 0;
    var steps_per_second: i32 = 20;
    var last_step_time = std.Io.Timestamp.now(init.io, .awake);

    // History data for plotting
    var history_steps: std.ArrayList(f32) = .empty;
    defer history_steps.deinit(allocator);
    var history_hh_liq: std.ArrayList(f32) = .empty;
    defer history_hh_liq.deinit(allocator);
    var history_firm_liq: std.ArrayList(f32) = .empty;
    defer history_firm_liq.deinit(allocator);
    var history_total_liq: std.ArrayList(f32) = .empty;
    defer history_total_liq.deinit(allocator);
    var history_employed: std.ArrayList(f32) = .empty;
    defer history_employed.deinit(allocator);
    var history_unemployed: std.ArrayList(f32) = .empty;
    defer history_unemployed.deinit(allocator);
    var history_open_positions: std.ArrayList(f32) = .empty;
    defer history_open_positions.deinit(allocator);
    var history_avg_price: std.ArrayList(f32) = .empty;
    defer history_avg_price.deinit(allocator);
    var history_avg_wage: std.ArrayList(f32) = .empty;
    defer history_avg_wage.deinit(allocator);
    var history_avg_res_wage: std.ArrayList(f32) = .empty;
    defer history_avg_res_wage.deinit(allocator);
    var history_inventory: std.ArrayList(f32) = .empty;
    defer history_inventory.deinit(allocator);

    while (!window.shouldClose()) {
        glfw.pollEvents();

        // 1. Run simulation steps at the selected speed
        const current_time = std.Io.Timestamp.now(init.io, .awake);
        const elapsed_ms = last_step_time.durationTo(current_time).toMilliseconds();
        const step_delay_ms = @divTrunc(1000, steps_per_second);
        const should_step = run_sim and (elapsed_ms >= step_delay_ms);

        if (should_step) {
            try model.step(step_arena.allocator());
            _ = step_arena.reset(.retain_capacity);
            last_step_time = current_time;
            step_count += 1;

            // Record data to history
            const hs = model.households.data.slice();
            const fs = model.firms.data.slice();
            
            var total_hh_liq: f32 = 0;
            var total_res_wage: f32 = 0;
            var employed_count: f32 = 0;
            for (hs.items(.liquidity)) |liq| total_hh_liq += @as(f32, @floatFromInt(liq)) / 100.0;
            for (hs.items(.reservation_wage)) |rw| total_res_wage += @as(f32, @floatFromInt(rw)) / 100.0;
            for (hs.items(.employer)) |emp| { if (emp != null) employed_count += 1; }

            var total_firm_liq: f32 = 0;
            var total_inv: f32 = 0;
            var open_pos: f32 = 0;
            var total_firm_wage: f32 = 0;
            var total_goods_price: f32 = 0;
            for (fs.items(.liquidity)) |liq| total_firm_liq += @as(f32, @floatFromInt(liq)) / 100.0;
            for (fs.items(.inventory)) |inv| total_inv += @as(f32, @floatFromInt(inv));
            for (fs.items(.has_open_position)) |op| { if (op) open_pos += 1; }
            for (fs.items(.wage_rate)) |w| total_firm_wage += @as(f32, @floatFromInt(w)) / 100.0;
            for (fs.items(.goods_price)) |p| total_goods_price += @as(f32, @floatFromInt(p)) / 100.0;

            const avg_wage = total_firm_wage / @as(f32, @floatFromInt(fs.len));
            const avg_price = total_goods_price / @as(f32, @floatFromInt(fs.len));
            const avg_res_wage = total_res_wage / @as(f32, @floatFromInt(hs.len));

            try history_steps.append(allocator, @as(f32, @floatFromInt(model.steps)));
            try history_hh_liq.append(allocator, total_hh_liq);
            try history_firm_liq.append(allocator, total_firm_liq);
            try history_total_liq.append(allocator, total_hh_liq + total_firm_liq);
            try history_employed.append(allocator, employed_count);
            try history_unemployed.append(allocator, @as(f32, @floatFromInt(hs.len)) - employed_count);
            try history_open_positions.append(allocator, open_pos);
            try history_avg_price.append(allocator, avg_price);
            try history_avg_wage.append(allocator, avg_wage);
            try history_avg_res_wage.append(allocator, avg_res_wage);
            try history_inventory.append(allocator, total_inv);
        }

        // 2. Start new ImGui frame
        const size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(size[0]), @intCast(size[1]));

        // 3. Render UI Window
        zgui.setNextWindowPos(.{ .x = 10, .y = 10 });
        zgui.setNextWindowSize(.{ .w = 1260, .h = 700 });
        
        if (zgui.begin("Legnick Baseline Economy Simulation", .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_collapse = true,
            },
        })) {
            zgui.text("Simulation Status", .{});
            zgui.separator();

            // Controls
            if (run_sim) {
                if (zgui.button("Pause", .{})) run_sim = false;
            } else {
                if (zgui.button("Play", .{})) run_sim = true;
            }
            zgui.sameLine(.{});
            if (zgui.button("Step Once", .{})) {
                try model.step(step_arena.allocator());
                _ = step_arena.reset(.retain_capacity);
                step_count += 1;
            }
            
            zgui.sameLine(.{});
            _ = zgui.sliderInt("Steps / Sec", .{
                .v = &steps_per_second,
                .min = 1,
                .max = 100,
            });

            zgui.text("Simulated Days: {d} | Months: {d} | Total Steps: {d}", .{
                model.steps,
                model.steps / model.month_length,
                step_count,
            });

            zgui.separator();

            // Plots layout (2x2 grid)
            if (zgui.beginChild("Plots", .{ .w = 0, .h = 0 })) {
                const w = (zgui.getWindowWidth() - 30) / 2.0;
                const h = (zgui.getWindowHeight() - 100) / 2.0;

                // Plot 1: Liquidity
                if (zgui.plot.beginPlot("Liquidity (in $)", .{ .w = w, .h = h })) {
                    zgui.plot.setupAxis(.x1, .{ .label = "Steps", .flags = .{ .auto_fit = true } });
                    zgui.plot.setupAxis(.y1, .{ .label = "Liquidity", .flags = .{ .auto_fit = true } });
                    zgui.plot.setupFinish();
                    if (history_steps.items.len > 0) {
                        zgui.plot.plotLine("Total", f32, .{ .xv = history_steps.items, .yv = history_total_liq.items });
                        zgui.plot.plotLine("Households", f32, .{ .xv = history_steps.items, .yv = history_hh_liq.items });
                        zgui.plot.plotLine("Firms", f32, .{ .xv = history_steps.items, .yv = history_firm_liq.items });
                    }
                    zgui.plot.endPlot();
                }

                zgui.sameLine(.{});

                // Plot 2: Employment
                if (zgui.plot.beginPlot("Employment", .{ .w = w, .h = h })) {
                    zgui.plot.setupAxis(.x1, .{ .label = "Steps", .flags = .{ .auto_fit = true } });
                    zgui.plot.setupAxis(.y1, .{ .label = "People / Vacancies", .flags = .{ .auto_fit = true } });
                    zgui.plot.setupFinish();
                    if (history_steps.items.len > 0) {
                        zgui.plot.plotLine("Employed", f32, .{ .xv = history_steps.items, .yv = history_employed.items });
                        zgui.plot.plotLine("Unemployed", f32, .{ .xv = history_steps.items, .yv = history_unemployed.items });
                        zgui.plot.plotLine("Open Positions", f32, .{ .xv = history_steps.items, .yv = history_open_positions.items });
                    }
                    zgui.plot.endPlot();
                }

                // Plot 3: Prices & Wages
                if (zgui.plot.beginPlot("Prices & Wages (Average in $)", .{ .w = w, .h = h })) {
                    zgui.plot.setupAxis(.x1, .{ .label = "Steps", .flags = .{ .auto_fit = true } });
                    zgui.plot.setupAxis(.y1, .{ .label = "Wage/Price", .flags = .{ .auto_fit = true } });
                    zgui.plot.setupFinish();
                    if (history_steps.items.len > 0) {
                        zgui.plot.plotLine("Avg Price", f32, .{ .xv = history_steps.items, .yv = history_avg_price.items });
                        zgui.plot.plotLine("Avg Wage", f32, .{ .xv = history_steps.items, .yv = history_avg_wage.items });
                        zgui.plot.plotLine("Avg Res. Wage", f32, .{ .xv = history_steps.items, .yv = history_avg_res_wage.items });
                    }
                    zgui.plot.endPlot();
                }

                zgui.sameLine(.{});

                // Plot 4: Inventory
                if (zgui.plot.beginPlot("Inventories (Total Goods)", .{ .w = w, .h = h })) {
                    zgui.plot.setupAxis(.x1, .{ .label = "Steps", .flags = .{ .auto_fit = true } });
                    zgui.plot.setupAxis(.y1, .{ .label = "Goods Quantity", .flags = .{ .auto_fit = true } });
                    zgui.plot.setupFinish();
                    if (history_steps.items.len > 0) {
                        zgui.plot.plotLine("Inventory", f32, .{ .xv = history_steps.items, .yv = history_inventory.items });
                    }
                    zgui.plot.endPlot();
                }

                zgui.endChild();
            }
        }
        zgui.end();

        // 4. OpenGL Render
        gld.clearColor(0.15, 0.16, 0.18, 1.00);
        gld.clear(gld.COLOR_BUFFER_BIT);

        zgui.backend.draw();

        window.swapBuffers();
    }
}
