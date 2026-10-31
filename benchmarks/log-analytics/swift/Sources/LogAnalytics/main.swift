// log-analytics: generate a synthetic structured log, parse every line into a
// typed record, aggregate per-service / per-user / per-status statistics, then
// free everything. See ../README.md for the rationale and the knobs.

import BenchKit

let services = [
    "auth-service",
    "user-profile",
    "payments-gateway",
    "search-indexer",
    "notification-hub",
    "inventory",
    "checkout",
    "recommendations",
]
let methods = ["GET", "POST", "PUT", "DELETE"]
let paths = [
    "/api/v1/users",
    "/api/v1/orders",
    "/api/v1/cart",
    "/api/v1/search",
    "/api/v1/products",
    "/healthz",
    "/api/v1/sessions",
    "/api/v1/payments",
]
let okStatuses: [UInt16] = [200, 201, 204]
let warnStatuses: [UInt16] = [400, 401, 403, 404, 429]
let errorStatuses: [UInt16] = [500, 502, 503, 504]
let warnReasons = ["validation error", "rate limited", "unauthorized", "not found"]
let errorReasons = ["upstream timeout", "connection reset", "database unavailable", "internal error"]

enum Level: UInt8 {
    case debug, info, warn, error

    var name: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warn: "WARN"
        case .error: "ERROR"
        }
    }

    init?<C: Collection>(utf8 bytes: C) where C.Element == UInt8 {
        if bytes.elementsEqual("INFO".utf8) {
            self = .info
        } else if bytes.elementsEqual("WARN".utf8) {
            self = .warn
        } else if bytes.elementsEqual("ERROR".utf8) {
            self = .error
        } else if bytes.elementsEqual("DEBUG".utf8) {
            self = .debug
        } else {
            return nil
        }
    }
}

/// One parsed log line. Owns its strings, as a parser that lets the raw text be
/// discarded afterwards would.
struct LogRecord {
    var timestampMs: UInt64
    var level: Level
    var service: String
    var requestID: UInt64
    var user: String
    var latencyMs: UInt32
    var status: UInt16
    var message: String
}

// ---- calendar helpers (Howard Hinnant's algorithms) -----------------------------

func civilFromDays(_ z0: Int64) -> (Int64, Int64, Int64) {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
}

func daysFromCivil(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
    let y = m <= 2 ? y0 - 1 : y0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

/// Appends exactly `width` decimal digits (zero padded) without allocating.
@inline(__always)
func appendFixedDigits(_ value: Int64, width: Int, to s: inout String) {
    var divisor: Int64 = 1
    for _ in 1..<width { divisor *= 10 }
    var v = value
    while divisor > 0 {
        s.unicodeScalars.append(Unicode.Scalar(UInt8(48 + v / divisor)))
        v %= divisor
        divisor /= 10
    }
}

/// Appends `YYYY-MM-DDTHH:MM:SS.mmmZ`.
func formatTimestamp(_ ms: UInt64, into s: inout String) {
    let days = Int64(ms / 86_400_000)
    var rem = Int64(ms % 86_400_000)
    let (y, mo, d) = civilFromDays(days)
    let h = rem / 3_600_000
    rem %= 3_600_000
    let mi = rem / 60_000
    rem %= 60_000
    let sec = rem / 1000
    let milli = rem % 1000
    appendFixedDigits(y, width: 4, to: &s)
    s += "-"
    appendFixedDigits(mo, width: 2, to: &s)
    s += "-"
    appendFixedDigits(d, width: 2, to: &s)
    s += "T"
    appendFixedDigits(h, width: 2, to: &s)
    s += ":"
    appendFixedDigits(mi, width: 2, to: &s)
    s += ":"
    appendFixedDigits(sec, width: 2, to: &s)
    s += "."
    appendFixedDigits(milli, width: 3, to: &s)
    s += "Z"
}

/// Parses `YYYY-MM-DDTHH:MM:SS.mmmZ` back into milliseconds since the epoch.
func parseTimestamp<C: Collection>(_ bytes: C) -> UInt64? where C.Element == UInt8 {
    guard bytes.count == 24 else { return nil }
    var it = bytes.makeIterator()
    func num(_ digits: Int) -> Int64? {
        var v: Int64 = 0
        for _ in 0..<digits {
            guard let c = it.next(), c >= 48, c <= 57 else { return nil }
            v = v * 10 + Int64(c - 48)
        }
        return v
    }
    func expect(_ c: UInt8) -> Bool { it.next() == c }

    guard let y = num(4), expect(UInt8(ascii: "-")),
          let mo = num(2), expect(UInt8(ascii: "-")),
          let d = num(2), expect(UInt8(ascii: "T")),
          let h = num(2), expect(UInt8(ascii: ":")),
          let mi = num(2), expect(UInt8(ascii: ":")),
          let s = num(2), expect(UInt8(ascii: ".")),
          let milli = num(3), expect(UInt8(ascii: "Z"))
    else { return nil }
    let days = daysFromCivil(y, mo, d)
    return UInt64(days * 86_400_000 + h * 3_600_000 + mi * 60_000 + s * 1000 + milli)
}

/// Parses a run of ASCII digits.
@inline(__always)
func parseUInt<C: Collection>(_ bytes: C) -> UInt64? where C.Element == UInt8 {
    guard !bytes.isEmpty else { return nil }
    var v: UInt64 = 0
    for c in bytes {
        guard c >= 48, c <= 57 else { return nil }
        v = v &* 10 &+ UInt64(c - 48)
    }
    return v
}

/// Parses lowercase/uppercase hexadecimal digits.
@inline(__always)
func parseHex<C: Collection>(_ bytes: C) -> UInt64? where C.Element == UInt8 {
    guard !bytes.isEmpty else { return nil }
    var v: UInt64 = 0
    for c in bytes {
        let digit: UInt64
        switch c {
        case 48...57: digit = UInt64(c - 48)
        case 97...102: digit = UInt64(c - 87)
        case 65...70: digit = UInt64(c - 55)
        default: return nil
        }
        v = v &* 16 &+ digit
    }
    return v
}

// ---- phase 1: generate ------------------------------------------------------------

/// Produces the whole log as one contiguous text buffer, exactly as it would look
/// after reading a log file into memory.
func generate(lines: Int, seed: UInt64) -> String {
    var rng = SplitMix64(seed: seed)
    var text = ""
    text.reserveCapacity(lines * 170)
    var ts: UInt64 = 1_710_505_696_789
    for _ in 0..<lines {
        ts += rng.below(50)
        let levelRoll = rng.below(100)
        let level: Level = levelRoll < 80 ? .info : levelRoll < 92 ? .warn : levelRoll < 98 ? .error : .debug
        let service = services[Int(rng.below(UInt64(services.count)))]
        let requestID = rng.next()
        let user = rng.below(50_000)
        let method = methods[Int(rng.below(UInt64(methods.count)))]
        let path = paths[Int(rng.below(UInt64(paths.count)))]
        let resource = rng.below(1_000_000)
        let statusRoll = rng.next()
        let latencyRoll = rng.next()
        let reasonRoll = rng.next()

        let status: UInt16
        let latency: UInt32
        let message: String
        switch level {
        case .error:
            status = errorStatuses[Int(statusRoll % UInt64(errorStatuses.count))]
            latency = 500 + UInt32(latencyRoll % 1500)
            message = "\(method) \(path)/\(resource) failed: \(errorReasons[Int(reasonRoll % UInt64(errorReasons.count))])"
        case .warn:
            status = warnStatuses[Int(statusRoll % UInt64(warnStatuses.count))]
            latency = 100 + UInt32(latencyRoll % 400)
            message = "\(method) \(path)/\(resource) rejected: \(warnReasons[Int(reasonRoll % UInt64(warnReasons.count))])"
        default:
            status = okStatuses[Int(statusRoll % UInt64(okStatuses.count))]
            latency = UInt32(latencyRoll % 250)
            message = "\(method) \(path)/\(resource) completed"
        }

        formatTimestamp(ts, into: &text)
        text += " level="
        text += level.name
        text += " service="
        text += service
        text += " request_id="
        appendHex16(requestID, to: &text)
        text += " user=u"
        text += String(user)
        text += " latency_ms="
        text += String(latency)
        text += " status="
        text += String(status)
        text += " msg=\""
        text += message
        text += "\"\n"
    }
    return text
}

// ---- phase 2: parse ---------------------------------------------------------------

/// Splits a UTF-8 slice on a separator byte without allocating an array of
/// tokens (the equivalent of Rust's lazy `str::split` / `str::lines`). Empty
/// tokens are skipped.
struct ByteTokenizer {
    var remaining: Substring.UTF8View
    let separator: UInt8

    mutating func next() -> Substring.UTF8View? {
        while let first = remaining.first, first == separator {
            remaining = remaining.dropFirst()
        }
        if remaining.isEmpty { return nil }
        let end = remaining.firstIndex(of: separator) ?? remaining.endIndex
        let token = remaining[remaining.startIndex..<end]
        remaining = remaining[end...]
        return token
    }
}

/// Finds the first occurrence of `needle` in a UTF-8 view by plain byte scanning,
/// which is what Rust's `str::find` does. Swift's generic
/// `Collection.firstRange(of:)` was measured at ~160x slower on this input
/// (see ../README.md), so it is deliberately not used here.
func findBytes(_ needle: StaticString, in haystack: Substring.UTF8View) -> Range<String.Index>? {
    let first = needle.utf8Start[0]
    let count = needle.utf8CodeUnitCount
    var i = haystack.startIndex
    while i != haystack.endIndex {
        if haystack[i] == first {
            var j = i
            var k = 0
            while k < count, j != haystack.endIndex, haystack[j] == needle.utf8Start[k] {
                j = haystack.index(after: j)
                k += 1
            }
            if k == count { return i..<j }
        }
        i = haystack.index(after: i)
    }
    return nil
}

/// Parses one line (a view into the text buffer) into an owned record.
func parseLine(_ utf8: Substring.UTF8View) -> LogRecord? {
    guard let msgRange = findBytes("msg=\"", in: utf8),
          utf8.last == UInt8(ascii: "\"")
    else { return nil }
    let message = String(decoding: utf8[msgRange.upperBound..<utf8.index(before: utf8.endIndex)], as: UTF8.self)
    let head = utf8[utf8.startIndex..<msgRange.lowerBound]

    var tokens = ByteTokenizer(remaining: head, separator: UInt8(ascii: " "))
    guard let first = tokens.next(), let timestampMs = parseTimestamp(first) else { return nil }

    var level: Level?
    var service: String?
    var requestID: UInt64?
    var user: String?
    var latencyMs: UInt32?
    var status: UInt16?
    while let token = tokens.next() {
        guard let eq = token.firstIndex(of: UInt8(ascii: "=")) else { return nil }
        let key = token[token.startIndex..<eq]
        let value = token[token.index(after: eq)...]
        if key.elementsEqual("level".utf8) {
            level = Level(utf8: value)
        } else if key.elementsEqual("service".utf8) {
            service = String(decoding: value, as: UTF8.self)
        } else if key.elementsEqual("request_id".utf8) {
            requestID = parseHex(value)
        } else if key.elementsEqual("user".utf8) {
            user = String(decoding: value, as: UTF8.self)
        } else if key.elementsEqual("latency_ms".utf8) {
            latencyMs = parseUInt(value).flatMap { UInt32(exactly: $0) }
        } else if key.elementsEqual("status".utf8) {
            status = parseUInt(value).flatMap { UInt16(exactly: $0) }
        }
    }
    guard let level, let service, let requestID, let user, let latencyMs, let status else { return nil }
    return LogRecord(
        timestampMs: timestampMs,
        level: level,
        service: service,
        requestID: requestID,
        user: user,
        latencyMs: latencyMs,
        status: status,
        message: message
    )
}

// ---- phase 3: aggregate -----------------------------------------------------------

struct ServiceStats {
    var count: UInt64 = 0
    var errors: UInt64 = 0
    var latencySum: UInt64 = 0
    var latencies: [UInt32] = []

    mutating func record(_ r: LogRecord) {
        count += 1
        if r.status >= 500 { errors += 1 }
        latencySum += UInt64(r.latencyMs)
        latencies.append(r.latencyMs)
    }
}

/// Returns the canonical textual summary and its checksum. The dictionary keys
/// share storage with the record strings (a retain each, no copy).
func aggregate(_ records: [LogRecord]) -> (summary: String, checksum: UInt64) {
    var byService: [String: ServiceStats] = [:]
    var byUser: [String: UInt32] = [:]
    var byStatus: [UInt16: UInt64] = [:]
    var firstTs = UInt64.max
    var lastTs: UInt64 = 0
    var debugLines: UInt64 = 0
    var messageBytes: UInt64 = 0
    var requestXor: UInt64 = 0

    for r in records {
        messageBytes += UInt64(r.message.utf8.count)
        requestXor ^= r.requestID
        byService[r.service, default: ServiceStats()].record(r)
        byUser[r.user, default: 0] += 1
        byStatus[r.status, default: 0] += 1
        firstTs = min(firstTs, r.timestampMs)
        lastTs = max(lastTs, r.timestampMs)
        if r.level == .debug { debugLines += 1 }
    }

    var summary = ""
    summary += "window \(firstTs)..\(lastTs) records=\(records.count) debug=\(debugLines) message_bytes=\(messageBytes) request_xor=\(hex16(requestXor))\n"

    for name in byService.keys.sorted() {
        byService[name]!.latencies.sort()
        let s = byService[name]!
        let p50 = s.latencies[s.latencies.count / 2]
        let p99 = s.latencies[s.latencies.count * 99 / 100]
        summary += "service \(name) count=\(s.count) errors=\(s.errors) avg_ms=\(s.latencySum / s.count) p50_ms=\(p50) p99_ms=\(p99)\n"
    }

    let users = byUser.sorted { a, b in
        a.value != b.value ? a.value > b.value : a.key < b.key
    }
    for (user, count) in users.prefix(10) {
        summary += "user \(user) count=\(count)\n"
    }

    for status in byStatus.keys.sorted() {
        summary += "status \(status) count=\(byStatus[status]!)\n"
    }

    return (summary, fnv1a64(summary.utf8))
}

// ---- main -------------------------------------------------------------------------

let args = Args()
let lineCount = args.int("lines", default: 500_000)
let seed = args.uint64("seed", default: 42)
let quiet = args.flag("quiet")

let total = Stopwatch()

var sw = Stopwatch()
var text = generate(lines: lineCount, seed: seed)
let generateMs = sw.elapsedMs
let rawBytes = text.utf8.count

sw = Stopwatch()
var records: [LogRecord] = []
records.reserveCapacity(lineCount)
var parseFailures = 0
do {
    // Scoped so that the tokenizer's view of `text` is gone before the free phase.
    var lines = ByteTokenizer(remaining: text.utf8[...], separator: UInt8(ascii: "\n"))
    while let line = lines.next() {
        if let r = parseLine(line) {
            records.append(r)
        } else {
            parseFailures += 1
        }
    }
}
let parseMs = sw.elapsedMs

sw = Stopwatch()
let (summary, checksum) = aggregate(records)
let aggregateMs = sw.elapsedMs

sw = Stopwatch()
records.removeAll()
text.removeAll()
let freeMs = sw.elapsedMs

let totalMs = total.elapsedMs

if !quiet {
    print(summary, terminator: "")
}
var report = Report(benchmark: "log-analytics")
report.int("lines", lineCount)
report.int("seed", seed)
report.int("raw_bytes", rawBytes)
report.int("parse_failures", parseFailures)
report.ms("generate_ms", generateMs)
report.ms("parse_ms", parseMs)
report.ms("aggregate_ms", aggregateMs)
report.ms("free_ms", freeMs)
report.ms("total_ms", totalMs)
report.text("checksum", hex16(checksum))
report.emit()
