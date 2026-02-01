const std = @import("std");

// 128 bytes to handle x86 adjacent-line prefetch (effectively 128-byte coherence unit)
const cache_line = 128;

const Waiter = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    shutdown: bool = false,

    fn wait(self: *Waiter) void {
        // Spin with yield instead of condvar - avoids futex syscall overhead on Linux
        for (0..100) |_| {
            if (self.shutdown) return;
            std.atomic.spinLoopHint();
        }
        std.Thread.yield() catch {};
    }

    fn notifyOne(self: *Waiter) void {
        self.cond.signal();
    }

    fn notifyAll(self: *Waiter) void {
        self.cond.broadcast();
    }

    fn close(self: *Waiter) void {
        self.mutex.lock();
        self.shutdown = true;
        self.mutex.unlock();
        self.cond.broadcast();
    }
};

fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            value: T = undefined,
            version: u64 = 0,
        };

        ring: []Entry,
        allocator: std.mem.Allocator,
        encoded_version: u64 align(cache_line) = 0,
        consumed_index: u64 align(cache_line) = 0,
        waiter: Waiter = .{},

        pub fn init(allocator: std.mem.Allocator, size: u32) !Self {
            const ring = try allocator.alloc(Entry, size);
            @memset(ring, Entry{});
            return .{
                .ring = ring,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.ring);
            self.* = undefined;
        }

        pub fn produce(self: *Self, value: T) void {
            const slot = while (true) {
                const current = @atomicLoad(u64, &self.encoded_version, .acquire);
                const write_idx: u32 = @truncate(current);
                const version: u32 = @truncate(current >> 32);

                const consumed: u32 = @truncate(@atomicLoad(u64, &self.consumed_index, .acquire));
                if (write_idx -% consumed >= self.ring.len) {
                    std.Thread.yield() catch {};
                    continue;
                }

                const new_idx = write_idx +% 1;
                const new_version = version +% 1;
                const new_encoded = @as(u64, new_idx) | (@as(u64, new_version) << 32);

                if (@cmpxchgWeak(
                    u64,
                    &self.encoded_version,
                    current,
                    new_encoded,
                    .acq_rel,
                    .monotonic,
                ) == null) {
                    break .{ .idx = write_idx, .ver = new_version };
                }
            };

            const entry = &self.ring[slot.idx % self.ring.len];
            entry.value = value;
            @atomicStore(u64, &entry.version, slot.ver, .release);
        }

        pub fn notify(self: *Self) void {
            self.waiter.notifyOne();
        }

        pub fn notifyAll(self: *Self) void {
            self.waiter.notifyAll();
        }

        pub fn close(self: *Self) void {
            self.waiter.close();
        }

        pub fn tryConsume(self: *Self) ?T {
            const consumed: u64 = @atomicLoad(u64, &self.consumed_index, .acquire);
            const consumed_idx: u32 = @truncate(consumed);
            const write_state = @atomicLoad(u64, &self.encoded_version, .acquire);
            const write_idx: u32 = @truncate(write_state);

            if (consumed_idx == write_idx) {
                return null;
            }

            if (@cmpxchgWeak(
                u64,
                &self.consumed_index,
                consumed,
                consumed +% 1,
                .acq_rel,
                .monotonic,
            ) == null) {
                const slot_idx = consumed_idx % @as(u32, @intCast(self.ring.len));
                const expected_version: u64 = consumed_idx +% 1;

                const entry = &self.ring[slot_idx];
                while (@atomicLoad(u64, &entry.version, .acquire) < expected_version) {
                    std.atomic.spinLoopHint();
                }

                return entry.value;
            }

            return null;
        }

        pub fn consume(self: *Self) ?T {
            // Fast path - try immediately
            if (self.tryConsume()) |value| {
                return value;
            }

            // Spin briefly (cheaper than futex syscall on Linux)
            for (0..64) |_| {
                std.atomic.spinLoopHint();
                if (self.tryConsume()) |value| return value;
                if (self.waiter.shutdown) return null;
            }

            // Slow path - park
            self.waiter.wait();
            return self.tryConsume();
        }
    };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Ring Buffer Benchmark ===\n\n", .{});

    try runBenchmark(allocator, 1, 1, 1_000_000, 256);
    try runBenchmark(allocator, 4, 4, 1_000_000, 256);
    try runBenchmark(allocator, 100, 100, 1_000_000, 1024);
}

const Ring = RingBuffer(u64);

fn runBenchmark(
    allocator: std.mem.Allocator,
    num_producers: u32,
    num_consumers: u32,
    total_items: u32,
    ring_size: u32,
) !void {
    var ring = try Ring.init(allocator, ring_size);
    defer ring.deinit();

    var consumed = std.atomic.Value(u32).init(0);
    var producers_done = std.atomic.Value(u32).init(0);
    const items_per_producer = total_items / num_producers;
    const actual_total = items_per_producer * num_producers;

    const producer_threads = try allocator.alloc(std.Thread, num_producers);
    defer allocator.free(producer_threads);
    const consumer_threads = try allocator.alloc(std.Thread, num_consumers);
    defer allocator.free(consumer_threads);

    const start = std.time.nanoTimestamp();

    for (producer_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, benchProducer, .{ &ring, items_per_producer, &producers_done, num_producers });
    }

    for (consumer_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, benchConsumer, .{ &ring, &consumed, actual_total });
    }

    for (producer_threads) |t| t.join();
    for (consumer_threads) |t| t.join();

    const end = std.time.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(end - start);
    const elapsed_ms = elapsed_ns / 1_000_000;
    const ops_per_sec = if (elapsed_ns > 0) (@as(u64, actual_total) * 1_000_000_000) / elapsed_ns else 0;

    std.debug.print("{d}P/{d}C: {d} items in {d}ms = {d} ops/sec\n", .{
        num_producers,
        num_consumers,
        actual_total,
        elapsed_ms,
        ops_per_sec,
    });
}

fn benchProducer(ring: *Ring, count: u32, producers_done: *std.atomic.Value(u32), num_producers: u32) void {
    for (0..count) |i| {
        ring.produce(i);
        ring.notify();
    }

    if (producers_done.fetchAdd(1, .release) + 1 == num_producers) {
        ring.notifyAll();
    }
}

fn benchConsumer(ring: *Ring, consumed: *std.atomic.Value(u32), total: u32) void {
    while (true) {
        if (consumed.load(.monotonic) >= total) {
            ring.close();
            return;
        }

        if (ring.consume()) |_| {
            if (consumed.fetchAdd(1, .monotonic) + 1 >= total) {
                ring.close();
                return;
            }
            ring.notify();
        }
    }
}
