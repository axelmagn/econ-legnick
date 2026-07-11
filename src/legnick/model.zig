const std = @import("std");
const households = @import("households.zig");
const firms = @import("firms.zig");
const core = @import("core.zig");

pub const Model = struct {
    prng: std.Random.DefaultPrng = undefined,
    // gpa: std.mem.Allocator,
    // io: std.Io,
    steps: usize = 0,
    poverty_level: f32 = 1,
    labor_supply: f32 = 1,
    month_length: usize = 28,
    households: households.Households = .{},
    firms: firms.Firms = .{},

    pub fn init(
        gpa: std.mem.Allocator,
        num_firms: usize,
        num_households: usize,
        seed: u64,
    ) !Model { // TODO: explicit errors
        var self: Model = .{
            .prng = std.Random.DefaultPrng.init(seed),
        };
        try self.firms.populate(num_firms, self.labor_supply, self.month_length, gpa);
        try self.households.populate(num_households, num_firms, gpa, self.prng.random());
        return self;
    }

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
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
            std.debug.print("\nstep {} is the start of a new month\n", .{self.steps});
            self.firms.onMonthStart(&households_slice, households_order, random);
            self.households.onMonthStart(random, &firms_slice, self.month_length);

            // report summary statistics
            
            // avg wage
            var avg_wage: f64 = 0;
            for(households_slice.items(.employer)) |employer| {
                if (employer != null) {
                    const wage = firms_slice.items(.wage_rate)[employer.?];
                    avg_wage += @floatFromInt(wage);
                }
            }
            avg_wage /= @floatFromInt(households_slice.len);
            std.debug.print("average wage: {}\n", .{avg_wage});

            // avg inventory
            var avg_inventory: f64 = 0;
            for(firms_slice.items(.inventory)) |inventory|{
                avg_inventory += @floatFromInt(inventory);
            }
            avg_inventory /= @floatFromInt(firms_slice.len);
            std.debug.print("average inventory: {}\n", .{avg_inventory});

            // avg price
            var avg_goods_price: f64 = 0;
            for(firms_slice.items(.goods_price)) |goods_price|{
                avg_goods_price += @floatFromInt(goods_price);
            }
            avg_goods_price /= @floatFromInt(firms_slice.len);
            std.debug.print("average goods price: {}\n", .{avg_goods_price});

            // avg firm liquidity
            var avg_firm_liquidity: f64 = 0;
            for(firms_slice.items(.liquidity)) |firm_liquidity|{
                avg_firm_liquidity += @floatFromInt(firm_liquidity);
            }
            avg_firm_liquidity /= @floatFromInt(firms_slice.len);
            std.debug.print("average firm liquidity: {}\n", .{avg_firm_liquidity});

            var avg_household_liquidity: f64 = 0;
            for(households_slice.items(.liquidity)) |household_liquidity| {
                avg_household_liquidity += @floatFromInt(household_liquidity);
            }
            avg_household_liquidity /= @floatFromInt(households_slice.len);
            std.debug.print("average household liquidity: {}\n", .{avg_household_liquidity});

        }
        const is_month_end = (self.steps + 1) % self.month_length == 0;
        if (is_month_end) {
            std.debug.print("step {} is the end of a month\n", .{self.steps});
            try self.firms.onMonthEnd(&households_slice, arena);
            self.households.onMonthEnd(&firms_slice);
        }
        try self.firms.onDay(&households_slice, self.labor_supply, arena);
        self.households.onDay(&firms_slice, random);

        // record statistics
        // TODO: use a real data structure instead of logging

        self.steps += 1;
    }
};
