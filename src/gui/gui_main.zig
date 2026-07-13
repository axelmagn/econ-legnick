const std = @import("std");
const legnick = @import("legnick");
const app = @import("appimgui");
const ig = app.ig;
const implot = @import("implot");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var init_arena = std.heap.ArenaAllocator.init(allocator);
    defer init_arena.deinit();
    var step_arena = std.heap.ArenaAllocator.init(allocator);
    defer step_arena.deinit();

    // Create Window using appimgui (GLFW + OpenGL backend)
    var window = try app.Window.createImGui(1280, 720, "Legnick Macroeconomic Simulation");
    defer window.destroyImGui();

    // Set styling and dark colors
    ig.igStyleColorsDark(null);

    // Initialize ImPlot Context
    _ = implot.ImPlot_CreateContext();
    defer implot.ImPlot_DestroyContext(null);

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
        window.pollEvents();
        if (window.isIconified()) continue;

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
        window.frame();

        // 3. Render UI Window
        ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, 0, .{ .x = 0, .y = 0 });
        ig.igSetNextWindowSize(.{ .x = 1260, .y = 700 }, 0);
        
        const win_flags = ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize | 
                          ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoCollapse;
        
        if (ig.igBegin("Legnick Baseline Economy Simulation", null, win_flags)) {
            ig.igText("Simulation Status");
            ig.igSeparator();

            // Controls
            if (run_sim) {
                if (ig.igButton("Pause", .{ .x = 0, .y = 0 })) run_sim = false;
            } else {
                if (ig.igButton("Play", .{ .x = 0, .y = 0 })) run_sim = true;
            }
            ig.igSameLine(0, -1);
            if (ig.igButton("Step Once", .{ .x = 0, .y = 0 })) {
                try model.step(step_arena.allocator());
                _ = step_arena.reset(.retain_capacity);
                step_count += 1;
            }
            
            ig.igSameLine(0, -1);
            _ = ig.igSliderInt("Steps / Sec", &steps_per_second, 1, 100, "%d", 0);

            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrintZ(&buf, "Simulated Days: {d} | Months: {d} | Total Steps: {d}", .{
                model.steps,
                model.steps / model.month_length,
                step_count,
            }) catch "Error formatting text";
            ig.igTextUnformatted(text.ptr, null);

            ig.igSeparator();

            // Plots layout (2x2 grid)
            if (ig.igBeginChild_Str("Plots", .{ .x = 0, .y = 0 }, 0, 0)) {
                const w = (ig.igGetWindowWidth() - 30) / 2.0;
                const h = (ig.igGetWindowHeight() - 100) / 2.0;

                // Plot 1: Liquidity
                if (implot.ImPlot_BeginPlot("Liquidity (in $)", .{ .x = w, .y = h }, 0)) {
                    implot.ImPlot_SetupAxis(implot.ImAxis_X1, "Steps", implot.ImPlotAxisFlags_AutoFit);
                    implot.ImPlot_SetupAxis(implot.ImAxis_Y1, "Liquidity", implot.ImPlotAxisFlags_AutoFit);
                    implot.ImPlot_SetupFinish();
                    if (history_steps.items.len > 0) {
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Total", history_steps.items.ptr, history_total_liq.items.ptr, @intCast(history_steps.items.len), 0, 0, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Households", history_steps.items.ptr, history_hh_liq.items.ptr, @intCast(history_steps.items.len), 0, 0, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Firms", history_steps.items.ptr, history_firm_liq.items.ptr, @intCast(history_steps.items.len), 0, 0, @intCast(@sizeOf(f32)));
                    }
                    implot.ImPlot_EndPlot();
                }

                ig.igSameLine(0, -1);

                // Plot 2: Employment
                if (implot.ImPlot_BeginPlot("Employment", .{ .x = w, .y = h }, 0)) {
                    implot.ImPlot_SetupAxis(implot.ImAxis_X1, "Steps", implot.ImPlotAxisFlags_AutoFit);
                    implot.ImPlot_SetupAxis(implot.ImAxis_Y1, "People / Vacancies", implot.ImPlotAxisFlags_AutoFit);
                    implot.ImPlot_SetupFinish();
                    if (history_steps.items.len > 0) {
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Employed", history_steps.items.ptr, history_employed.items.ptr, @intCast(history_steps.items.len), 0, 0, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Unemployed", history_steps.items.ptr, history_unemployed.items.ptr, @intCast(history_steps.items.len), 0, 0, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Open Positions", history_steps.items.ptr, history_open_positions.items.ptr, @intCast(history_steps.items.len), 0, 0, @intCast(@sizeOf(f32)));
                    }
                    implot.ImPlot_EndPlot();
                }

                // Plot 3: Prices & Wages
                if (implot.ImPlot_BeginPlot("Prices & Wages (Average in $)", .{ .x = w, .y = h }, 0)) {
                    implot.ImPlot_SetupAxis(implot.ImAxis_X1, "Steps", implot.ImPlotAxisFlags_AutoFit);
                    implot.ImPlot_SetupAxis(implot.ImAxis_Y1, "Wage/Price", implot.ImPlotAxisFlags_AutoFit);
                    implot.ImPlot_SetupFinish();
                    if (history_steps.items.len > 0) {
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Avg Price", history_steps.items.ptr, history_avg_price.items.ptr, @intCast(history_steps.items.len), 0, 0, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Avg Wage", history_steps.items.ptr, history_avg_wage.items.ptr, @intCast(history_steps.items.len), 0, 0, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Avg Res. Wage", history_steps.items.ptr, history_avg_res_wage.items.ptr, @intCast(history_steps.items.len), 0, 0, @intCast(@sizeOf(f32)));
                    }
                    implot.ImPlot_EndPlot();
                }

                ig.igSameLine(0, -1);

                // Plot 4: Inventory
                if (implot.ImPlot_BeginPlot("Inventories (Total Goods)", .{ .x = w, .y = h }, 0)) {
                    implot.ImPlot_SetupAxis(implot.ImAxis_X1, "Steps", implot.ImPlotAxisFlags_AutoFit);
                    implot.ImPlot_SetupAxis(implot.ImAxis_Y1, "Goods Quantity", implot.ImPlotAxisFlags_AutoFit);
                    implot.ImPlot_SetupFinish();
                    if (history_steps.items.len > 0) {
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Inventory", history_steps.items.ptr, history_inventory.items.ptr, @intCast(history_steps.items.len), 0, 0, @intCast(@sizeOf(f32)));
                    }
                    implot.ImPlot_EndPlot();
                }

                ig.igEndChild();
            }
        }
        ig.igEnd();

        // 4. OpenGL Render
        window.render();
    }
}
