// Dependency-free support code shared by the Swift side of every benchmark.
//
// The Rust crate at `common/rust/benchkit` is a line-for-line mirror of this
// module so that both sides of a benchmark pair measure and report identically.
// Deliberately avoids Foundation so that the measurements reflect the Swift
// standard library and runtime alone. The companion CBenchKit target holds the
// two OS-specific primitives (peak RSS and stderr output) as C, the Swift
// equivalent of the `extern "C"` block in the Rust crate.

import CBenchKit

/// SplitMix64: a tiny, fast, deterministic PRNG. Both languages implement the
/// exact same sequence so that a given seed produces identical workloads.
public struct SplitMix64 {
    @usableFromInline var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    @inlinable @inline(__always)
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform-ish integer in `0..<n` (modulo bias is irrelevant here; what
    /// matters is that Swift and Rust agree).
    @inlinable @inline(__always)
    public mutating func below(_ n: UInt64) -> UInt64 {
        next() % n
    }
}

/// 64-bit FNV-1a, used to turn a canonical textual summary into a checksum that
/// the harness compares across languages.
public func fnv1a64<C: Sequence>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for b in bytes {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01B3
    }
    return h
}

/// Streaming FNV-1a for hashing structures without first rendering them to text.
public struct Fnv1a {
    @usableFromInline var state: UInt64 = 0xCBF2_9CE4_8422_2325

    public init() {}

    @inlinable @inline(__always)
    public mutating func byte(_ b: UInt8) {
        state ^= UInt64(b)
        state = state &* 0x0000_0100_0000_01B3
    }

    @inlinable
    public mutating func update<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes { byte(b) }
    }

    public var value: UInt64 { state }
}

/// Minimal `--key value` / `--key=value` / `--flag` command-line parser.
public struct Args {
    private var values: [String: String] = [:]

    public init(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            guard arg.hasPrefix("--") else {
                print("ignoring unexpected argument `\(arg)`", to: &standardError)
                continue
            }
            let key = String(arg.dropFirst(2))
            if let eq = key.firstIndex(of: "=") {
                values[String(key[..<eq])] = String(key[key.index(after: eq)...])
            } else if index < arguments.count, !arguments[index].hasPrefix("--") {
                values[key] = arguments[index]
                index += 1
            } else {
                values[key] = "true"
            }
        }
    }

    public func uint64(_ key: String, default defaultValue: UInt64) -> UInt64 {
        guard let raw = values[key] else { return defaultValue }
        guard let value = UInt64(raw.replacing("_", with: "")) else {
            fatalError("--\(key) expects an integer, got `\(raw)`")
        }
        return value
    }

    public func int(_ key: String, default defaultValue: Int) -> Int {
        Int(uint64(key, default: UInt64(defaultValue)))
    }

    public func flag(_ key: String) -> Bool {
        values[key] == "true"
    }
}

/// Wall-clock stopwatch with millisecond readout.
public struct Stopwatch {
    private let start: ContinuousClock.Instant

    public init() {
        start = ContinuousClock.now
    }

    public var elapsedMs: Double {
        let d = start.duration(to: ContinuousClock.now)
        let (seconds, attoseconds) = d.components
        return Double(seconds) * 1000.0 + Double(attoseconds) / 1e15
    }
}

/// Peak resident set size of the current process, in bytes (0 if unavailable).
/// Implemented in the CBenchKit target (`getrusage` / `GetProcessMemoryInfo`).
public func peakRSSBytes() -> UInt64 {
    benchkit_peak_rss_bytes()
}

/// Number of hardware threads the process may use (at least 1).
public func availableParallelism() -> Int {
    max(Int(benchkit_cpu_count()), 1)
}

/// Collects the benchmark's measurements and prints them as a single JSON line.
/// The harness reads the last line of stdout that starts with `{`.
public struct Report {
    private var fields: [(String, String)] = []

    public init(benchmark: String) {
        text("benchmark", benchmark)
        text("language", "swift")
    }

    @discardableResult
    public mutating func int(_ key: String, _ value: UInt64) -> Self {
        fields.append((key, String(value)))
        return self
    }

    @discardableResult
    public mutating func int(_ key: String, _ value: Int) -> Self {
        fields.append((key, String(value)))
        return self
    }

    @discardableResult
    public mutating func ms(_ key: String, _ value: Double) -> Self {
        fields.append((key, formatFixed(value, decimals: 3)))
        return self
    }

    /// A non-timing floating-point value (a ratio, a rate), three decimals.
    @discardableResult
    public mutating func num(_ key: String, _ value: Double) -> Self {
        fields.append((key, formatFixed(value, decimals: 3)))
        return self
    }

    @discardableResult
    public mutating func text(_ key: String, _ value: String) -> Self {
        let escaped = value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        fields.append((key, "\"\(escaped)\""))
        return self
    }

    /// Appends the peak RSS and prints the JSON line.
    public mutating func emit() {
        int("peak_rss_bytes", peakRSSBytes())
        let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        print("{\(body)}")
    }
}

/// Formats a Double with a fixed number of decimals without Foundation (and
/// without libm: `rounded()` would require linking `-lm` on Linux).
public func formatFixed(_ value: Double, decimals: Int) -> String {
    var scale: Int64 = 1
    for _ in 0..<decimals { scale *= 10 }
    let magnitude = value < 0 ? -value : value
    let scaled = Int64(magnitude * Double(scale) + 0.5)
    let whole = scaled / scale
    let frac = scaled % scale
    var fracText = String(frac)
    while fracText.count < decimals { fracText = "0" + fracText }
    let sign = value < 0 && scaled > 0 ? "-" : ""
    return decimals == 0 ? "\(sign)\(whole)" : "\(sign)\(whole).\(fracText)"
}

/// Zero-padded hexadecimal rendering of a 64-bit value.
public func hex16(_ value: UInt64) -> String {
    var s = ""
    appendHex16(value, to: &s)
    return s
}

/// Appends exactly 16 lowercase hex digits to `s` without any intermediate allocation.
public func appendHex16(_ value: UInt64, to s: inout String) {
    let digits: StaticString = "0123456789abcdef"
    for shift in stride(from: 60, through: 0, by: -4) {
        let nibble = Int((value >> UInt64(shift)) & 0xF)
        s.unicodeScalars.append(Unicode.Scalar(digits.utf8Start[nibble]))
    }
}

/// `print(_:to:)` target for stderr.
public struct StandardError: TextOutputStream {
    public init() {}
    public mutating func write(_ string: String) {
        var s = string
        s.withUTF8 { buf in
            guard let base = buf.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                benchkit_write_stderr($0, buf.count)
            }
        }
    }
}

nonisolated(unsafe) public var standardError = StandardError()
