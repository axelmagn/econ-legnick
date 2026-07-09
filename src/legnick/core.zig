//! shared functions and data types
const std = @import("std");

pub const log = std.log.scoped(.legnick);

/// ID of an entity
pub const Id = usize;

/// amount of money (in cents)
pub const Currency = u64;

/// amount of goods
pub const GoodsAmount = u64;

pub fn withProbability(probability: f32, random: std.Random) bool {
    const x = random.float(f32);
    return x < probability;
}
