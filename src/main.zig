const std = @import("std");

const cache_line = 128;

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
        allocator: std.mem.Allocator,

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
                const slot = &self.slots[head & self.mask];

                const seq = @atomicLoad(u64, &slot.sequence, .acquire);
                const diff = @as(i64, @bitCast(seq)) - @as(i64, @bitCast(head));

                if (diff == 0) {
                    if (@cmpxchgWeak(u64, &self.head, head, head +% 1, .monotonic, .monotonic) == null) {
                        slot.value = value;
                        @atomicStore(u64, &slot.sequence, head +% 1, .release);
                        return;
                    }
                    spin_count = 0; // Got close, reset
                } else if (diff < 0) {
                    // Buffer full - progressive backoff
                    // First 8 tries: just spin hint (~5-10ns each)
                    // Then: 2, 4, 8, 16... spin hints
                    if (spin_count < 8) {
                        std.atomic.spinLoopHint();
                        spin_count += 1;
                    } else {
                        const extra = @min(spin_count - 7, 5); // cap at 32 spins
                        for (0..(@as(u8, 1) << extra)) |_| std.atomic.spinLoopHint();
                        spin_count +|= 1; // saturating add
                    }
                }
            }
        }

        pub fn close(self: *Self) void {
            @atomicStore(bool, &self.shutdown, true, .release);
        }

        pub fn tryConsume(self: *Self) ?T {
            const tail = @atomicLoad(u64, &self.tail, .monotonic);
            const slot = &self.slots[tail & self.mask];

            const seq = @atomicLoad(u64, &slot.sequence, .acquire);
            const diff = @as(i64, @bitCast(seq)) - @as(i64, @bitCast(tail +% 1));

            if (diff == 0) {
                if (@cmpxchgWeak(u64, &self.tail, tail, tail +% 1, .monotonic, .monotonic) == null) {
                    const value = slot.value;
                    @atomicStore(u64, &slot.sequence, tail +% self.mask +% 1, .release);
                    return value;
                }
            }
            return null;
        }

        pub fn consume(self: *Self) ?T {
            if (self.tryConsume()) |v| return v;

            var spin_count: u8 = 0;
            while (!@atomicLoad(bool, &self.shutdown, .acquire)) {
                if (self.tryConsume()) |v| return v;

                // Progressive backoff - tight at first, then back off
                if (spin_count < 8) {
                    std.atomic.spinLoopHint();
                    spin_count += 1;
                } else {
                    const extra = @min(spin_count - 7, 5);
                    for (0..(@as(u8, 1) << extra)) |_| std.atomic.spinLoopHint();
                    spin_count +|= 1;
                }
            }
            return self.tryConsume();
        }
    };
}

// Message with timestamp for latency measurement
const TimestampedMsg = struct {
    send_time: i128,  // nanosecond timestamp when produced
    id: u64,
};

const Ring = RingBuffer(TimestampedMsg);

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Get CPU count, use half for producers, half for consumers
    const cpus = std.Thread.getCpuCount() catch 4;
    const threads_per_side: u32 = @intCast(@max(1, cpus / 2));

    std.debug.print("=== {d} CPUs detected, using {d}P/{d}C (no oversubscription) ===\n\n", .{cpus, threads_per_side, threads_per_side});

    std.debug.print("=== THROUGHPUT ===\n", .{});
    try runThroughputBenchmark(allocator, threads_per_side, threads_per_side, 1_000_000, 512);

    std.debug.print("\n=== LATENCY ===\n", .{});
    try runLatencyBenchmark(allocator, threads_per_side, threads_per_side, 100_000, 512);
}

const ThroughputRing = RingBuffer(u64);

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

fn runLatencyBenchmark(
    allocator: std.mem.Allocator,
    num_producers: u32,
    num_consumers: u32,
    total_items: u32,
    ring_size: u32,
) !void {
    var ring = try Ring.init(allocator, ring_size);
    defer ring.deinit();

    // Collect latencies from consumers
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

    // Calculate latency stats
    const num_samples = @min(latency_idx.load(.monotonic), max_samples);
    if (num_samples == 0) {
        std.debug.print("{d}P/{d}C: No samples collected\n", .{ num_producers, num_consumers });
        return;
    }

    // Sort for percentiles
    std.mem.sort(i128, latencies[0..num_samples], {}, std.sort.asc(i128));

    const min_lat = latencies[0];
    const p50 = latencies[num_samples / 2];
    const p99 = latencies[(num_samples * 99) / 100];
    const p999 = latencies[(num_samples * 999) / 1000];
    const max_lat = latencies[num_samples - 1];

    // Calculate average
    var sum: i128 = 0;
    for (latencies[0..num_samples]) |l| sum += l;
    const avg = @divTrunc(sum, num_samples);

    const elapsed_ms = @divTrunc(end - start, 1_000_000);

    std.debug.print("{d}P/{d}C ({d} samples, {d}ms total):\n", .{
        num_producers, num_consumers, num_samples, elapsed_ms
    });
    std.debug.print("  min: {d}ns, avg: {d}ns, p50: {d}ns\n", .{
        @as(i64, @intCast(min_lat)),
        @as(i64, @intCast(avg)),
        @as(i64, @intCast(p50))
    });
    std.debug.print("  p99: {d}ns, p99.9: {d}ns, max: {d}ns\n\n", .{
        @as(i64, @intCast(p99)),
        @as(i64, @intCast(p999)),
        @as(i64, @intCast(max_lat))
    });
}

fn latencyProducer(ring: *Ring, count: u32) void {
    for (0..count) |i| {
        const msg = TimestampedMsg{
            .send_time = std.time.nanoTimestamp(),
            .id = i,
        };
        ring.produce(msg);
    }
}

fn latencyConsumer(
    ring: *Ring,
    consumed: *std.atomic.Value(u32),
    total: u32,
    latencies: []i128,
    latency_idx: *std.atomic.Value(u32),
) void {
    while (consumed.load(.monotonic) < total) {
        if (ring.consume()) |msg| {
            const recv_time = std.time.nanoTimestamp();
            const latency = recv_time - msg.send_time;

            // Record latency (best effort, may miss some under contention)
            const idx = latency_idx.fetchAdd(1, .monotonic);
            if (idx < latencies.len) {
                latencies[idx] = latency;
            }

            _ = consumed.fetchAdd(1, .monotonic);
        }
    }
}
