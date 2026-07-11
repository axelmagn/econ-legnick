const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Random = std.Random;

const core = @import("core.zig");
const Id = core.Id;
const Currency = core.Currency;
const GoodsAmount = core.GoodsAmount;

// const firms = @import("firms.zig");
const FirmsSlice = @import("firms.zig").Firms.Slice;

/// calibration settings for the household agent
pub const HouseholdConfig = struct {
    /// reservation wage assigned to each household at t=0
    initial_reservation_wage: Currency = 0,

    /// amount of liquidity assigned to each household at t=0
    initial_liquidity: Currency = 0,

    /// unemployed reservation wage decay rate
    wage_decay_rate: f32 = 0.9,

    /// Fraction of demand supplied that will satisfy the household desire
    satisfaction_fraction: f32 = 0.95,

    /// fraction a new firms price has to be less than the old firm before the
    /// new firm will be picked
    zeta: f32 = 0.01,

    /// number of firms to search for work if unemployed
    beta: usize = 5,

    /// probability of searching for new work, if employed
    pi: f32 = 0.1,

    /// decay rate for consumption expenditure function
    /// in the range 0 < alpha < 1
    alpha: f32 = 0.9,

    /// number of firms in the preferred suppliers list
    num_preferred_suppliers: usize = 7,

    /// probability of looking for firm with cheaper prices
    psi_price: f32 = 0.25,

    /// probability of replacing a firm that fails to supply
    psi_quant: f32 = 0.25,
};

pub const Household = struct {
    /// entity ID
    /// NOTE: not sure we need this
    // id: Id,

    /// the firm the household is working for, if employed
    employer: ?Id = null,
    /// minimal claim on labor income
    reservation_wage: Currency,
    /// amount of money household possesses
    liquidity: Currency,
    /// how many goods to buy each day
    current_demand: GoodsAmount = 0,

    /// number of firms household prefers to buy from
    preferred_suppliers_len: usize = 0,
    /// list of firms household prefers to buy from
    preferred_suppliers: [max_firms]Id = undefined,

    /// number of firms that have failed to supply this month
    blackmarked_firms_len: usize = 0,
    /// list of firms that have failed to supply this month
    blackmarked_firms: [max_firms]Id = undefined,
    blackmarked_firms_weights: [max_firms]f32 = undefined,

    pub const max_firms = 8;

    fn add_sampled_firm(
        firms_len: *usize,
        firms_buf: []Id,
        num_global_firms: usize,
        rand: std.Random,
    ) error{ OutOfMemory, OutOfFirms }!void {
        if (firms_buf.len <= firms_len.*) return error.OutOfMemory;
        if (num_global_firms <= firms_len.* + 1) return error.OutOfFirms;

        var firm_id = rand.intRangeLessThan(usize, 0, num_global_firms);

        for (0..(firms_len.* + 1)) |_| {
            add_firm(firms_len, firms_buf, firm_id) catch |err| {
                switch (err) {
                    error.AlreadyPresent => {
                        // if the firm is already present, try the next firm sequentially
                        firm_id += 1;
                        firm_id %= num_global_firms;
                        continue;
                    },
                    error.OutOfMemory => |oom| return oom,
                }
            };
            return;
        }
        unreachable; // by the pidgeonholing principle, N+1 options and N holes
    }

    fn add_firm(
        firms_len: *usize,
        firms_buf: []Id,
        firm_id: Id,
    ) error{ OutOfMemory, AlreadyPresent }!void {
        if (firms_buf.len <= firms_len.*) return error.OutOfMemory;
        for (firms_buf[0..firms_len.*]) |id| {
            if (firm_id == id) {
                return error.AlreadyPresent;
            }
        }
        firms_buf[firms_len.*] = firm_id;
        firms_len.* += 1;
    }
};

pub const Households = struct {
    config: HouseholdConfig = .{},
    data: Table = .empty,

    pub const Table = std.MultiArrayList(Household);
    pub const Slice = Table.Slice;

    pub fn populate(
        self: *Households,
        num_households: usize,
        num_firms: usize,
        gpa: Allocator,
        rand: std.Random,
    ) error{ OutOfMemory, OutOfFirms }!void {
        try self.data.ensureTotalCapacity(gpa, num_households);
        self.data.len = 0;
        for (0..num_households) |_| {
            var household: Household = .{
                // .id = i,
                .reservation_wage = self.config.initial_reservation_wage,
                .liquidity = self.config.initial_liquidity,
            };
            // sample preferred suppliers
            for (0..self.config.num_preferred_suppliers) |_| {
                try Household.add_sampled_firm(
                    &household.preferred_suppliers_len,
                    &household.preferred_suppliers,
                    num_firms,
                    rand,
                );
            }
            assert(self.data.len < self.data.capacity);
            self.data.appendAssumeCapacity(household);
        }
    }

    pub fn deinit(self: *Households, gpa: Allocator) void {
        self.data.deinit(gpa);
    }

    pub fn onMonthStart(
        self: *Households,
        random: Random,
        firms: *const FirmsSlice,
        month_length: usize,
    ) void {
        const slice = self.data.slice();

        // find cheaper vendor
        for (0..slice.len) |household_id| {
            if (core.withProbability(self.config.psi_price, random)) {
                findCheaperVendor(&slice, household_id, firms, random, &self.config);
            }
        }

        // dump a failed vendor
        for (0..slice.len) |household_id| {
            if (core.withProbability(self.config.psi_quant, random)) {
                findBetterVendor(&slice, household_id, firms, random);
            }
        }

        // clear the blackmark list
        for (
            slice.items(.blackmarked_firms_len),
            slice.items(.blackmarked_firms_weights),
        ) |*blackmarked_firms_len, *blackmarked_firms_weights| {
            for (0..blackmarked_firms_len.*) |i| {
                blackmarked_firms_weights[i] = 0;
            }
            blackmarked_firms_len.* = 0;
        }

        // look for a job if household wants to
        for (0..slice.len) |household_id| {
            if (isUnhappyAtWork(&slice, household_id, firms, &self.config, random)) {
                lookForNewJob(&slice, household_id, firms, &self.config, random);
            }
        }
        // plan consumption
        for (0..slice.len) |household_id| {
            planConsumption(&slice, household_id, &self.config, firms, month_length);
        }
    }

    pub fn onMonthEnd(
        self: *const Households,
        firms: *const FirmsSlice,
    ) void {
        const slice = self.data.slice();
        for (0..slice.len) |household_id| {
            adjustReservationWage(&slice, household_id, &self.config, firms);
        }
    }

    pub fn onDay(
        self: *const Households,
        firms: *const FirmsSlice,
        random: Random,
    ) void {
        const slice = self.data.slice();
        for (0..slice.len) |household_id| {
            buyGoods(&slice, household_id, &self.config, firms, random);
        }
    }

    pub fn fireWorker(
        households: *const Slice,
        index: usize,
        employer_index: usize,
    ) error{ AlreadyUnemployed, EmployerMismatch }!void {
        const employer = &households.items(.employer)[index];
        if (employer.* == null) return error.AlreadyUnemployed;
        if (employer.*.? != employer_index) return error.EmployerMismatch;
        employer.* = null;
    }

    fn findCheaperVendor(
        households: *const Slice,
        household_id: Id,
        firms: *const FirmsSlice,
        random: Random,
        config: *const HouseholdConfig,
    ) void {
        const preferred_suppliers_len = households.items(.preferred_suppliers_len)[household_id];
        const preferred_suppliers = &households.items(.preferred_suppliers)[household_id];

        // pick a random existing supplier and calculate the price to beat
        const existing_supplier_idx = random.intRangeLessThan(Id, 0, preferred_suppliers_len);
        const existing_supplier_id = preferred_suppliers[existing_supplier_idx];
        const existing_price = firms.items(.goods_price)[existing_supplier_id];
        const price_to_beat: f32 = @as(f32, @floatFromInt(existing_price)) * (1 - config.zeta);

        // pick another random firm and switch if the price is right
        var candidate_id = random.intRangeLessThan(Id, 0, firms.len);
        while (true) {
            var is_in_preferred = false;
            for (0..preferred_suppliers_len) |i| {
                if (preferred_suppliers[i] == candidate_id) {
                    is_in_preferred = true;
                    break;
                }
            }
            if (!is_in_preferred) break;
            candidate_id = random.intRangeLessThan(Id, 0, firms.len);
        }
        const candidate_price: f32 = @floatFromInt(firms.items(.goods_price)[candidate_id]);
        if (candidate_price < price_to_beat) {
            preferred_suppliers[existing_supplier_idx] = candidate_id;
        }
    }

    fn findBetterVendor(
        households: *const Slice,
        household_id: Id,
        firms: *const FirmsSlice,
        random: Random,
    ) void {
        const blackmarked_firms_len = households.items(.blackmarked_firms_len)[household_id];
        if (blackmarked_firms_len == 0) return;
        const blackmarked_firms = &households.items(.blackmarked_firms)[household_id];
        const blackmarked_firms_weights = &households.items(.blackmarked_firms_weights)[household_id];

        // select a random blackmarked firm
        const blackmarked_firm_idx = random.weightedIndex(f32, blackmarked_firms_weights[0..blackmarked_firms_len]);
        const blackmarked_firm_id = blackmarked_firms[blackmarked_firm_idx];

        // replace with a random new firm
        const preferred_suppliers_len = households.items(.preferred_suppliers_len)[household_id];
        const preferred_suppliers = &households.items(.preferred_suppliers)[household_id];
        var candidate_id = random.intRangeLessThan(Id, 0, firms.len);
        while (true) {
            var is_in_preferred = false;
            for (0..preferred_suppliers_len) |i| {
                if (preferred_suppliers[i] == candidate_id) {
                    is_in_preferred = true;
                    break;
                }
            }
            if (!is_in_preferred) break;
            candidate_id = random.intRangeLessThan(Id, 0, firms.len);
        }
        for (0..preferred_suppliers_len) |i| {
            if (preferred_suppliers[i] == blackmarked_firm_id) {
                preferred_suppliers[i] = candidate_id;
                break;
            }
        }
    }

    fn isUnhappyAtWork(
        households: *const Slice,
        household_id: Id,
        firms: *const FirmsSlice,
        config: *const HouseholdConfig,
        random: Random,
    ) bool {
        // unemployed
        const employer = households.items(.employer)[household_id];
        if (employer == null) return true;

        // not paid enough
        const wage = firms.items(.wage_rate)[employer.?];
        const reservation_wage = households.items(.reservation_wage)[household_id];
        if (wage < reservation_wage) return true;

        // just feel like it
        return core.withProbability(config.pi, random);
    }

    fn lookForNewJob(
        households: *const Slice,
        household_id: Id,
        firms: *const FirmsSlice,
        config: *const HouseholdConfig,
        random: Random,
    ) void {
        const employer = &households.items(.employer)[household_id];
        const num_searches = if (employer.* == null) config.beta else 1;
        for (0..num_searches) |_| {
            var potential_employer = random.intRangeLessThan(usize, 0, firms.len);
            while (employer.* != null and potential_employer == employer.*) {
                potential_employer = random.intRangeLessThan(usize, 0, firms.len);
            }
            if (isAcceptableJobOffer(households, household_id, firms, potential_employer)) {
                employer.* = potential_employer;
                firms.items(.has_open_position)[potential_employer] = false;
            }
        }
    }

    fn isAcceptableJobOffer(
        households: *const Slice,
        household_id: Id,
        firms: *const FirmsSlice,
        potential_employer: Id,
    ) bool {
        if (!firms.items(.has_open_position)[potential_employer]) return false;

        const reservation_wage = households.items(.reservation_wage)[household_id];
        const potential_wage = firms.items(.wage_rate)[potential_employer];
        if (potential_wage > reservation_wage) return true;

        const current_employer = households.items(.employer)[household_id];
        if (current_employer == null) return false;

        const current_wage = firms.items(.wage_rate)[current_employer.?];
        if (potential_wage < current_wage) return true;

        return false;
    }

    fn planConsumption(
        households: *const Slice,
        household_id: Id,
        config: *const HouseholdConfig,
        firms: *const FirmsSlice,
        month_length: usize,
    ) void {
        const current_demand = &households.items(.current_demand)[household_id];
        const preferred_suppliers_len = households.items(.preferred_suppliers_len)[household_id];
        if (preferred_suppliers_len == 0) {
            current_demand.* = std.math.maxInt(GoodsAmount);
            return;
        }

        // calculate average goods price
        var average_goods_price: f32 = 0;
        const preferred_suppliers = &households.items(.preferred_suppliers)[household_id];
        for (0..preferred_suppliers_len) |i| {
            const supplier = preferred_suppliers[i];
            const goods_price = firms.items(.goods_price)[supplier];
            average_goods_price += @floatFromInt(goods_price);
        }
        const preferred_suppliers_len_f32: f32 = @floatFromInt(preferred_suppliers_len);
        average_goods_price = @divExact(average_goods_price, preferred_suppliers_len_f32);

        const liquidity: f32 = @floatFromInt(households.items(.liquidity)[household_id]);
        const planned_consumption_f32 = std.math.pow(
            f32,
            @divExact(liquidity, average_goods_price),
            config.alpha,
        );
        const planned_consumption: GoodsAmount = @intFromFloat(planned_consumption_f32);
        current_demand.* = @divTrunc(planned_consumption, month_length);
    }

    fn adjustReservationWage(
        households: *const Slice,
        household_id: Id,
        config: *const HouseholdConfig,
        firms: *const FirmsSlice,
    ) void {
        const employer = households.items(.employer)[household_id];
        const reservation_wage = &households.items(.reservation_wage)[household_id];
        // if unemployed, reserve wage decays
        if (employer == null) {
            const reservation_wage_f32: f32 = @floatFromInt(reservation_wage.*);
            reservation_wage.* = @intFromFloat(reservation_wage_f32 * config.wage_decay_rate);
        } else {
            const employer_wage = firms.items(.wage_rate)[employer.?];
            reservation_wage.* = if (employer_wage > reservation_wage.*) employer_wage else reservation_wage.*;
        }
    }

    fn buyGoods(
        households: *const Slice,
        household_id: Id,
        config: *const HouseholdConfig,
        firms: *const FirmsSlice,
        random: Random,
    ) void {
        // put the preferred suppliers in a random order
        const preferred_suppliers_len = households.items(.preferred_suppliers_len)[household_id];
        const preferred_suppliers = &households.items(.preferred_suppliers)[household_id];
        random.shuffle(Id, preferred_suppliers[0..preferred_suppliers_len]);

        // obtain the required amount of goods
        var required_amount = households.items(.current_demand)[household_id];
        const liquidity = &households.items(.liquidity)[household_id];
        var required_amount_f32: f32 = @floatFromInt(required_amount);
        const satisfaction_amount = std.math.floor(required_amount_f32 * (1 - config.satisfaction_fraction));
        for (preferred_suppliers[0..preferred_suppliers_len]) |vendor_id| {
            const available_amount = firms.items(.inventory)[vendor_id];
            var affordable_amount: GoodsAmount = std.math.maxInt(GoodsAmount);
            const goods_price = firms.items(.goods_price)[vendor_id];
            if (goods_price > 0) {
                affordable_amount = @divTrunc(liquidity.*, goods_price);
            }

            // blackmark firm if it cannot supply full amount
            if (available_amount < required_amount and available_amount < affordable_amount) {
                // find or append blackmarked firm
                var already_exists = false;
                const weight: f32 = @floatFromInt(required_amount - available_amount);
                const blackmarked_firms_len = &households.items(.blackmarked_firms_len)[household_id];
                for (0..blackmarked_firms_len.*) |i| {
                    if (vendor_id == households.items(.blackmarked_firms)[household_id][i]) {
                        already_exists = true;
                        households.items(.blackmarked_firms_weights)[household_id][i] += weight;
                    }
                }
                if (!already_exists) {
                    households.items(.blackmarked_firms)[household_id][blackmarked_firms_len.*] = vendor_id;
                    households.items(.blackmarked_firms_weights)[household_id][blackmarked_firms_len.*] = weight;
                    blackmarked_firms_len.* += 1;
                }
            }

            var transaction_amount = required_amount;
            if (available_amount < transaction_amount) transaction_amount = available_amount;
            if (affordable_amount < transaction_amount) transaction_amount = affordable_amount;

            // transact
            const total_price = transaction_amount * goods_price;
            std.debug.assert(firms.items(.inventory)[vendor_id] >= transaction_amount);
            firms.items(.inventory)[vendor_id] -= transaction_amount;
            firms.items(.liquidity)[vendor_id] += total_price;
            std.debug.assert(liquidity.* >= total_price);
            liquidity.* -= total_price;

            required_amount -= transaction_amount;
            required_amount_f32 = @floatFromInt(required_amount);
            if (required_amount_f32 <= satisfaction_amount) return;
        }

        // TODO: record unsatisfied demand
    }
};
