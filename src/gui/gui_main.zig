const std = @import("std");
const legnick = @import("legnick");
const app = @import("appimgui");
const ig = app.ig;
const implot = @import("implot");

fn unrollRingBuffer(arena: std.mem.Allocator, list: *std.ArrayList(f32), offset: usize) !void {
    if (offset == 0 or list.items.len <= 1) return;
    const len = list.items.len;
    const temp = try arena.alloc(f32, len);
    defer arena.free(temp);
    std.mem.copyForwards(f32, temp[0 .. len - offset], list.items[offset..len]);
    std.mem.copyForwards(f32, temp[len - offset .. len], list.items[0..offset]);
    std.mem.copyForwards(f32, list.items, temp);
}

fn truncateHistory(list: *std.ArrayList(f32), target_len: usize) void {
    if (list.items.len > target_len) {
        const diff = list.items.len - target_len;
        std.mem.copyForwards(f32, list.items[0..target_len], list.items[diff..list.items.len]);
        list.shrinkRetainingCapacity(target_len);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var init_arena = std.heap.ArenaAllocator.init(allocator);
    defer init_arena.deinit();
    var step_arena = std.heap.ArenaAllocator.init(allocator);
    defer step_arena.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    // Create Window using appimgui (GLFW + OpenGL backend)
    var window = try app.Window.createImGui(1280, 720, "Legnick Macroeconomic Simulation");
    defer window.destroyImGui();

    // Set styling and dark colors
    ig.igStyleColorsDark(null);

    // Initialize ImPlot Context
    _ = implot.ImPlot_CreateContext();
    defer implot.ImPlot_DestroyContext(null);

    // Model Configuration State
    var config_num_firms: i32 = 100;
    var config_num_households: i32 = 1000;
    var config_firm_liq: f32 = 3840.00; // in dollars
    var config_hh_liq: f32 = 900.00;    // in dollars
    var config_seed: i32 = 42;

    // Initialize Simulation Model
    var model = try legnick.model.Model.init(
        init.io,
        init_arena.allocator(),
        @intCast(config_num_firms),
        @intCast(config_num_households),
        @intCast(config_seed),
        @intFromFloat(std.math.round(config_firm_liq * 100.0)),
        @intFromFloat(std.math.round(config_hh_liq * 100.0)),
    );
    defer model.deinit(init_arena.allocator());

    // GUI State
    var run_sim = false;
    var step_count: usize = 0;
    var steps_per_second: i32 = 20;
    var last_step_time = std.Io.Timestamp.now(init.io, .awake);
    var show_daily_wage = true;
    var use_dual_yaxis = true;

    // Sliding window ring buffer settings
    var limit_history = true;
    var max_history_len: i32 = 1000;
    var history_write_count: usize = 0;
    var prev_limit_history = limit_history;
    var prev_max_history_len = max_history_len;

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
        defer _ = frame_arena.reset(.retain_capacity);
        const frame_allocator = frame_arena.allocator();
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
            history_write_count += 1;

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

            if (limit_history and history_steps.items.len >= @as(usize, @intCast(max_history_len))) {
                const cap = @as(usize, @intCast(max_history_len));
                const idx = (history_write_count - 1) % cap;
                history_steps.items[idx] = @as(f32, @floatFromInt(model.steps));
                history_hh_liq.items[idx] = total_hh_liq;
                history_firm_liq.items[idx] = total_firm_liq;
                history_total_liq.items[idx] = total_hh_liq + total_firm_liq;
                history_employed.items[idx] = employed_count;
                history_unemployed.items[idx] = @as(f32, @floatFromInt(hs.len)) - employed_count;
                history_open_positions.items[idx] = open_pos;
                history_avg_price.items[idx] = avg_price;
                history_avg_wage.items[idx] = avg_wage;
                history_avg_res_wage.items[idx] = avg_res_wage;
                history_inventory.items[idx] = total_inv;
            } else {
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
        }

        // Handle dynamic settings changes
        if (limit_history != prev_limit_history or max_history_len != prev_max_history_len) {
            // Determine current offset before change
            var current_offset: usize = 0;
            if (prev_limit_history and history_steps.items.len >= @as(usize, @intCast(prev_max_history_len))) {
                current_offset = history_write_count % @as(usize, @intCast(prev_max_history_len));
            }

            // Unroll all lists to linear arrays
            try unrollRingBuffer(allocator, &history_steps, current_offset);
            try unrollRingBuffer(allocator, &history_hh_liq, current_offset);
            try unrollRingBuffer(allocator, &history_firm_liq, current_offset);
            try unrollRingBuffer(allocator, &history_total_liq, current_offset);
            try unrollRingBuffer(allocator, &history_employed, current_offset);
            try unrollRingBuffer(allocator, &history_unemployed, current_offset);
            try unrollRingBuffer(allocator, &history_open_positions, current_offset);
            try unrollRingBuffer(allocator, &history_avg_price, current_offset);
            try unrollRingBuffer(allocator, &history_avg_wage, current_offset);
            try unrollRingBuffer(allocator, &history_avg_res_wage, current_offset);
            try unrollRingBuffer(allocator, &history_inventory, current_offset);

            // If we are limiting history, truncate to new max_history_len
            if (limit_history) {
                const target_len = @as(usize, @intCast(max_history_len));
                truncateHistory(&history_steps, target_len);
                truncateHistory(&history_hh_liq, target_len);
                truncateHistory(&history_firm_liq, target_len);
                truncateHistory(&history_total_liq, target_len);
                truncateHistory(&history_employed, target_len);
                truncateHistory(&history_unemployed, target_len);
                truncateHistory(&history_open_positions, target_len);
                truncateHistory(&history_avg_price, target_len);
                truncateHistory(&history_avg_wage, target_len);
                truncateHistory(&history_avg_res_wage, target_len);
                truncateHistory(&history_inventory, target_len);
            }

            history_write_count = history_steps.items.len;
            prev_limit_history = limit_history;
            prev_max_history_len = max_history_len;
        }

        // 2. Start new ImGui frame
        window.frame();

        // 3. Render UI Window
        ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, 0, .{ .x = 0, .y = 0 });
        ig.igSetNextWindowSize(.{ .x = 1260, .y = 700 }, 0);
        
        const win_flags = ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize | 
                          ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoCollapse;
        
        if (ig.igBegin("Legnick Baseline Economy Simulation", null, win_flags)) {
            const sidebar_width: f32 = 320.0;
            const window_width = ig.igGetWindowWidth();
            const plots_width = window_width - sidebar_width - 30.0;
            const window_height = ig.igGetWindowHeight();
            const plots_height = window_height - 35.0;

            // 3a. Sidebar Column (Left)
            if (ig.igBeginChild_Str("Sidebar", .{ .x = sidebar_width, .y = plots_height }, 0, 0)) {
                ig.igText("Simulation Control");
                ig.igSeparator();

                // Play / Pause / Step
                if (run_sim) {
                    if (ig.igButton("Pause", .{ .x = -1.0, .y = 0.0 })) run_sim = false;
                } else {
                    if (ig.igButton("Play", .{ .x = -1.0, .y = 0.0 })) run_sim = true;
                }
                if (ig.igButton("Step Once", .{ .x = -1.0, .y = 0.0 })) {
                    try model.step(step_arena.allocator());
                    _ = step_arena.reset(.retain_capacity);
                    step_count += 1;
                }
                
                ig.igSetNextItemWidth(-1.0);
                _ = ig.igSliderInt("Steps / Sec", &steps_per_second, 1, 100, "%d", 0);

                ig.igSpacing();
                ig.igText("Display Settings");
                ig.igSeparator();
                _ = ig.igCheckbox("Limit History", &limit_history);
                if (limit_history) {
                    ig.igSetNextItemWidth(-1.0);
                    _ = ig.igSliderInt("Max History", &max_history_len, 100, 10000, "%d", 0);
                }
                _ = ig.igCheckbox("Daily Wage", &show_daily_wage);
                _ = ig.igCheckbox("Dual Y-Axis", &use_dual_yaxis);

                ig.igSpacing();
                ig.igText("Initial Configuration");
                ig.igSeparator();

                const is_running = model.steps > 0;
                if (is_running) {
                    var val_buf: [128]u8 = undefined;
                    const txt_firms = std.fmt.bufPrintZ(&val_buf, "Firms: {d}", .{config_num_firms}) catch "Firms: Error";
                    ig.igTextUnformatted(txt_firms.ptr, null);
                    const txt_households = std.fmt.bufPrintZ(&val_buf, "Households: {d}", .{config_num_households}) catch "Households: Error";
                    ig.igTextUnformatted(txt_households.ptr, null);
                    const txt_firm_liq = std.fmt.bufPrintZ(&val_buf, "Firm Liquidity: ${d:.2}", .{config_firm_liq}) catch "Firm Liquidity: Error";
                    ig.igTextUnformatted(txt_firm_liq.ptr, null);
                    const txt_hh_liq = std.fmt.bufPrintZ(&val_buf, "Household Liquidity: ${d:.2}", .{config_hh_liq}) catch "Household Liquidity: Error";
                    ig.igTextUnformatted(txt_hh_liq.ptr, null);
                    const txt_seed = std.fmt.bufPrintZ(&val_buf, "Seed: {d}", .{config_seed}) catch "Seed: Error";
                    ig.igTextUnformatted(txt_seed.ptr, null);
                    ig.igSpacing();
                    ig.igText("(*) Reset simulation to edit config.");
                } else {
                    ig.igSetNextItemWidth(-100.0);
                    _ = ig.igSliderInt("Firms", &config_num_firms, 10, 500, "%d", 0);
                    ig.igSetNextItemWidth(-100.0);
                    _ = ig.igSliderInt("Households", &config_num_households, 100, 5000, "%d", 0);
                    ig.igSetNextItemWidth(-100.0);
                    _ = ig.igSliderFloat("Firm Liq ($)", &config_firm_liq, 100.0, 10000.0, "$%.2f", 0);
                    ig.igSetNextItemWidth(-100.0);
                    _ = ig.igSliderFloat("HH Liq ($)", &config_hh_liq, 10.0, 5000.0, "$%.2f", 0);
                    ig.igSetNextItemWidth(-100.0);
                    _ = ig.igSliderInt("Seed", &config_seed, 1, 1000, "%d", 0);
                }

                ig.igSpacing();
                if (ig.igButton("Reset Simulation", .{ .x = -1.0, .y = 0.0 })) {
                    run_sim = false;
                    model.deinit(init_arena.allocator());
                    _ = init_arena.reset(.retain_capacity);
                    
                    const num_firms_usize = @as(usize, @intCast(config_num_firms));
                    const num_households_usize = @as(usize, @intCast(config_num_households));
                    const seed_u64 = @as(u64, @intCast(config_seed));
                    const firm_liq_cents = @as(u64, @intFromFloat(std.math.round(config_firm_liq * 100.0)));
                    const hh_liq_cents = @as(u64, @intFromFloat(std.math.round(config_hh_liq * 100.0)));

                    model = try legnick.model.Model.init(
                        init.io,
                        init_arena.allocator(),
                        num_firms_usize,
                        num_households_usize,
                        seed_u64,
                        firm_liq_cents,
                        hh_liq_cents,
                    );
                    step_count = 0;
                    history_write_count = 0;
                    history_steps.clearRetainingCapacity();
                    history_hh_liq.clearRetainingCapacity();
                    history_firm_liq.clearRetainingCapacity();
                    history_total_liq.clearRetainingCapacity();
                    history_employed.clearRetainingCapacity();
                    history_unemployed.clearRetainingCapacity();
                    history_open_positions.clearRetainingCapacity();
                    history_avg_price.clearRetainingCapacity();
                    history_avg_wage.clearRetainingCapacity();
                    history_avg_res_wage.clearRetainingCapacity();
                    history_inventory.clearRetainingCapacity();
                }

                ig.igSpacing();
                ig.igText("Statistics");
                ig.igSeparator();

                var buf: [256]u8 = undefined;
                const text = std.fmt.bufPrintZ(&buf, "Simulated Days: {d}\nMonths: {d}\nTotal Steps: {d}", .{
                    model.steps,
                    model.steps / model.month_length,
                    step_count,
                }) catch "Error formatting text";
                ig.igTextUnformatted(text.ptr, null);

                ig.igEndChild();
            }

            ig.igSameLine(0, -1);

            // 3b. Plots Column (Right)
            if (ig.igBeginChild_Str("Plots", .{ .x = plots_width, .y = plots_height }, 0, 0)) {
                var plot_offset: c_int = 0;
                var plot_count = @as(c_int, @intCast(history_steps.items.len));
                if (limit_history and history_steps.items.len >= @as(usize, @intCast(max_history_len))) {
                    plot_offset = @intCast(history_write_count % @as(usize, @intCast(max_history_len)));
                    plot_count = @intCast(max_history_len);
                }

                const w = (ig.igGetWindowWidth() - 30) / 2.0;
                const h = (ig.igGetWindowHeight() - 100) / 2.0;

                // Plot 1: Liquidity
                if (implot.ImPlot_BeginPlot("Liquidity (in $)", .{ .x = w, .y = h }, 0)) {
                    implot.ImPlot_SetupAxis(implot.ImAxis_X1, "Steps", implot.ImPlotAxisFlags_AutoFit);
                    implot.ImPlot_SetupAxis(implot.ImAxis_Y1, "Liquidity", implot.ImPlotAxisFlags_AutoFit);
                    implot.ImPlot_SetupFinish();
                    if (history_steps.items.len > 0) {
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Total", history_steps.items.ptr, history_total_liq.items.ptr, plot_count, 0, plot_offset, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Households", history_steps.items.ptr, history_hh_liq.items.ptr, plot_count, 0, plot_offset, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Firms", history_steps.items.ptr, history_firm_liq.items.ptr, plot_count, 0, plot_offset, @intCast(@sizeOf(f32)));
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
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Employed", history_steps.items.ptr, history_employed.items.ptr, plot_count, 0, plot_offset, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Unemployed", history_steps.items.ptr, history_unemployed.items.ptr, plot_count, 0, plot_offset, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Open Positions", history_steps.items.ptr, history_open_positions.items.ptr, plot_count, 0, plot_offset, @intCast(@sizeOf(f32)));
                    }
                    implot.ImPlot_EndPlot();
                }

                // Plot 3: Prices & Wages
                if (implot.ImPlot_BeginPlot("Prices & Wages (Average in $)", .{ .x = w, .y = h }, 0)) {
                    implot.ImPlot_SetupAxis(implot.ImAxis_X1, "Steps", implot.ImPlotAxisFlags_AutoFit);
                    
                    const wage_label = if (show_daily_wage) "Wages (Daily Equiv. $)" else "Wages (Monthly $)";
                    implot.ImPlot_SetupAxis(implot.ImAxis_Y1, wage_label, implot.ImPlotAxisFlags_AutoFit);

                    if (use_dual_yaxis) {
                        implot.ImPlot_SetupAxis(implot.ImAxis_Y2, "Price ($)", implot.ImPlotAxisFlags_Opposite | implot.ImPlotAxisFlags_AutoFit);
                    }
                    
                    implot.ImPlot_SetupFinish();
                    
                    if (history_steps.items.len > 0) {
                        var wage_ptr = history_avg_wage.items.ptr;
                        var res_wage_ptr = history_avg_res_wage.items.ptr;
                        
                        if (show_daily_wage) {
                            const month_len_f32 = @as(f32, @floatFromInt(model.month_length));
                            const temp_wage = try frame_allocator.alloc(f32, history_avg_wage.items.len);
                            const temp_res_wage = try frame_allocator.alloc(f32, history_avg_res_wage.items.len);
                            for (history_avg_wage.items, 0..) |w_val, idx| {
                                temp_wage[idx] = w_val / month_len_f32;
                            }
                            for (history_avg_res_wage.items, 0..) |rw_val, idx| {
                                temp_res_wage[idx] = rw_val / month_len_f32;
                            }
                            wage_ptr = temp_wage.ptr;
                            res_wage_ptr = temp_res_wage.ptr;
                        }

                        // Wages go to Y1
                        implot.ImPlot_SetAxes(implot.ImAxis_X1, implot.ImAxis_Y1);
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Avg Wage", history_steps.items.ptr, wage_ptr, plot_count, 0, plot_offset, @intCast(@sizeOf(f32)));
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Avg Res. Wage", history_steps.items.ptr, res_wage_ptr, plot_count, 0, plot_offset, @intCast(@sizeOf(f32)));

                        // Price goes to Y2 if dual axis is checked, otherwise Y1
                        if (use_dual_yaxis) {
                            implot.ImPlot_SetAxes(implot.ImAxis_X1, implot.ImAxis_Y2);
                        } else {
                            implot.ImPlot_SetAxes(implot.ImAxis_X1, implot.ImAxis_Y1);
                        }
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Avg Price", history_steps.items.ptr, history_avg_price.items.ptr, plot_count, 0, plot_offset, @intCast(@sizeOf(f32)));
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
                        implot.ImPlot_PlotLine_FloatPtrFloatPtr("Inventory", history_steps.items.ptr, history_inventory.items.ptr, plot_count, 0, plot_offset, @intCast(@sizeOf(f32)));
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
