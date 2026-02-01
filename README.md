# ziggy

MPMC ring buffer in Zig. Lock-free, sequence-per-slot design.

## usage

```zig
const RingBuffer = @import("ziggy").RingBuffer;

var ring = try RingBuffer(u64).init(allocator, 512);
defer ring.deinit();

// producer
ring.produce(42);

// consumer
if (ring.tryConsume()) |val| { ... }
// or blocking:
if (ring.consume()) |val| { ... }

ring.close();
```

## build

```
zig build -Doptimize=ReleaseFast   # build
zig build test                      # run tests
zig build run -Doptimize=ReleaseFast  # run benchmarks
```

## perf

10P/10C, 20-core machine:
- ~6.8M ops/sec
- p50: ~32µs
