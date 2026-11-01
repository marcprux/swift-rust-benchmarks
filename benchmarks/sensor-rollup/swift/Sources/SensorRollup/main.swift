// sensor-rollup: a telemetry pipeline over plain value types (arrays of structs,
// floating-point and integer arithmetic), with no heap objects, strings or
// reference counting in the hot path. It is the control benchmark: both
// languages compile to nearly the same machine code here. See ../README.md.

import BenchKit

let windowMs: UInt64 = 60_000
let history = 60
let minHistory = 10
let bins = 256

struct Reading {
    var sensor: UInt32
    var quality: UInt32 // 0 = good, 1 = flagged by the device
    var timestamp: UInt64
    var value: Double
}

struct Stats {
    var count: UInt32 = 0
    var sum = 0.0
    var min = Double.infinity
    var max = -Double.infinity
    var sumSq = 0.0
}

/// Uniform double in [0, 1) from the top 53 bits of the PRNG output.
@inline(__always)
func uniform(_ rng: inout SplitMix64) -> Double {
    Double(rng.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
}

/// Interleaved readings from `sensors` devices, each following its own random
/// walk, with timestamps increasing by 1-20 ms and 1% device-flagged spikes.
func generate(_ rng: inout SplitMix64, sensors: Int, readings: Int) -> [Reading] {
    var levels: [Double] = []
    levels.reserveCapacity(sensors)
    for _ in 0..<sensors {
        levels.append(20.0 + 10.0 * uniform(&rng))
    }
    var out: [Reading] = []
    out.reserveCapacity(readings)
    var ts: UInt64 = 0
    for _ in 0..<readings {
        ts += 1 + rng.below(20)
        let s = Int(rng.below(UInt64(sensors)))
        let step = uniform(&rng) * 2.0 - 1.0
        levels[s] += step * 0.1
        let jitter = uniform(&rng) * 2.0 - 1.0
        var value = levels[s] + jitter * 0.5
        var quality: UInt32 = 0
        if rng.below(100) == 0 {
            value += 50.0
            quality = 1
        }
        out.append(Reading(sensor: UInt32(s), quality: quality, timestamp: ts, value: value))
    }
    return out
}

struct Rollup {
    var stats: [Stats] // sensors x windows, row-major
    var windows: Int
    var good: UInt64
    var bad: UInt64
    var min: Double
    var max: Double
}

/// Per-sensor, per-minute count / sum / min / max / sum of squares over the
/// readings the device did not flag.
func rollup(_ readings: [Reading], sensors: Int) -> Rollup {
    let last = readings.last?.timestamp ?? 0
    let windows = Int(last / windowMs) + 1
    var stats = [Stats](repeating: Stats(), count: sensors * windows)
    var good: UInt64 = 0
    var bad: UInt64 = 0
    var gmin = Double.infinity
    var gmax = -Double.infinity
    for r in readings {
        if r.quality != 0 {
            bad += 1
            continue
        }
        good += 1
        let v = r.value
        let w = Int(r.timestamp / windowMs)
        let i = Int(r.sensor) * windows + w
        stats[i].count += 1
        stats[i].sum += v
        if v < stats[i].min {
            stats[i].min = v
        }
        if v > stats[i].max {
            stats[i].max = v
        }
        stats[i].sumSq += v * v
        if v < gmin {
            gmin = v
        }
        if v > gmax {
            gmax = v
        }
    }
    return Rollup(stats: stats, windows: windows, good: good, bad: bad, min: gmin, max: gmax)
}

/// For every sensor, walk the window means in time order and flag a window whose
/// mean lies more than three standard deviations from the trailing `history`
/// windows' means. Returns the anomaly count per sensor.
func anomalies(_ roll: Rollup, sensors: Int) -> [UInt32] {
    let windows = roll.windows
    var counts = [UInt32](repeating: 0, count: sensors)
    var ring = [Double](repeating: 0, count: history)
    for s in 0..<sensors {
        var histSum = 0.0
        var histSq = 0.0
        var ringCount = 0
        var head = 0
        var found: UInt32 = 0
        for w in 0..<windows {
            let st = roll.stats[s * windows + w]
            if st.count == 0 {
                continue
            }
            let mean = st.sum / Double(st.count)
            if ringCount >= minHistory {
                let n = Double(ringCount)
                let mu = histSum / n
                var variance = histSq / n - mu * mu
                if variance < 0.0 {
                    variance = 0.0
                }
                let dev = mean - mu
                if dev * dev > 9.0 * variance {
                    found += 1
                }
            }
            if ringCount == history {
                let old = ring[head]
                histSum -= old
                histSq -= old * old
            } else {
                ringCount += 1
            }
            ring[head] = mean
            histSum += mean
            histSq += mean * mean
            head = (head + 1) % history
        }
        counts[s] = found
    }
    return counts
}

/// 256-bin histogram per sensor over the global value range, then the bin that
/// holds the 50th, 95th and 99th percentile of each sensor's good readings.
func quantiles(_ readings: [Reading], sensors: Int, lo: Double, hi: Double) -> [(UInt8, UInt8, UInt8)] {
    var hist = [UInt32](repeating: 0, count: sensors * bins)
    let scale = hi > lo ? Double(bins - 1) / (hi - lo) : 0.0
    for r in readings {
        if r.quality != 0 {
            continue
        }
        var bin = Int((r.value - lo) * scale)
        if bin > bins - 1 {
            bin = bins - 1
        }
        hist[Int(r.sensor) * bins + bin] += 1
    }
    var out: [(UInt8, UInt8, UInt8)] = []
    out.reserveCapacity(sensors)
    let percentiles: [UInt64] = [50, 95, 99]
    for s in 0..<sensors {
        let base = s * bins
        var total: UInt64 = 0
        for bin in 0..<bins {
            total += UInt64(hist[base + bin])
        }
        var result: [UInt8] = [0, 0, 0]
        for (i, pct) in percentiles.enumerated() {
            let rank = Swift.max((total * pct + 99) / 100, 1)
            var cumulative: UInt64 = 0
            var bin = 0
            while bin < bins - 1 {
                cumulative += UInt64(hist[base + bin])
                if cumulative >= rank {
                    break
                }
                bin += 1
            }
            result[i] = UInt8(bin)
        }
        out.append((result[0], result[1], result[2]))
    }
    return out
}

func run() {
    let args = Args()
    let sensors = max(args.int("sensors", default: 1_000), 1)
    let nReadings = args.int("readings", default: 5_000_000)
    let seed = args.uint64("seed", default: 42)
    let quiet = args.flag("quiet")

    var summary = ""
    let total = Stopwatch()

    var sw = Stopwatch()
    var rng = SplitMix64(seed: seed)
    var readings = generate(&rng, sensors: sensors, readings: nReadings)
    let generateMs = sw.elapsedMs

    sw = Stopwatch()
    var roll = rollup(readings, sensors: sensors)
    let rollupMs = sw.elapsedMs
    summary += "rollup windows=\(roll.windows) good=\(roll.good) bad=\(roll.bad) min=\(hex16(roll.min.bitPattern)) max=\(hex16(roll.max.bitPattern))\n"

    sw = Stopwatch()
    var anomalyCounts = anomalies(roll, sensors: sensors)
    let anomalyMs = sw.elapsedMs
    let anomalyTotal = anomalyCounts.reduce(UInt64(0)) { $0 + UInt64($1) }
    summary += "anomalies total=\(anomalyTotal)\n"

    sw = Stopwatch()
    var percentiles = quantiles(readings, sensors: sensors, lo: roll.min, hi: roll.max)
    let quantileMs = sw.elapsedMs

    // Per-sensor detail, hashed rather than printed.
    var detail = Fnv1a()
    for s in 0..<sensors {
        var sum = 0.0
        var count: UInt64 = 0
        for w in 0..<roll.windows {
            let st = roll.stats[s * roll.windows + w]
            sum += st.sum
            count += UInt64(st.count)
        }
        withUnsafeBytes(of: anomalyCounts[s].littleEndian) { detail.update($0) }
        detail.byte(percentiles[s].0)
        detail.byte(percentiles[s].1)
        detail.byte(percentiles[s].2)
        withUnsafeBytes(of: sum.bitPattern.littleEndian) { detail.update($0) }
        withUnsafeBytes(of: count.littleEndian) { detail.update($0) }
    }
    summary += "sensors=\(sensors) p50/p95/p99[0]=\(percentiles[0].0)/\(percentiles[0].1)/\(percentiles[0].2) detail=\(hex16(detail.value))\n"

    sw = Stopwatch()
    percentiles.removeAll()
    anomalyCounts.removeAll()
    roll.stats.removeAll()
    readings.removeAll()
    let freeMs = sw.elapsedMs

    let totalMs = total.elapsedMs
    var h = Fnv1a()
    h.update(summary.utf8)

    if !quiet {
        print(summary, terminator: "")
    }
    var report = Report(benchmark: "sensor-rollup")
    report.int("sensors", sensors)
    report.int("readings", nReadings)
    report.int("seed", seed)
    report.int("anomalies", anomalyTotal)
    report.ms("generate_ms", generateMs)
    report.ms("rollup_ms", rollupMs)
    report.ms("anomaly_ms", anomalyMs)
    report.ms("quantile_ms", quantileMs)
    report.ms("free_ms", freeMs)
    report.ms("total_ms", totalMs)
    report.text("checksum", hex16(h.value))
    report.emit()
}

run()
