const std = @import("std");
const builtin = @import("builtin");

pub const cache_line = 128;

const Waiter = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    parked_count: u32 align(cache_line) = 0,

    fn notifyOne(self: *Waiter) void {
        if (@atomicLoad(u32, &self.parked_count, .monotonic) != 0) {
            @branchHint(.cold);
            self.cond.signal();
        }
    }

    fn broadcast(self: *Waiter) void {
        if (@atomicLoad(u32, &self.parked_count, .monotonic) != 0) {
            @branchHint(.cold);
            self.cond.broadcast();
        }
    }
};

// MPMC Ring Buffer - Sequence-per-slot design (LMAX Disruptor style)
//
// Each slot has its own sequence number that acts as both a lock and a version.
// Producers and consumers coordinate by comparing head/tail cursors against
// slot sequences. This avoids a central lock and allows true parallelism.
//
// Memory layout uses 128-byte alignment to prevent false sharing on modern CPUs.
// Head and tail cursors are on separate cache lines, and each slot's sequence
// is also cache-line aligned.
//
// Invariants:
//   - slot.sequence == head means slot is writable (empty)
//   - slot.sequence == tail + 1 means slot is readable (has data)
//   - head - tail <= capacity (buffer never overflows)
//
// The sequence numbers wrap around using wrapping arithmetic (+%), which is
// safe because we only compare for equality, not ordering.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const Slot = struct {
            sequence: u64 align(cache_line) = 0,
            value: T = undefined,
        };

        slots: []Slot,
        mask: u64,
        head: u64 align(cache_line) = 0,
        tail: u64 align(cache_line) = 0,
        epoch: u64 align(cache_line) = 0,
        shutdown: bool align(cache_line) = false,
        waiter: Waiter align(cache_line) = .{},
        allocator: std.mem.Allocator,

        produced: if (builtin.mode == .Debug) std.atomic.Value(u64) else void =
            if (builtin.mode == .Debug) std.atomic.Value(u64).init(0) else {},
        consumed: if (builtin.mode == .Debug) std.atomic.Value(u64) else void =
            if (builtin.mode == .Debug) std.atomic.Value(u64).init(0) else {},

        // Initialize the ring buffer with the given capacity.
        // Size must be a power of two - this allows us to use bitwise AND for
        // fast modulo (index & mask instead of index % size). Slots are initialized
        // with sequence = index, marking them all as "empty and ready for writing".
        pub fn init(allocator: std.mem.Allocator, size: u32) !Self {
            std.debug.assert(size > 0 and (size & (size - 1)) == 0);

            const slots = try allocator.alloc(Slot, size);
            for (slots, 0..) |*slot, i| {
                slot.sequence = i;
                slot.value = undefined;
            }

            return .{
                .slots = slots,
                .mask = size - 1,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        // Produce a value into the ring buffer (blocking).
        //
        // Algorithm:
        //   1. Load current head position (where we want to write)
        //   2. Check if slot.sequence == head (slot is empty and ready)
        //   3. CAS head to head+1 to claim the slot
        //   4. Write value, then set slot.sequence = head+1 to publish
        //
        // Memory ordering:
        //   - Load head with monotonic (just need current value)
        //   - Load sequence with acquire (sync with consumer's release)
        //   - Store sequence with release (publish data to consumers)
        //
        // Backoff strategy:
        //   - On CAS failure: immediately retry (contention, slot likely still valid)
        //   - On sequence mismatch: spin with hints, yield after 256 spins
        //   - Never blocks - will eventually succeed as consumers drain the buffer
        pub fn produce(self: *Self, value: T) void {
            var spin_count: u8 = 0;
            while (!@atomicLoad(bool, &self.shutdown, .acquire)) {
                const head = @atomicLoad(u64, &self.head, .monotonic);
                const slot = &self.slots[head & self.mask];
                const seq = @atomicLoad(u64, &slot.sequence, .acquire);

                if (seq == head) {
                    @branchHint(.likely);
                    if (@cmpxchgWeak(u64, &self.head, head, head +% 1, .monotonic, .monotonic) == null) {
                        @branchHint(.likely);
                        slot.value = value;
                        @atomicStore(u64, &slot.sequence, head +% 1, .release);
                        _ = @atomicRmw(u64, &self.epoch, .Add, 1, .release);
                        if (builtin.mode == .Debug) _ = self.produced.fetchAdd(1, .monotonic);
                        self.waiter.notifyOne();
                        return;
                    }
                    continue;
                }

                std.atomic.spinLoopHint();
                spin_count +%= 1;
                if (spin_count == 0) {
                    @branchHint(.cold);
                    std.Thread.yield() catch {};
                }
            }
        }

        pub fn close(self: *Self) void {
            @atomicStore(bool, &self.shutdown, true, .release);
            _ = @atomicRmw(u64, &self.epoch, .Add, 1, .release);
            self.waiter.broadcast();
        }

        // Try to consume a value (non-blocking).
        // Returns null immediately if buffer is empty or on contention.
        //
        // Algorithm:
        //   1. Load current tail position (where we want to read)
        //   2. Check if slot.sequence == tail+1 (slot has data ready)
        //   3. CAS tail to tail+1 to claim the slot
        //   4. Read value, then set slot.sequence = tail+mask+1 to free slot
        //
        // The final sequence value (tail + mask + 1) is carefully chosen:
        // it equals the head value that will next want to write to this slot,
        // effectively marking it as empty for the next producer cycle.
        pub fn tryConsume(self: *Self) ?T {
            const tail = @atomicLoad(u64, &self.tail, .monotonic);
            const slot = &self.slots[tail & self.mask];
            const seq = @atomicLoad(u64, &slot.sequence, .acquire);
            const expected = tail +% 1;

            if (seq == expected) {
                @branchHint(.likely);
                if (@cmpxchgWeak(u64, &self.tail, tail, expected, .monotonic, .monotonic) == null) {
                    @branchHint(.likely);
                    const value = slot.value;
                    @atomicStore(u64, &slot.sequence, tail +% self.mask +% 1, .release);
                    if (builtin.mode == .Debug) _ = self.consumed.fetchAdd(1, .monotonic);
                    return value;
                }
            }
            return null;
        }

        pub fn consume(self: *Self) ?T {
            if (self.tryConsume()) |v| {
                @branchHint(.likely);
                return v;
            }

            var spin_count: u8 = 0;
            while (spin_count < 16) : (spin_count += 1) {
                if (self.tryConsume()) |v| return v;
                if (@atomicLoad(bool, &self.shutdown, .acquire)) {
                    @branchHint(.cold);
                    return self.tryConsume();
                }
                std.atomic.spinLoopHint();
            }

            while (!@atomicLoad(bool, &self.shutdown, .acquire)) {
                self.park();
                if (self.tryConsume()) |v| return v;
            }
            return self.tryConsume();
        }

        // Epoch-based parking: prevents lost wakeups by checking if epoch changed
        // since we decided to sleep. Even if signal is "lost", epoch changed so
        // we won't actually sleep (or will immediately re-check).
        fn park(self: *Self) void {
            const e0 = @atomicLoad(u64, &self.epoch, .acquire);

            self.waiter.mutex.lock();
            defer self.waiter.mutex.unlock();

            _ = @atomicRmw(u32, &self.waiter.parked_count, .Add, 1, .monotonic);
            defer _ = @atomicRmw(u32, &self.waiter.parked_count, .Sub, 1, .monotonic);

            while (true) {
                if (@atomicLoad(bool, &self.shutdown, .acquire)) return;
                if (self.peekReadable()) return;
                if (@atomicLoad(u64, &self.epoch, .acquire) != e0) return;
                self.waiter.cond.wait(&self.waiter.mutex);
            }
        }

        fn peekReadable(self: *Self) bool {
            const tail = @atomicLoad(u64, &self.tail, .monotonic);
            const slot = &self.slots[tail & self.mask];
            const seq = @atomicLoad(u64, &slot.sequence, .acquire);
            return seq == tail +% 1;
        }

        pub fn checkInvariants(self: *Self) void {
            if (builtin.mode != .Debug) return;
            const head = @atomicLoad(u64, &self.head, .acquire);
            const tail = @atomicLoad(u64, &self.tail, .acquire);
            std.debug.assert(head -% tail <= self.mask + 1);
            std.debug.assert(self.produced.load(.acquire) == head);
            std.debug.assert(self.consumed.load(.acquire) == tail);
        }
    };
}

// Tests

const TestValue = struct {
    producer_id: u32,
    seq: u32,
    fn encode(producer_id: u32, seq: u32) u64 {
        return (@as(u64, producer_id) << 32) | seq;
    }
    fn decode(val: u64) TestValue {
        return .{ .producer_id = @intCast(val >> 32), .seq = @intCast(val & 0xFFFFFFFF) };
    }
};

const TestRing = RingBuffer(u64);

test "single producer single consumer" {
    const allocator = std.testing.allocator;
    var ring = try TestRing.init(allocator, 16);
    defer ring.deinit();

    const n = 1000;

    // Producer thread
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(r: *TestRing) void {
            for (0..n) |i| {
                r.produce(TestValue.encode(0, @intCast(i)));
            }
        }
    }.run, .{&ring});

    // Consumer in main thread
    var received: [n]bool = [_]bool{false} ** n;
    var count: usize = 0;

    while (count < n) {
        if (ring.tryConsume()) |val| {
            const tv = TestValue.decode(val);
            try std.testing.expect(tv.producer_id == 0);
            try std.testing.expect(tv.seq < n);
            try std.testing.expect(!received[tv.seq]); // No duplicates
            received[tv.seq] = true;
            count += 1;
        }
    }

    producer.join();

    // All items received
    for (received) |r| {
        try std.testing.expect(r);
    }
}

test "multiple producers single consumer" {
    const allocator = std.testing.allocator;
    var ring = try TestRing.init(allocator, 64);
    defer ring.deinit();

    const num_producers = 4;
    const items_per_producer = 500;
    const total = num_producers * items_per_producer;

    var producers: [num_producers]std.Thread = undefined;

    for (0..num_producers) |p| {
        producers[p] = try std.Thread.spawn(.{}, struct {
            fn run(r: *TestRing, pid: u32) void {
                for (0..items_per_producer) |i| {
                    r.produce(TestValue.encode(pid, @intCast(i)));
                }
            }
        }.run, .{ &ring, @as(u32, @intCast(p)) });
    }

    // Track what we received per producer
    var received: [num_producers][items_per_producer]bool =
        [_][items_per_producer]bool{[_]bool{false} ** items_per_producer} ** num_producers;
    var count: usize = 0;

    while (count < total) {
        if (ring.tryConsume()) |val| {
            const tv = TestValue.decode(val);
            try std.testing.expect(tv.producer_id < num_producers);
            try std.testing.expect(tv.seq < items_per_producer);
            try std.testing.expect(!received[tv.producer_id][tv.seq]); // No duplicates
            received[tv.producer_id][tv.seq] = true;
            count += 1;
        }
    }

    for (&producers) |*p| p.join();

    // Verify all received
    for (received) |producer_items| {
        for (producer_items) |r| {
            try std.testing.expect(r);
        }
    }
}

test "multiple producers multiple consumers" {
    const allocator = std.testing.allocator;
    var ring = try TestRing.init(allocator, 128);
    defer ring.deinit();

    const num_producers = 4;
    const num_consumers = 4;
    const items_per_producer = 1000;
    const total = num_producers * items_per_producer;

    // Track consumed items (thread-safe)
    const consumed_flags = try allocator.alloc(std.atomic.Value(bool), total);
    defer allocator.free(consumed_flags);
    for (consumed_flags) |*f| f.* = std.atomic.Value(bool).init(false);

    var consumed_count = std.atomic.Value(usize).init(0);

    var producers: [num_producers]std.Thread = undefined;
    var consumers: [num_consumers]std.Thread = undefined;

    // Start producers
    for (0..num_producers) |p| {
        producers[p] = try std.Thread.spawn(.{}, struct {
            fn run(r: *TestRing, pid: u32) void {
                for (0..items_per_producer) |i| {
                    // Encode unique ID: producer_id * items_per_producer + seq
                    const unique_id = pid * items_per_producer + @as(u32, @intCast(i));
                    r.produce(unique_id);
                }
            }
        }.run, .{ &ring, @as(u32, @intCast(p)) });
    }

    // Start consumers
    for (0..num_consumers) |c| {
        consumers[c] = try std.Thread.spawn(.{}, struct {
            fn run(
                r: *TestRing,
                flags: []std.atomic.Value(bool),
                count: *std.atomic.Value(usize),
                total_items: usize,
            ) void {
                while (count.load(.monotonic) < total_items) {
                    if (r.tryConsume()) |val| {
                        const idx = @as(usize, @intCast(val));

                        // Must not have been consumed before
                        const was_set = flags[idx].swap(true, .acq_rel);
                        if (was_set) {
                            std.debug.panic("DUPLICATE: item {} consumed twice!", .{idx});
                        }

                        _ = count.fetchAdd(1, .monotonic);
                    }
                }
            }
        }.run, .{ &ring, consumed_flags, &consumed_count, total });
    }

    // Wait for all
    for (&producers) |*p| p.join();
    ring.close();
    for (&consumers) |*c| c.join();

    // Verify all consumed exactly once
    for (consumed_flags, 0..) |f, i| {
        if (!f.load(.acquire)) {
            std.debug.panic("MISSING: item {} was never consumed!", .{i});
        }
    }

    try std.testing.expectEqual(total, consumed_count.load(.acquire));
}

// Fuzz tests

test "fuzz mpmc correctness" {
    const base_seed = @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));

    // Run 10 iterations with different seeds (use more for stress testing)
    // Stress test: zig build test -Doptimize=ReleaseFast 2>&1 | grep -c "Fuzz:"
    const iterations = 10;
    for (0..iterations) |i| {
        try fuzzTest(std.testing.allocator, base_seed +% i);
    }
}

test "fuzz with zig fuzzer" {
    // Run with: zig build test --fuzz
    try std.testing.fuzz(.{}, fuzzInput, .{ .corpus = &.{} });
}

fn fuzzInput(_: @TypeOf(.{}), input: []const u8) !void {
    if (input.len < 4) return;

    // Parse fuzz input into test parameters
    const ring_size_exp = @as(u5, @intCast((input[0] % 7) + 4)); // 4-10 -> 16 to 1024
    const ring_size: u32 = @as(u32, 1) << ring_size_exp;
    const num_producers: u8 = (input[1] % 8) + 1; // 1-8
    const num_consumers: u8 = (input[2] % 8) + 1; // 1-8
    const items_per_producer: u32 = (@as(u32, input[3]) * 20) + 10; // 10-5110

    try fuzzTestWithParams(std.testing.allocator, ring_size, num_producers, num_consumers, items_per_producer);
}

fn fuzzTestWithParams(
    allocator: std.mem.Allocator,
    ring_size: u32,
    num_producers: u8,
    num_consumers: u8,
    items_per_producer: u32,
) !void {
    const total: usize = @as(usize, num_producers) * items_per_producer;

    var ring = try TestRing.init(allocator, ring_size);
    defer ring.deinit();

    const consumed_flags = try allocator.alloc(std.atomic.Value(bool), total);
    defer allocator.free(consumed_flags);
    for (consumed_flags) |*f| f.* = std.atomic.Value(bool).init(false);

    var consumed_count = std.atomic.Value(usize).init(0);
    var error_flag = std.atomic.Value(bool).init(false);

    const producers = try allocator.alloc(std.Thread, num_producers);
    defer allocator.free(producers);
    const consumers = try allocator.alloc(std.Thread, num_consumers);
    defer allocator.free(consumers);

    // Start producers
    for (0..num_producers) |p| {
        producers[p] = try std.Thread.spawn(.{}, struct {
            fn run(r: *TestRing, pid: usize, count: u32, ipp: u32) void {
                for (0..count) |i| {
                    r.produce(@as(u64, pid) * ipp + @as(u64, @intCast(i)));
                }
            }
        }.run, .{ &ring, p, items_per_producer, items_per_producer });
    }

    // Start consumers
    for (0..num_consumers) |c| {
        consumers[c] = try std.Thread.spawn(.{}, struct {
            fn run(
                r: *TestRing,
                flags: []std.atomic.Value(bool),
                count: *std.atomic.Value(usize),
                total_items: usize,
                err: *std.atomic.Value(bool),
            ) void {
                while (count.load(.monotonic) < total_items and !err.load(.monotonic)) {
                    if (r.tryConsume()) |val| {
                        const idx = @as(usize, @intCast(val));
                        if (idx >= flags.len) {
                            err.store(true, .release);
                            return;
                        }
                        if (flags[idx].swap(true, .acq_rel)) {
                            err.store(true, .release);
                            return;
                        }
                        _ = count.fetchAdd(1, .monotonic);
                    }
                }
            }
        }.run, .{ &ring, consumed_flags, &consumed_count, total, &error_flag });
    }

    for (producers) |p| p.join();
    ring.close();
    for (consumers) |c| c.join();

    // Check for errors
    if (error_flag.load(.acquire)) return error.FuzzError;

    // Verify all consumed
    for (consumed_flags) |f| {
        if (!f.load(.acquire)) return error.FuzzError;
    }

    if (consumed_count.load(.acquire) != total) return error.FuzzError;
}

fn fuzzTest(allocator: std.mem.Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    // Random parameters
    const ring_size: u32 = @as(u32, 1) << @intCast(random.intRangeAtMost(u4, 4, 10)); // 16 to 1024
    const num_producers = random.intRangeAtMost(u8, 1, 8);
    const num_consumers = random.intRangeAtMost(u8, 1, 8);
    const items_per_producer = random.intRangeAtMost(u32, 100, 5000);
    const total: usize = @as(usize, num_producers) * items_per_producer;

    std.debug.print(
        "\nFuzz: ring_size={}, {}P/{}C, {} items each, {} total\n",
        .{ ring_size, num_producers, num_consumers, items_per_producer, total },
    );

    var ring = try TestRing.init(allocator, ring_size);
    defer ring.deinit();

    const consumed_flags = try allocator.alloc(std.atomic.Value(bool), total);
    defer allocator.free(consumed_flags);
    for (consumed_flags) |*f| f.* = std.atomic.Value(bool).init(false);

    var consumed_count = std.atomic.Value(usize).init(0);
    var error_flag = std.atomic.Value(bool).init(false);

    var producers = try allocator.alloc(std.Thread, num_producers);
    defer allocator.free(producers);
    var consumers = try allocator.alloc(std.Thread, num_consumers);
    defer allocator.free(consumers);

    // Start producers
    for (0..num_producers) |p| {
        producers[p] = try std.Thread.spawn(.{}, struct {
            fn run(r: *TestRing, pid: usize, count: u32, ipp: u32) void {
                for (0..count) |i| {
                    const unique_id = @as(u64, pid) * ipp + @as(u64, @intCast(i));
                    r.produce(unique_id);
                }
            }
        }.run, .{ &ring, p, items_per_producer, items_per_producer });
    }

    // Start consumers
    for (0..num_consumers) |c| {
        consumers[c] = try std.Thread.spawn(.{}, struct {
            fn run(
                r: *TestRing,
                flags: []std.atomic.Value(bool),
                count: *std.atomic.Value(usize),
                total_items: usize,
                err: *std.atomic.Value(bool),
            ) void {
                while (count.load(.monotonic) < total_items and !err.load(.monotonic)) {
                    if (r.tryConsume()) |val| {
                        const idx = @as(usize, @intCast(val));
                        if (idx >= flags.len) {
                            std.debug.print("OUT OF BOUNDS: {} >= {}\n", .{ idx, flags.len });
                            err.store(true, .release);
                            return;
                        }
                        const was_set = flags[idx].swap(true, .acq_rel);
                        if (was_set) {
                            std.debug.print("DUPLICATE: item {} consumed twice!\n", .{idx});
                            err.store(true, .release);
                            return;
                        }
                        _ = count.fetchAdd(1, .monotonic);
                    }
                }
            }
        }.run, .{ &ring, consumed_flags, &consumed_count, total, &error_flag });
    }

    for (producers) |p| p.join();
    ring.close();
    for (consumers) |c| c.join();

    try std.testing.expect(!error_flag.load(.acquire));

    // Verify all consumed
    var missing: usize = 0;
    for (consumed_flags) |f| {
        if (!f.load(.acquire)) missing += 1;
    }

    if (missing > 0) {
        std.debug.print("MISSING: {} items never consumed!\n", .{missing});
        return error.TestFailed;
    }

    try std.testing.expectEqual(total, consumed_count.load(.acquire));
}
