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

## benchmarks

10P/10C on 20-core machine, 100 runs each:

| metric     | ziggy     | crossbeam | diff |
|------------|-----------|-----------|------|
| throughput | 6.36 M/s  | 6.51 M/s  | -2%  |
| p50        | 0.060 ms  | 0.046 ms  | -30% |
| p99        | 0.092 ms  | 0.089 ms  | -4%  |
| p99.9      | 0.156 ms  | 0.154 ms  | ~0%  |
| p99.99     | 0.195 ms  | 0.205 ms  | +5%  |
| p99.999    | 0.853 ms  | 0.551 ms  | -55% |

![latency](benchmarks/latency.png)

![throughput](benchmarks/throughput.png)

crossbeam wins on median latency, ziggy is competitive on throughput and p99.9.

173 lines of zig vs 639 lines of rust (array.rs only, full crossbeam-channel is 8600+ lines).

to run crossbeam benchmark:
```
cd benchmarks/crossbeam
cargo run --release
```
