const std = @import("std");
const households = @import("households.zig");
const firms = @import("firms.zig");
const core = @import("core.zig");

pub const Model = struct {
    prng: std.Random.DefaultPrng = undefined,
    // gpa: std.mem.Allocator,
    io: std.Io,
    steps: usize = 0,
    poverty_level: f32 = 1,
    labor_supply: f32 = 1,
    month_length: usize = 28,
    households: households.Households = .{},
    firms: firms.Firms = .{},
    stats_file: std.Io.File,

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        num_firms: usize,
        num_households: usize,
        seed: u64,
        initial_firm_liquidity: core.Currency,
        initial_household_liquidity: core.Currency,
    ) !Model { // TODO: explicit errors
        var self: Model = .{
            .prng = std.Random.DefaultPrng.init(seed),
            .io = io,
            .stats_file = try std.Io.Dir.cwd().createFile(io, "simulation_stats.csv", .{}),
        };
        self.firms.config.initial_liquidity = initial_firm_liquidity;
        self.households.config.initial_liquidity = initial_household_liquidity;
        try self.firms.populate(num_firms, self.labor_supply, self.month_length, gpa);
        try self.households.populate(num_households, num_firms, gpa, self.prng.random());
        try self.stats_file.writeStreamingAll(self.io, StepStats.csv_header);
        return self;
    }

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        self.stats_file.close(self.io);
        self.firms.deinit(gpa);
        self.households.deinit(gpa);
    }

    pub fn step(self: *Model, arena: std.mem.Allocator) !void {
        const random = self.prng.random();

        const households_slice = self.households.data.slice();
        const firms_slice = self.firms.data.slice();

        // create a random shuffle of household IDs
        const num_households = self.households.data.len;
        var households_order = try arena.alloc(core.Id, num_households);
        for (0..num_households) |i| households_order[i] = i;
        random.shuffle(core.Id, households_order);

        const is_month_start = self.steps % self.month_length == 0;
        if (is_month_start) {
            self.firms.onMonthStart(&households_slice, households_order, random);
            self.households.onMonthStart(random, &firms_slice, self.month_length);
        }
        const is_month_end = (self.steps + 1) % self.month_length == 0;
        if (is_month_end) {
            try self.firms.onMonthEnd(&households_slice, arena);
            self.households.onMonthEnd(&firms_slice);
        }
        const days_left = self.month_length - (self.steps % self.month_length);
        try self.firms.onDay(&households_slice, self.labor_supply, arena);
        self.households.onDay(&firms_slice, random, days_left);

        // record statistics
        try self.logStats();

        self.steps += 1;
    }

    fn logStats(self: *Model) !void {
        const households_slice = self.households.data.slice();
        const firms_slice = self.firms.data.slice();

        var total_hh_liq: u64 = 0;
        var total_reservation_wage: u64 = 0;
        var employed_count: usize = 0;
        for (households_slice.items(.liquidity)) |liq| {
            total_hh_liq += liq;
        }
        for (households_slice.items(.reservation_wage)) |rw| {
            total_reservation_wage += rw;
        }
        for (households_slice.items(.employer)) |employer| {
            if (employer != null) {
                employed_count += 1;
            }
        }

        var total_firm_liq: u64 = 0;
        var total_inventory: u64 = 0;
        var open_positions: usize = 0;
        var total_firm_wage: u64 = 0;
        var total_goods_price: u64 = 0;
        for (firms_slice.items(.liquidity)) |liq| {
            total_firm_liq += liq;
        }
        for (firms_slice.items(.inventory)) |inv| {
            total_inventory += inv;
        }
        for (firms_slice.items(.has_open_position)) |op| {
            if (op) {
                open_positions += 1;
            }
        }
        for (firms_slice.items(.wage_rate)) |w| {
            total_firm_wage += w;
        }
        for (firms_slice.items(.goods_price)) |p| {
            total_goods_price += p;
        }

        var total_employed_wage: u64 = 0;
        for (households_slice.items(.employer)) |employer| {
            if (employer) |emp_id| {
                total_employed_wage += firms_slice.items(.wage_rate)[emp_id];
            }
        }

        const num_hh = households_slice.len;
        const num_f = firms_slice.len;

        const avg_employed_wage = if (employed_count > 0)
            @as(f64, @floatFromInt(total_employed_wage)) / @as(f64, @floatFromInt(employed_count))
        else
            0.0;
        const avg_firm_wage = @as(f64, @floatFromInt(total_firm_wage)) / @as(f64, @floatFromInt(num_f));
        const avg_goods_price = @as(f64, @floatFromInt(total_goods_price)) / @as(f64, @floatFromInt(num_f));
        const avg_res_wage = @as(f64, @floatFromInt(total_reservation_wage)) / @as(f64, @floatFromInt(num_hh));

        const stats = StepStats{
            .step = self.steps,
            .total_liquidity = total_hh_liq + total_firm_liq,
            .total_household_liquidity = total_hh_liq,
            .total_firm_liquidity = total_firm_liq,
            .employed_count = employed_count,
            .unemployed_count = num_hh - employed_count,
            .open_positions = open_positions,
            .total_inventory = total_inventory,
            .average_employed_wage = avg_employed_wage,
            .average_firm_wage = avg_firm_wage,
            .average_goods_price = avg_goods_price,
            .average_reservation_wage = avg_res_wage,
        };

        var buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{f}", .{stats});
        try self.stats_file.writeStreamingAll(self.io, line);
    }
};

pub const StepStats = struct {
    step: usize,
    total_liquidity: u64,
    total_household_liquidity: u64,
    total_firm_liquidity: u64,
    employed_count: usize,
    unemployed_count: usize,
    open_positions: usize,
    total_inventory: u64,
    average_employed_wage: f64,
    average_firm_wage: f64,
    average_goods_price: f64,
    average_reservation_wage: f64,

    pub const csv_header = blk: {
        const fields = std.meta.fields(StepStats);
        var header: []const u8 = "";
        for (fields, 0..) |field, i| {
            header = header ++ field.name;
            if (i < fields.len - 1) {
                header = header ++ ",";
            } else {
                header = header ++ "\n";
            }
        }
        break :blk header;
    };

    pub fn format(
        self: StepStats,
        writer: anytype,
    ) !void {
        const fields = std.meta.fields(StepStats);
        inline for (fields, 0..) |field, i| {
            const val = @field(self, field.name);
            switch (field.type) {
                f32, f64 => try writer.print("{d:.2}", .{val}),
                else => try writer.print("{}", .{val}),
            }
            if (i < fields.len - 1) {
                try writer.writeAll(",");
            } else {
                try writer.writeAll("\n");
            }
        }
    }
};
