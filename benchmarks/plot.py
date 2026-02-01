#!/usr/bin/env python3
import matplotlib.pyplot as plt
import numpy as np

# Data from 100-run benchmark
latency_metrics = ['p50', 'p99', 'p99.9', 'p99.99', 'p99.999']
ziggy_latency = [0.060, 0.092, 0.156, 0.195, 0.853]  # in ms
crossbeam_latency = [0.046, 0.089, 0.154, 0.205, 0.551]  # in ms

throughput_ziggy = 6.36
throughput_crossbeam = 6.51

# Latency chart
fig1, ax1 = plt.subplots(figsize=(10, 5))
x = np.arange(len(latency_metrics))
width = 0.35

bars1 = ax1.bar(x - width/2, ziggy_latency, width, label='Ziggy', color='#4a90d9')
bars2 = ax1.bar(x + width/2, crossbeam_latency, width, label='Crossbeam', color='#d94a4a')

ax1.set_ylabel('Latency (ms)')
ax1.set_xlabel('Percentile')
ax1.set_title('Latency Comparison (10P/10C, 100 runs)')
ax1.set_xticks(x)
ax1.set_xticklabels(latency_metrics)
ax1.legend()
ax1.set_ylim(0, max(max(ziggy_latency), max(crossbeam_latency)) * 1.15)

for bar in bars1:
    h = bar.get_height()
    ax1.annotate(f'{h:.3f}', xy=(bar.get_x() + bar.get_width()/2, h), xytext=(0, 3),
                 textcoords="offset points", ha='center', va='bottom', fontsize=8)
for bar in bars2:
    h = bar.get_height()
    ax1.annotate(f'{h:.3f}', xy=(bar.get_x() + bar.get_width()/2, h), xytext=(0, 3),
                 textcoords="offset points", ha='center', va='bottom', fontsize=8)

plt.tight_layout()
plt.savefig('latency.png', dpi=150)
print("Saved latency.png")

# Throughput chart
fig2, ax2 = plt.subplots(figsize=(6, 5))
bars = ax2.bar(['Ziggy', 'Crossbeam'], [throughput_ziggy, throughput_crossbeam],
               color=['#4a90d9', '#d94a4a'], width=0.5)

ax2.set_ylabel('Throughput (M ops/sec)')
ax2.set_title('Throughput Comparison (10P/10C, 100 runs)')
ax2.set_ylim(0, max(throughput_ziggy, throughput_crossbeam) * 1.15)

for bar in bars:
    h = bar.get_height()
    ax2.annotate(f'{h:.2f}', xy=(bar.get_x() + bar.get_width()/2, h), xytext=(0, 3),
                 textcoords="offset points", ha='center', va='bottom', fontsize=10)

plt.tight_layout()
plt.savefig('throughput.png', dpi=150)
print("Saved throughput.png")
