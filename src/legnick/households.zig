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
    /// NOTE: not convinced that this needs to be state.
    // current_demand: GoodsAmount,

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

    pub fn onMonthStart(self: *Households, random: Random, firms: *const FirmsSlice) !void {
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

        // TODO:
        // clear the blackmark list
        // look for a job if household wants to
        // plan consumption
    }

    fn findCheaperVendor(
        households: *const Slice,
        household_id: Id,
        firms: *const FirmsSlice,
        random: Random,
        config: *const HouseholdConfig,
    ) void {
        const preferred_suppliers_len = households.items(.preferred_suppliers_len)[household_id];
        const preferred_suppliers = &households.item(.preferred_suppliers)[household_id];

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
        const candidate_price = firms.items(.goods_price)[candidate_id];
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
};
