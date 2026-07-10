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
            std.debug.print("step {} is the start of a new month\n", .{self.steps});
            self.firms.onMonthStart(&households_slice, households_order, random);
            self.households.onMonthStart(random, &firms_slice);
        }
        const is_month_end = (self.steps + 1) % self.month_length == 0;
        if (is_month_end) {
            std.debug.print("step {} is the end of a month\n", .{self.steps});
            try self.firms.onMonthEnd(&households_slice, arena);
        }
        try self.firms.onDay(&households_slice, self.labor_supply, arena);

        // record statistics
        // TODO: use a real data structure instead of logging

        self.steps += 1;
    }
};
