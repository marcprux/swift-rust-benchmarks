//! sensor-rollup: a telemetry pipeline over plain value types (arrays of structs,
//! floating-point and integer arithmetic), with no heap objects, strings or
//! reference counting in the hot path. It is the control benchmark: both
//! languages compile to nearly the same machine code here. See ../README.md.

use benchkit::{Args, Fnv1a, Report, SplitMix64, Stopwatch};
use std::fmt::Write as _;

const WINDOW_MS: u64 = 60_000;
const HISTORY: usize = 60;
const MIN_HISTORY: usize = 10;
const BINS: usize = 256;

#[derive(Clone, Copy)]
struct Reading {
    sensor: u32,
    quality: u32, // 0 = good, 1 = flagged by the device
    timestamp: u64,
    value: f64,
}

#[derive(Clone, Copy)]
struct Stats {
    count: u32,
    sum: f64,
    min: f64,
    max: f64,
    sum_sq: f64,
}

impl Stats {
    const EMPTY: Stats = Stats { count: 0, sum: 0.0, min: f64::INFINITY, max: f64::NEG_INFINITY, sum_sq: 0.0 };
}

/// Uniform double in [0, 1) from the top 53 bits of the PRNG output.
#[inline]
fn uniform(rng: &mut SplitMix64) -> f64 {
    (rng.next_u64() >> 11) as f64 * (1.0 / 9_007_199_254_740_992.0)
}

/// Interleaved readings from `sensors` devices, each following its own random
/// walk, with timestamps increasing by 1-20 ms and 1% device-flagged spikes.
fn generate(rng: &mut SplitMix64, sensors: usize, readings: usize) -> Vec<Reading> {
    let mut levels: Vec<f64> = Vec::with_capacity(sensors);
    for _ in 0..sensors {
        levels.push(20.0 + 10.0 * uniform(rng));
    }
    let mut out = Vec::with_capacity(readings);
    let mut ts: u64 = 0;
    for _ in 0..readings {
        ts += 1 + rng.below(20);
        let s = rng.below(sensors as u64) as usize;
        let step = uniform(rng) * 2.0 - 1.0;
        levels[s] += step * 0.1;
        let jitter = uniform(rng) * 2.0 - 1.0;
        let mut value = levels[s] + jitter * 0.5;
        let mut quality = 0;
        if rng.below(100) == 0 {
            value += 50.0;
            quality = 1;
        }
        out.push(Reading { sensor: s as u32, quality, timestamp: ts, value });
    }
    out
}

struct Rollup {
    stats: Vec<Stats>, // sensors x windows, row-major
    windows: usize,
    good: u64,
    bad: u64,
    min: f64,
    max: f64,
}

/// Per-sensor, per-minute count / sum / min / max / sum of squares over the
/// readings the device did not flag.
fn rollup(readings: &[Reading], sensors: usize) -> Rollup {
    let last = readings.last().map_or(0, |r| r.timestamp);
    let windows = (last / WINDOW_MS) as usize + 1;
    let mut stats = vec![Stats::EMPTY; sensors * windows];
    let (mut good, mut bad) = (0u64, 0u64);
    let (mut gmin, mut gmax) = (f64::INFINITY, f64::NEG_INFINITY);
    for r in readings {
        if r.quality != 0 {
            bad += 1;
            continue;
        }
        good += 1;
        let v = r.value;
        let w = (r.timestamp / WINDOW_MS) as usize;
        let st = &mut stats[r.sensor as usize * windows + w];
        st.count += 1;
        st.sum += v;
        if v < st.min {
            st.min = v;
        }
        if v > st.max {
            st.max = v;
        }
        st.sum_sq += v * v;
        if v < gmin {
            gmin = v;
        }
        if v > gmax {
            gmax = v;
        }
    }
    Rollup { stats, windows, good, bad, min: gmin, max: gmax }
}

/// For every sensor, walk the window means in time order and flag a window whose
/// mean lies more than three standard deviations from the trailing HISTORY
/// windows' means. Returns the anomaly count per sensor.
fn anomalies(roll: &Rollup, sensors: usize) -> Vec<u32> {
    let windows = roll.windows;
    let mut counts = vec![0u32; sensors];
    let mut ring = [0.0f64; HISTORY];
    for s in 0..sensors {
        let (mut hist_sum, mut hist_sq) = (0.0f64, 0.0f64);
        let (mut ring_count, mut head) = (0usize, 0usize);
        let mut found = 0u32;
        for w in 0..windows {
            let st = roll.stats[s * windows + w];
            if st.count == 0 {
                continue;
            }
            let mean = st.sum / st.count as f64;
            if ring_count >= MIN_HISTORY {
                let n = ring_count as f64;
                let mu = hist_sum / n;
                let mut var = hist_sq / n - mu * mu;
                if var < 0.0 {
                    var = 0.0;
                }
                let dev = mean - mu;
                if dev * dev > 9.0 * var {
                    found += 1;
                }
            }
            if ring_count == HISTORY {
                let old = ring[head];
                hist_sum -= old;
                hist_sq -= old * old;
            } else {
                ring_count += 1;
            }
            ring[head] = mean;
            hist_sum += mean;
            hist_sq += mean * mean;
            head = (head + 1) % HISTORY;
        }
        counts[s] = found;
    }
    counts
}

/// 256-bin histogram per sensor over the global value range, then the bin that
/// holds the 50th, 95th and 99th percentile of each sensor's good readings.
fn quantiles(readings: &[Reading], sensors: usize, lo: f64, hi: f64) -> Vec<[u8; 3]> {
    let mut hist = vec![0u32; sensors * BINS];
    let scale = if hi > lo { (BINS - 1) as f64 / (hi - lo) } else { 0.0 };
    for r in readings {
        if r.quality != 0 {
            continue;
        }
        let mut bin = ((r.value - lo) * scale) as usize;
        if bin > BINS - 1 {
            bin = BINS - 1;
        }
        hist[r.sensor as usize * BINS + bin] += 1;
    }
    let mut out = Vec::with_capacity(sensors);
    for s in 0..sensors {
        let row = &hist[s * BINS..(s + 1) * BINS];
        let total: u64 = row.iter().map(|&c| c as u64).sum();
        let mut result = [0u8; 3];
        for (i, pct) in [50u64, 95, 99].iter().enumerate() {
            let rank = ((total * pct + 99) / 100).max(1);
            let mut cumulative = 0u64;
            let mut bin = 0usize;
            while bin < BINS - 1 {
                cumulative += row[bin] as u64;
                if cumulative >= rank {
                    break;
                }
                bin += 1;
            }
            result[i] = bin as u8;
        }
        out.push(result);
    }
    out
}

fn main() {
    let args = Args::parse();
    let sensors = args.usize("sensors", 1_000).max(1);
    let n_readings = args.usize("readings", 5_000_000);
    let seed = args.u64("seed", 42);
    let quiet = args.flag("quiet");

    let mut summary = String::new();
    let total = Stopwatch::start();

    let sw = Stopwatch::start();
    let mut rng = SplitMix64::new(seed);
    let readings = generate(&mut rng, sensors, n_readings);
    let generate_ms = sw.elapsed_ms();

    let sw = Stopwatch::start();
    let roll = rollup(&readings, sensors);
    let rollup_ms = sw.elapsed_ms();
    writeln!(
        summary,
        "rollup windows={} good={} bad={} min={:016x} max={:016x}",
        roll.windows, roll.good, roll.bad, roll.min.to_bits(), roll.max.to_bits()
    )
    .unwrap();

    let sw = Stopwatch::start();
    let anomaly_counts = anomalies(&roll, sensors);
    let anomaly_ms = sw.elapsed_ms();
    let anomaly_total: u64 = anomaly_counts.iter().map(|&c| c as u64).sum();
    writeln!(summary, "anomalies total={anomaly_total}").unwrap();

    let sw = Stopwatch::start();
    let percentiles = quantiles(&readings, sensors, roll.min, roll.max);
    let quantile_ms = sw.elapsed_ms();

    // Per-sensor detail, hashed rather than printed.
    let mut detail = Fnv1a::new();
    for s in 0..sensors {
        let mut sum = 0.0f64;
        let mut count = 0u64;
        for w in 0..roll.windows {
            let st = roll.stats[s * roll.windows + w];
            sum += st.sum;
            count += st.count as u64;
        }
        detail.update(&anomaly_counts[s].to_le_bytes());
        detail.update(&percentiles[s]);
        detail.update(&sum.to_bits().to_le_bytes());
        detail.update(&count.to_le_bytes());
    }
    writeln!(
        summary,
        "sensors={} p50/p95/p99[0]={}/{}/{} detail={:016x}",
        sensors, percentiles[0][0], percentiles[0][1], percentiles[0][2], detail.finish()
    )
    .unwrap();

    let sw = Stopwatch::start();
    drop(percentiles);
    drop(anomaly_counts);
    drop(roll);
    drop(readings);
    let free_ms = sw.elapsed_ms();

    let total_ms = total.elapsed_ms();
    let mut h = Fnv1a::new();
    h.update(summary.as_bytes());

    if !quiet {
        print!("{summary}");
    }
    Report::new("sensor-rollup")
        .int("sensors", sensors as u64)
        .int("readings", n_readings as u64)
        .int("seed", seed)
        .int("anomalies", anomaly_total)
        .ms("generate_ms", generate_ms)
        .ms("rollup_ms", rollup_ms)
        .ms("anomaly_ms", anomaly_ms)
        .ms("quantile_ms", quantile_ms)
        .ms("free_ms", free_ms)
        .ms("total_ms", total_ms)
        .text("checksum", &format!("{:016x}", h.finish()))
        .emit();
}
