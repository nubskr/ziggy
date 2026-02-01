use crossbeam_channel::bounded;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

fn main() {
    let cpus = thread::available_parallelism().map(|p| p.get()).unwrap_or(4);
    let threads_per_side = (cpus / 2).max(1) as u32;

    println!("=== Crossbeam: {} CPUs, using {}P/{}C ===\n", cpus, threads_per_side, threads_per_side);

    println!("=== THROUGHPUT ===");
    run_throughput_benchmark(threads_per_side, threads_per_side, 1_000_000, 512);

    println!("\n=== LATENCY ===");
    run_latency_benchmark(threads_per_side, threads_per_side, 100_000, 512);
}

fn run_throughput_benchmark(num_producers: u32, num_consumers: u32, total_items: u32, ring_size: usize) {
    let (tx, rx) = bounded::<u64>(ring_size);
    let consumed = Arc::new(AtomicU32::new(0));
    let items_per_producer = total_items / num_producers;
    let actual_total = items_per_producer * num_producers;

    let start = Instant::now();

    let producers: Vec<_> = (0..num_producers)
        .map(|_| {
            let tx = tx.clone();
            thread::spawn(move || {
                for i in 0..items_per_producer {
                    tx.send(i as u64).unwrap();
                }
            })
        })
        .collect();

    let consumers: Vec<_> = (0..num_consumers)
        .map(|_| {
            let rx = rx.clone();
            let consumed = consumed.clone();
            thread::spawn(move || {
                while consumed.load(Ordering::Relaxed) < actual_total {
                    if rx.try_recv().is_ok() {
                        consumed.fetch_add(1, Ordering::Relaxed);
                    }
                }
            })
        })
        .collect();

    for p in producers { p.join().unwrap(); }
    drop(tx);
    for c in consumers { c.join().unwrap(); }

    let elapsed = start.elapsed().as_nanos() as u64;
    let ops_per_sec = if elapsed > 0 { (actual_total as u64 * 1_000_000_000) / elapsed } else { 0 };
    println!("{}P/{}C: {} ops/sec", num_producers, num_consumers, ops_per_sec);
}

fn run_latency_benchmark(num_producers: u32, num_consumers: u32, total_items: u32, ring_size: usize) {
    let (tx, rx) = bounded::<(Instant, u64)>(ring_size);
    let consumed = Arc::new(AtomicU32::new(0));
    let items_per_producer = total_items / num_producers;
    let actual_total = items_per_producer * num_producers;

    let latencies = Arc::new(std::sync::Mutex::new(Vec::with_capacity(actual_total as usize)));

    let start = Instant::now();

    let producers: Vec<_> = (0..num_producers)
        .map(|_| {
            let tx = tx.clone();
            thread::spawn(move || {
                for i in 0..items_per_producer {
                    tx.send((Instant::now(), i as u64)).unwrap();
                }
            })
        })
        .collect();

    let consumers: Vec<_> = (0..num_consumers)
        .map(|_| {
            let rx = rx.clone();
            let consumed = consumed.clone();
            let latencies = latencies.clone();
            thread::spawn(move || {
                let mut local_latencies = Vec::new();
                while consumed.load(Ordering::Relaxed) < actual_total {
                    if let Ok((send_time, _)) = rx.try_recv() {
                        local_latencies.push(send_time.elapsed().as_nanos() as i64);
                        consumed.fetch_add(1, Ordering::Relaxed);
                    }
                }
                latencies.lock().unwrap().extend(local_latencies);
            })
        })
        .collect();

    for p in producers { p.join().unwrap(); }
    drop(tx);
    for c in consumers { c.join().unwrap(); }

    let end = Instant::now();
    let mut latencies = Arc::try_unwrap(latencies).unwrap().into_inner().unwrap();

    if latencies.is_empty() {
        println!("No samples");
        return;
    }

    latencies.sort();
    let n = latencies.len();
    let p50 = latencies[n / 2];
    let p99 = latencies[(n * 99) / 100];
    let p999 = latencies[(n * 999) / 1000];
    let p9999 = latencies[(n * 9999) / 10000];
    let p99999 = latencies[((n * 99999) / 100000).min(n - 1)];
    let elapsed_ms = (end - start).as_millis();

    println!("{}P/{}C ({} samples, {}ms):", num_producers, num_consumers, n, elapsed_ms);
    println!("  p50: {}µs, p99: {}µs, p99.9: {}µs, p99.99: {}µs, p99.999: {}µs",
        p50 / 1000, p99 / 1000, p999 / 1000, p9999 / 1000, p99999 / 1000);
}
