const std = @import("std");
const builtin = @import("builtin");

const cache_line = 128;

/// Waiter for parking threads when queue is empty/full.
/// Uses parked_count for fast-path: skip syscall when no one is waiting.
const Waiter = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    parked_count: u32 align(cache_line) = 0,
    shutdown: bool = false,

    /// Park the calling thread until notified or shutdown
    fn wait(self: *Waiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = @atomicRmw(u32, &self.parked_count, .Add, 1, .monotonic);
        defer _ = @atomicRmw(u32, &self.parked_count, .Sub, 1, .monotonic);

        while (!self.shutdown) {
            self.cond.wait(&self.mutex);
            break; // Woken up
        }
    }

    /// Wake one parked thread (if any)
    fn notifyOne(self: *Waiter) void {
        // Fast path: no one waiting, skip the signal entirely
        if (@atomicLoad(u32, &self.parked_count, .monotonic) == 0) {
            return;
        }
        self.cond.signal();
    }

    /// Wake all parked threads
    fn notifyAll(self: *Waiter) void {
        if (@atomicLoad(u32, &self.parked_count, .monotonic) == 0) {
            return;
        }
        self.cond.broadcast();
    }

    /// Signal shutdown and wake everyone
    fn close(self: *Waiter) void {
        self.mutex.lock();
        self.shutdown = true;
        self.mutex.unlock();
        self.cond.broadcast();
    }
};

/// Thread-safe MPMC ring buffer using sequence-per-slot design.
///
/// Invariants:
/// 1. head >= tail (can't consume more than produced)
/// 2. head - tail <= size (can't exceed capacity)
/// 3. Each item consumed exactly once
/// 4. Each slot written only when free
/// 5. Consumer reads only after producer writes
fn RingBuffer(comptime T: type) type {
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
        shutdown: bool align(cache_line) = false,
        consumer_waiter: Waiter align(cache_line) = .{},
        allocator: std.mem.Allocator,

        // Debug counters (only in debug builds)
        produced: if (builtin.mode == .Debug) std.atomic.Value(u64) else void =
            if (builtin.mode == .Debug) std.atomic.Value(u64).init(0) else {},
        consumed: if (builtin.mode == .Debug) std.atomic.Value(u64) else void =
            if (builtin.mode == .Debug) std.atomic.Value(u64).init(0) else {},

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

        pub fn produce(self: *Self, value: T) void {
            var spin_count: u8 = 0;
            while (true) {
                const head = @atomicLoad(u64, &self.head, .monotonic);
                const slot_idx = head & self.mask;
                const slot = &self.slots[slot_idx];

                const seq = @atomicLoad(u64, &slot.sequence, .acquire);
                const diff = @as(i64, @bitCast(seq)) - @as(i64, @bitCast(head));

                if (diff == 0) {
                    if (@cmpxchgWeak(u64, &self.head, head, head +% 1, .monotonic, .monotonic) == null) {
                        slot.value = value;
                        @atomicStore(u64, &slot.sequence, head +% 1, .release);

                        if (builtin.mode == .Debug) {
                            _ = self.produced.fetchAdd(1, .monotonic);
                        }

                        // Wake one sleeping consumer (if any)
                        self.consumer_waiter.notifyOne();
                        return;
                    }
                    spin_count = 0;
                } else if (diff < 0) {
                    // Buffer full - producers spin (consumers will catch up)
                    if (spin_count < 16) {
                        std.atomic.spinLoopHint();
                        spin_count += 1;
                    } else {
                        // Yield to let consumers run
                        std.Thread.yield() catch {};
                        spin_count = 8;
                    }
                }
            }
        }

        pub fn close(self: *Self) void {
            @atomicStore(bool, &self.shutdown, true, .release);
            self.consumer_waiter.close();
        }

        pub fn tryConsume(self: *Self) ?T {
            const tail = @atomicLoad(u64, &self.tail, .monotonic);
            const slot_idx = tail & self.mask;
            const slot = &self.slots[slot_idx];

            const seq = @atomicLoad(u64, &slot.sequence, .acquire);
            const diff = @as(i64, @bitCast(seq)) - @as(i64, @bitCast(tail +% 1));

            if (diff == 0) {
                if (@cmpxchgWeak(u64, &self.tail, tail, tail +% 1, .monotonic, .monotonic) == null) {
                    const value = slot.value;
                    @atomicStore(u64, &slot.sequence, tail +% self.mask +% 1, .release);

                    if (builtin.mode == .Debug) {
                        _ = self.consumed.fetchAdd(1, .monotonic);
                    }
                    return value;
                }
            }
            return null;
        }

        /// Blocking consume - spins briefly, then parks if no data
        pub fn consume(self: *Self) ?T {
            // Fast path
            if (self.tryConsume()) |v| return v;

            // Spin briefly - message might be arriving
            var spin_count: u8 = 0;
            while (spin_count < 16) {
                if (self.tryConsume()) |v| return v;
                if (@atomicLoad(bool, &self.shutdown, .acquire)) {
                    return self.tryConsume();
                }
                std.atomic.spinLoopHint();
                spin_count += 1;
            }

            // Nothing coming - park instead of burning CPU
            while (!@atomicLoad(bool, &self.shutdown, .acquire)) {
                self.consumer_waiter.wait();

                // Woke up - try again
                if (self.tryConsume()) |v| return v;
            }

            return self.tryConsume();
        }

        /// Debug: check invariants hold
        pub fn checkInvariants(self: *Self) void {
            if (builtin.mode != .Debug) return;

            const head = @atomicLoad(u64, &self.head, .acquire);
            const tail = @atomicLoad(u64, &self.tail, .acquire);
            const produced = self.produced.load(.acquire);
            const consumed = self.consumed.load(.acquire);

            // head >= tail (in modular arithmetic, check via size)
            const in_flight = head -% tail;
            std.debug.assert(in_flight <= self.mask + 1); // Can't have more than ring size

            // produced == head, consumed == tail
            std.debug.assert(produced == head);
            std.debug.assert(consumed == tail);
        }
    };
}

// ============================================================================
// TESTS
// ============================================================================

/// Unique value for testing: encodes producer ID and sequence number
const TestValue = struct {
    producer_id: u32,
    seq: u32,

    fn encode(producer_id: u32, seq: u32) u64 {
        return (@as(u64, producer_id) << 32) | seq;
    }

    fn decode(val: u64) TestValue {
        return .{
            .producer_id = @intCast(val >> 32),
            .seq = @intCast(val & 0xFFFFFFFF),
        };
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
        }.run, .{&ring, @as(u32, @intCast(p))});
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
        }.run, .{&ring, @as(u32, @intCast(p))});
    }

    // Start consumers
    for (0..num_consumers) |c| {
        consumers[c] = try std.Thread.spawn(.{}, struct {
            fn run(r: *TestRing, flags: []std.atomic.Value(bool), count: *std.atomic.Value(usize), total_items: usize) void {
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
        }.run, .{&ring, consumed_flags, &consumed_count, total});
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

// ============================================================================
// FUZZ TEST
// ============================================================================

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

fn fuzzTestWithParams(allocator: std.mem.Allocator, ring_size: u32, num_producers: u8, num_consumers: u8, items_per_producer: u32) !void {
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
            fn run(r: *TestRing, flags: []std.atomic.Value(bool), count: *std.atomic.Value(usize), total_items: usize, err: *std.atomic.Value(bool)) void {
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

    std.debug.print("\nFuzz: ring_size={}, {}P/{}C, {} items each, {} total\n",
        .{ring_size, num_producers, num_consumers, items_per_producer, total});

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
        }.run, .{&ring, p, items_per_producer, items_per_producer});
    }

    // Start consumers
    for (0..num_consumers) |c| {
        consumers[c] = try std.Thread.spawn(.{}, struct {
            fn run(r: *TestRing, flags: []std.atomic.Value(bool), count: *std.atomic.Value(usize),
                   total_items: usize, err: *std.atomic.Value(bool)) void {
                while (count.load(.monotonic) < total_items and !err.load(.monotonic)) {
                    if (r.tryConsume()) |val| {
                        const idx = @as(usize, @intCast(val));
                        if (idx >= flags.len) {
                            std.debug.print("OUT OF BOUNDS: {} >= {}\n", .{idx, flags.len});
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
        }.run, .{&ring, consumed_flags, &consumed_count, total, &error_flag});
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

// ============================================================================
// BENCHMARKS (run with: zig build run -Doptimize=ReleaseFast)
// ============================================================================

const TimestampedMsg = struct {
    send_time: i128,
    id: u64,
};

const BenchRing = RingBuffer(TimestampedMsg);
const ThroughputRing = RingBuffer(u64);

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const cpus = std.Thread.getCpuCount() catch 4;
    const threads_per_side: u32 = @intCast(@max(1, cpus / 2));

    std.debug.print("=== {d} CPUs detected, using {d}P/{d}C (no oversubscription) ===\n\n", .{cpus, threads_per_side, threads_per_side});

    std.debug.print("=== THROUGHPUT ===\n", .{});
    try runThroughputBenchmark(allocator, threads_per_side, threads_per_side, 1_000_000, 512);

    std.debug.print("\n=== LATENCY ===\n", .{});
    try runLatencyBenchmark(allocator, threads_per_side, threads_per_side, 100_000, 512);
}

fn runThroughputBenchmark(allocator: std.mem.Allocator, num_producers: u32, num_consumers: u32, total_items: u32, ring_size: u32) !void {
    var ring = try ThroughputRing.init(allocator, ring_size);
    defer ring.deinit();
    var consumed = std.atomic.Value(u32).init(0);
    const items_per_producer = total_items / num_producers;
    const actual_total = items_per_producer * num_producers;
    const producer_threads = try allocator.alloc(std.Thread, num_producers);
    defer allocator.free(producer_threads);
    const consumer_threads = try allocator.alloc(std.Thread, num_consumers);
    defer allocator.free(consumer_threads);
    const start = std.time.nanoTimestamp();
    for (producer_threads) |*t| t.* = try std.Thread.spawn(.{}, throughputProducer, .{ &ring, items_per_producer });
    for (consumer_threads) |*t| t.* = try std.Thread.spawn(.{}, throughputConsumer, .{ &ring, &consumed, actual_total });
    for (producer_threads) |t| t.join();
    ring.close();
    for (consumer_threads) |t| t.join();
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const ops_per_sec = if (elapsed_ns > 0) (@as(u64, actual_total) * 1_000_000_000) / elapsed_ns else 0;
    std.debug.print("{d}P/{d}C: {d} ops/sec\n", .{num_producers, num_consumers, ops_per_sec});
}

fn throughputProducer(ring: *ThroughputRing, count: u32) void {
    for (0..count) |i| ring.produce(i);
}

fn throughputConsumer(ring: *ThroughputRing, consumed: *std.atomic.Value(u32), total: u32) void {
    while (consumed.load(.monotonic) < total) {
        if (ring.consume()) |_| _ = consumed.fetchAdd(1, .monotonic);
    }
}

fn runLatencyBenchmark(allocator: std.mem.Allocator, num_producers: u32, num_consumers: u32, total_items: u32, ring_size: u32) !void {
    var ring = try BenchRing.init(allocator, ring_size);
    defer ring.deinit();

    const max_samples = total_items;
    var latencies = try allocator.alloc(i128, max_samples);
    defer allocator.free(latencies);
    @memset(latencies, 0);

    var latency_idx = std.atomic.Value(u32).init(0);
    var consumed = std.atomic.Value(u32).init(0);

    const items_per_producer = total_items / num_producers;
    const actual_total = items_per_producer * num_producers;

    const producer_threads = try allocator.alloc(std.Thread, num_producers);
    defer allocator.free(producer_threads);
    const consumer_threads = try allocator.alloc(std.Thread, num_consumers);
    defer allocator.free(consumer_threads);

    const start = std.time.nanoTimestamp();

    for (producer_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, latencyProducer, .{ &ring, items_per_producer });
    }

    for (consumer_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, latencyConsumer, .{ &ring, &consumed, actual_total, latencies, &latency_idx });
    }

    for (producer_threads) |t| t.join();
    ring.close();
    for (consumer_threads) |t| t.join();

    const end = std.time.nanoTimestamp();

    const num_samples = @min(latency_idx.load(.monotonic), max_samples);
    if (num_samples == 0) {
        std.debug.print("{d}P/{d}C: No samples collected\n", .{ num_producers, num_consumers });
        return;
    }

    std.mem.sort(i128, latencies[0..num_samples], {}, std.sort.asc(i128));

    const min_lat = latencies[0];
    const p50 = latencies[num_samples / 2];
    const p99 = latencies[(num_samples * 99) / 100];
    const p999 = latencies[(num_samples * 999) / 1000];
    const max_lat = latencies[num_samples - 1];

    var sum: i128 = 0;
    for (latencies[0..num_samples]) |l| sum += l;
    const avg = @divTrunc(sum, num_samples);

    const elapsed_ms = @divTrunc(end - start, 1_000_000);

    std.debug.print("{d}P/{d}C ({d} samples, {d}ms total):\n", .{num_producers, num_consumers, num_samples, elapsed_ms});
    std.debug.print("  min: {d}µs, avg: {d}µs, p50: {d}µs\n", .{@divTrunc(min_lat, 1000), @divTrunc(avg, 1000), @divTrunc(p50, 1000)});
    std.debug.print("  p99: {d}µs, p99.9: {d}µs, max: {d}µs\n\n", .{@divTrunc(p99, 1000), @divTrunc(p999, 1000), @divTrunc(max_lat, 1000)});
}

fn latencyProducer(ring: *BenchRing, count: u32) void {
    for (0..count) |i| {
        ring.produce(.{ .send_time = std.time.nanoTimestamp(), .id = i });
    }
}

fn latencyConsumer(ring: *BenchRing, consumed: *std.atomic.Value(u32), total: u32, latencies: []i128, latency_idx: *std.atomic.Value(u32)) void {
    while (consumed.load(.monotonic) < total) {
        if (ring.consume()) |msg| {
            const idx = latency_idx.fetchAdd(1, .monotonic);
            if (idx < latencies.len) latencies[idx] = std.time.nanoTimestamp() - msg.send_time;
            _ = consumed.fetchAdd(1, .monotonic);
        }
    }
}
