pub const N_INCOMING_WORKERS = 4;
pub const N_OUTGOING_WORKERS = 4;

// We are currently going for 64kb blocks
pub const BIT_PER_BLOCK = 16;
pub const BLOCK_SIZE = 1 << BIT_PER_BLOCK;
pub const ROUTING_TABLE_SIZE = 4;

pub const Block = []u8;
pub const Guid = u64;
const ID_SIZE = 32;
pub const ID = [ID_SIZE]u8;

const std = @import("std");
pub const allocator = std.heap.page_allocator;

var root_guid: Guid = undefined;

pub var rng: std.rand.DefaultPrng = undefined;

// unique id for message work
pub fn get_guid() Guid {
    const order = @import("builtin").AtomicOrder.Monotonic;
    var val = @atomicRmw(u64, &root_guid, .Add, 1, order);
    return val;
}

pub fn init() void {
    const seed = @import("std").crypto.random.int(u64);
    rng = std.rand.DefaultPrng.init(seed);

    root_guid = rng.random.int(u64);
}
