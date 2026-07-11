const std = @import("std");
const assert = std.debug.assert;
const Random = std.Random;
const Allocator = std.mem.Allocator;

const core = @import("core.zig");
const Id = core.Id;
const Currency = core.Currency;
const GoodsAmount = core.GoodsAmount;
const log = core.log;

const households = @import("households.zig");
const Households = households.Households;
const HouseholdsSlice = households.Households.Slice;

pub const FirmConfig = struct {
    /// amount of liquidity assigned to each firm at t=0
    initial_liquidity: Currency = 128 * 3000,

    /// price of goods at each firm at t=0
    initial_goods_price: Currency = 3000,

    /// amount of inventory in each firm at t=0
    initial_inventory: GoodsAmount = 0,

    /// initial wage rate at t=0
    initial_wage_rate: Currency = 63 * 3000,

    /// the expected demand for goods per month
    expected_demand: GoodsAmount = 1,

    /// number of months of filled positions before wage will be reduced
    gamma: usize = 24,

    /// upper bound for the wage adjustment
    delta: f32 = 0.019,

    /// range that inventories can be mantained relative to demand
    inventory_uphi: f32 = 1.0,
    inventory_lphi: f32 = 0.25,

    /// range that prices can be marked up over costs
    goods_price_uphi: f32 = 1.15,
    goods_price_lphi: f32 = 1.025,

    /// upper bound for the price adjustment
    upsilon: f32 = 0.02,

    /// probability of changing the goods price
    theta: f32 = 0.75,

    /// productivity multiple by which labor power is turned into labor output
    lambda_val: f32 = 3,

    /// percentage of income to reserve to cover bad times
    chi: f32 = 0.1,
};

pub const Firm = struct {
    /// amount of money the firm possesses
    liquidity: Currency,
    /// the price of each item in the inventory
    goods_price: Currency,
    /// the price the firm will pay for labor power
    wage_rate: Currency,
    /// amount of goods on hand
    inventory: GoodsAmount,
    current_demand: GoodsAmount,
    marginal_cost_deflator: f32,

    worker_on_notice: ?Id = null,
    has_open_position: bool = false,
    months_since_hire_failure: usize = 0,
    // note: list of workers is derived from household employer field

    pub const max_workers = 256;
};

pub const Firms = struct {
    config: FirmConfig = .{},
    data: Table = .empty,

    pub const Table = std.MultiArrayList(Firm);
    pub const Slice = Table.Slice;

    pub fn populate(
        self: *Firms,
        num_firms: usize,
        labor_supply: f32,
        month_length: usize,
        gpa: Allocator,
    ) error{OutOfMemory}!void {
        try self.data.ensureTotalCapacity(gpa, num_firms);
        self.data.len = 0;

        const month_length_f32: f32 = @floatFromInt(month_length);
        for (0..num_firms) |_| {
            const firm: Firm = .{
                .liquidity = self.config.initial_liquidity,
                .goods_price = self.config.initial_goods_price,
                .wage_rate = self.config.initial_wage_rate,
                .inventory = self.config.initial_inventory,
                .current_demand = self.config.expected_demand,
                .marginal_cost_deflator = self.config.lambda_val * labor_supply * month_length_f32,
            };
            assert(self.data.len < self.data.capacity);
            self.data.appendAssumeCapacity(firm);
        }
    }

    pub fn deinit(self: *Firms, gpa: Allocator) void {
        self.data.deinit(gpa);
    }

    pub fn onMonthStart(
        self: *const Firms,
        households_slice: *const HouseholdsSlice,
        households_order: []Id,
        random: Random,
    ) void {
        // TODO: reset monthly stats (once we have monthly stats)
        const slice = self.data.slice();

        // update wages
        for (0..slice.len) |i| {
            setWageRate(&slice, i, random, &self.config);
        }

        // manage workforce
        for (0..slice.len) |i| {
            manageWorkforce(&slice, i, &self.config, households_slice, households_order);
        }

        // update goods price
        for (0..slice.len) |i| {
            if (core.withProbability(self.config.theta, random)) {
                setGoodsPrice(&slice, i, &self.config, random);
            }
        }

        // reset monthly accumulators
        for (0..slice.len) |i| {
            slice.items(.current_demand)[i] = 0;
        }
    }

    pub fn onMonthEnd(
        self: *const Firms,
        households_slice: *const HouseholdsSlice,
        arena: Allocator,
    ) !void {
        const slice = self.data.slice();

        // pay wages
        try payWages(&slice, households_slice, arena);

        // check for hire failures
        for (
            slice.items(.has_open_position),
            slice.items(.months_since_hire_failure),
        ) |has_open_position, *months_since_hire_failure| {
            if (has_open_position) {
                months_since_hire_failure.* = 0;
            } else {
                months_since_hire_failure.* += 1;
            }
        }
    }

    pub fn onDay(
        self: *const Firms,
        households_slice: *const HouseholdsSlice,
        labor_supply: f32,
        arena: Allocator,
    ) !void {
        const slice = self.data.slice();
        try produceOutput(&slice, &self.config, households_slice, labor_supply, arena);
    }

    /// adjust wage rate
    fn setWageRate(
        firms: *const Slice,
        index: usize,
        random: Random,
        config: *const FirmConfig,
    ) void {
        const wage_rate = &firms.items(.wage_rate)[index];
        const has_open_position = &firms.items(.has_open_position)[index];
        const months_since_hire_failure = &firms.items(.months_since_hire_failure)[index];
        if (has_open_position.*) {
            // raise wage
            var wage_rate_f32: f32 = @floatFromInt(wage_rate.*);
            wage_rate_f32 *= 1 + random.floatNorm(f32) * config.delta;
            wage_rate.* = @intFromFloat(std.math.round(wage_rate_f32));
        } else if (months_since_hire_failure.* >= config.gamma) { // should lower wage
            // lower wage
            var wage_rate_f32: f32 = @floatFromInt(wage_rate.*);
            wage_rate_f32 *= 1 - random.floatNorm(f32) * config.delta;
            wage_rate.* = @intFromFloat(std.math.round(wage_rate_f32));
            log.debug("firm {} lowered wages to {}\n", .{ index, wage_rate.* });
        }
    }

    fn manageWorkforce(
        firms: *const Slice,
        firm_id: usize,
        config: *const FirmConfig,
        households_slice: *const HouseholdsSlice,
        households_order: []Id,
    ) void {
        const has_open_position = &firms.items(.has_open_position)[firm_id];
        const worker_on_notice = &firms.items(.worker_on_notice)[firm_id];

        // if inventory is too high, either cancel outstanding notice or offer a new position
        if (inventoryTooLow(firms, firm_id, config)) {
            has_open_position.* = worker_on_notice.* == null;
            worker_on_notice.* = null;
        }

        // if a worker is on notice, fire them
        if (worker_on_notice.* != null) {
            Households.fireWorker(
                households_slice,
                worker_on_notice.*.?,
                firm_id,
            ) catch |err| {
                // errors here indicate state inconsistency
                std.debug.panic("fatal error while firing worker: {}\n", .{err});
            };
            worker_on_notice.* = null;
        }

        // if inventories are too high give notice to a worker and cancel any open position
        if (inventoryTooHigh(firms, firm_id, config)) {
            // find a random employee to put on notice
            for (households_order) |household_id| {
                if (households_slice.items(.employer)[household_id] == firm_id) {
                    worker_on_notice.* = household_id;
                }
            }
            has_open_position.* = false;
        }
    }

    fn inventoryTooLow(
        firms: *const Slice,
        firm_id: usize,
        config: *const FirmConfig,
    ) bool {
        const inventory_floor = inventoryFloor(firms, firm_id, config);
        const inventory = firms.items(.inventory)[firm_id];
        return inventory < inventory_floor;
    }

    fn inventoryTooHigh(
        firms: *const Slice,
        firm_id: usize,
        config: *const FirmConfig,
    ) bool {
        const inventory_ceil = inventoryCeiling(firms, firm_id, config);
        const inventory = firms.items(.inventory)[firm_id];
        return inventory > inventory_ceil;
    }

    fn inventoryFloor(
        firms: *const Slice,
        firm_id: usize,
        config: *const FirmConfig,
    ) GoodsAmount {
        const current_demand: GoodsAmount = firms.items(.current_demand)[firm_id];
        const floor_f32 = config.inventory_lphi * @as(f32, @floatFromInt(current_demand));
        return @intFromFloat(std.math.ceil(floor_f32));
    }

    fn inventoryCeiling(
        firms: *const Slice,
        firm_id: usize,
        config: *const FirmConfig,
    ) GoodsAmount {
        const current_demand: GoodsAmount = firms.items(.current_demand)[firm_id];
        const floor_f32 = config.inventory_uphi * @as(f32, @floatFromInt(current_demand));
        return @intFromFloat(std.math.floor(floor_f32));
    }

    fn setGoodsPrice(
        firms: *const Slice,
        firm_id: Id,
        config: *const FirmConfig,
        random: Random,
    ) void {
        const inventory_too_low = inventoryTooLow(firms, firm_id, config);
        const inventory_too_high = inventoryTooHigh(firms, firm_id, config);
        if (!inventory_too_low and !inventory_too_high) return;

        const price_adjustment = random.float(f32) * config.upsilon;
        const goods_price = &firms.items(.goods_price)[firm_id];
        var goods_price_f32: f32 = @floatFromInt(goods_price.*);
        if (inventory_too_low) {
            // raise prices
            goods_price_f32 *= 1 + price_adjustment;
        } else if (inventory_too_high) {
            // lower prices
            goods_price_f32 *= 1 - price_adjustment;
        }

        const price_floor = goodsPriceFloor(firms, firm_id, config);
        const price_ceil = goodsPriceCeiling(firms, firm_id, config);
        goods_price_f32 = std.math.clamp(
            goods_price_f32,
            @as(f32, @floatFromInt(price_floor)),
            @as(f32, @floatFromInt(price_ceil)),
        );

        goods_price.* = @intFromFloat(goods_price_f32);
    }

    fn goodsPriceFloor(
        firms: *const Slice,
        firm_id: usize,
        config: *const FirmConfig,
    ) GoodsAmount {
        const goods_price: GoodsAmount = firms.items(.goods_price)[firm_id];
        const floor_f32 = config.goods_price_lphi * @as(f32, @floatFromInt(goods_price));
        return @intFromFloat(std.math.ceil(floor_f32));
    }

    fn goodsPriceCeiling(
        firms: *const Slice,
        firm_id: usize,
        config: *const FirmConfig,
    ) GoodsAmount {
        const goods_price: GoodsAmount = firms.items(.goods_price)[firm_id];
        const ceil_f32 = config.goods_price_uphi * @as(f32, @floatFromInt(goods_price));
        return @intFromFloat(std.math.floor(ceil_f32));
    }

    fn payWages(
        firms: *const Slice,
        households_slice: *const HouseholdsSlice,
        arena: Allocator,
    ) error{OutOfMemory}!void {
        // count workers for each firm
        const num_workers_idx = try arena.alloc(usize, firms.len);
        defer arena.free(num_workers_idx);
        for (num_workers_idx) |*num_workers| {
            num_workers.* = 0;
        }
        for (households_slice.items(.employer)) |employer| {
            if (employer == null) continue;
            num_workers_idx[employer.?] += 1;
        }

        // adjust firm wages
        for (0..firms.len) |firm_id| {
            const num_workers = num_workers_idx[firm_id];
            // if liquidity is too low, we can't pay anyone
            const liquidity = &firms.items(.liquidity)[firm_id];
            const wage_rate = &firms.items(.wage_rate)[firm_id];
            if (liquidity.* < num_workers) {
                wage_rate.* = 0;
                return;
            }
            // if we can't pay all of our workers, reduce wages
            if (liquidity.* < num_workers * wage_rate.*) {
                wage_rate.* = @divFloor(liquidity.*, num_workers);
            }

            // go ahead and decrement liquidity while we're in here
            const firm_wages = wage_rate.* * num_workers;
            assert(liquidity.* >= firm_wages);
            liquidity.* -= firm_wages;
        }

        // pay out wages
        for (
            households_slice.items(.employer),
            households_slice.items(.liquidity),
        ) |employer, *liquidity| {
            if (employer == null) continue;
            const wage_rate = firms.items(.wage_rate)[employer.?];
            liquidity.* += wage_rate;
        }
    }

    fn produceOutput(
        firms: *const Slice,
        config: *const FirmConfig,
        households_slice: *const HouseholdsSlice,
        labor_supply: f32,
        arena: Allocator,
    ) !void {
        // sum labor power for each firm
        const firm_labor_power = try arena.alloc(f32, firms.len);
        defer arena.free(firm_labor_power);

        for (firm_labor_power) |*labor_power_item| {
            labor_power_item.* = 0;
        }
        for (households_slice.items(.employer)) |employer| {
            if (employer == null) continue;
            firm_labor_power[employer.?] += labor_supply;
        }

        // add inventory for each firm
        for (0..firms.len, firms.items(.inventory)) |firm_id, *inventory| {
            const production_amount = firm_labor_power[firm_id] * config.lambda_val;
            inventory.* += @intFromFloat(production_amount);
        }
    }
};
