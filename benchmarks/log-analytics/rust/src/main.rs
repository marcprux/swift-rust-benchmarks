//! log-analytics: generate a synthetic structured log, parse every line into a
//! typed record, aggregate per-service / per-user / per-status statistics, then
//! free everything. See ../README.md for the rationale and the knobs.

use benchkit::{fnv1a64, Args, Report, SplitMix64, Stopwatch};
use std::collections::HashMap;
use std::fmt::Write as _;

const SERVICES: &[&str] = &[
    "auth-service",
    "user-profile",
    "payments-gateway",
    "search-indexer",
    "notification-hub",
    "inventory",
    "checkout",
    "recommendations",
];
const METHODS: &[&str] = &["GET", "POST", "PUT", "DELETE"];
const PATHS: &[&str] = &[
    "/api/v1/users",
    "/api/v1/orders",
    "/api/v1/cart",
    "/api/v1/search",
    "/api/v1/products",
    "/healthz",
    "/api/v1/sessions",
    "/api/v1/payments",
];
const OK_STATUSES: &[u16] = &[200, 201, 204];
const WARN_STATUSES: &[u16] = &[400, 401, 403, 404, 429];
const ERROR_STATUSES: &[u16] = &[500, 502, 503, 504];
const WARN_REASONS: &[&str] = &["validation error", "rate limited", "unauthorized", "not found"];
const ERROR_REASONS: &[&str] = &[
    "upstream timeout",
    "connection reset",
    "database unavailable",
    "internal error",
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Level {
    Debug,
    Info,
    Warn,
    Error,
}

impl Level {
    fn name(self) -> &'static str {
        match self {
            Level::Debug => "DEBUG",
            Level::Info => "INFO",
            Level::Warn => "WARN",
            Level::Error => "ERROR",
        }
    }

    fn parse(s: &str) -> Option<Level> {
        match s {
            "INFO" => Some(Level::Info),
            "WARN" => Some(Level::Warn),
            "ERROR" => Some(Level::Error),
            "DEBUG" => Some(Level::Debug),
            _ => None,
        }
    }
}

/// One parsed log line. Owns its strings, as a parser that lets the raw text be
/// discarded afterwards would.
struct LogRecord {
    timestamp_ms: u64,
    level: Level,
    service: String,
    request_id: u64,
    user: String,
    latency_ms: u32,
    status: u16,
    message: String,
}

// ---- calendar helpers (Howard Hinnant's algorithms) -----------------------------

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Appends `YYYY-MM-DDTHH:MM:SS.mmmZ`.
fn format_timestamp(ms: u64, out: &mut String) {
    let days = (ms / 86_400_000) as i64;
    let mut rem = ms % 86_400_000;
    let (y, mo, d) = civil_from_days(days);
    let h = rem / 3_600_000;
    rem %= 3_600_000;
    let mi = rem / 60_000;
    rem %= 60_000;
    let s = rem / 1000;
    let milli = rem % 1000;
    write!(out, "{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{milli:03}Z").unwrap();
}

/// Parses `YYYY-MM-DDTHH:MM:SS.mmmZ` back into milliseconds since the epoch.
fn parse_timestamp(b: &[u8]) -> Option<u64> {
    if b.len() != 24 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':'
        || b[16] != b':' || b[19] != b'.' || b[23] != b'Z'
    {
        return None;
    }
    let num = |range: std::ops::Range<usize>| -> Option<i64> {
        let mut v: i64 = 0;
        for &c in &b[range] {
            if !c.is_ascii_digit() {
                return None;
            }
            v = v * 10 + (c - b'0') as i64;
        }
        Some(v)
    };
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, s, milli) = (num(11..13)?, num(14..16)?, num(17..19)?, num(20..23)?);
    let days = days_from_civil(y, mo, d);
    Some((days * 86_400_000 + h * 3_600_000 + mi * 60_000 + s * 1000 + milli) as u64)
}

// ---- phase 1: generate ------------------------------------------------------------

/// Produces the whole log as one contiguous text buffer, exactly as it would look
/// after reading a log file into memory.
fn generate(lines: usize, seed: u64) -> String {
    let mut rng = SplitMix64::new(seed);
    let mut text = String::with_capacity(lines * 170);
    let mut ts: u64 = 1_710_505_696_789;
    for _ in 0..lines {
        ts += rng.below(50);
        let level = match rng.below(100) {
            0..=79 => Level::Info,
            80..=91 => Level::Warn,
            92..=97 => Level::Error,
            _ => Level::Debug,
        };
        let service = SERVICES[rng.below(SERVICES.len() as u64) as usize];
        let request_id = rng.next_u64();
        let user = rng.below(50_000);
        let method = METHODS[rng.below(METHODS.len() as u64) as usize];
        let path = PATHS[rng.below(PATHS.len() as u64) as usize];
        let resource = rng.below(1_000_000);
        let status_roll = rng.next_u64();
        let latency_roll = rng.next_u64();
        let reason_roll = rng.next_u64();

        let (status, latency, message) = match level {
            Level::Error => (
                ERROR_STATUSES[(status_roll % ERROR_STATUSES.len() as u64) as usize],
                500 + (latency_roll % 1500) as u32,
                format!(
                    "{method} {path}/{resource} failed: {}",
                    ERROR_REASONS[(reason_roll % ERROR_REASONS.len() as u64) as usize]
                ),
            ),
            Level::Warn => (
                WARN_STATUSES[(status_roll % WARN_STATUSES.len() as u64) as usize],
                100 + (latency_roll % 400) as u32,
                format!(
                    "{method} {path}/{resource} rejected: {}",
                    WARN_REASONS[(reason_roll % WARN_REASONS.len() as u64) as usize]
                ),
            ),
            _ => (
                OK_STATUSES[(status_roll % OK_STATUSES.len() as u64) as usize],
                (latency_roll % 250) as u32,
                format!("{method} {path}/{resource} completed"),
            ),
        };

        format_timestamp(ts, &mut text);
        writeln!(
            text,
            " level={} service={service} request_id={request_id:016x} user=u{user} latency_ms={latency} status={status} msg=\"{message}\"",
            level.name()
        )
        .unwrap();
    }
    text
}

// ---- phase 2: parse ---------------------------------------------------------------

/// Parses one line (a borrowed slice of the text buffer) into an owned record.
fn parse_line(line: &str) -> Option<LogRecord> {
    let msg_pos = line.find("msg=\"")?;
    let message = line[msg_pos + 5..].strip_suffix('"')?;
    let head = &line[..msg_pos];

    let mut tokens = head.split(' ').filter(|t| !t.is_empty());
    let timestamp_ms = parse_timestamp(tokens.next()?.as_bytes())?;

    let mut level = None;
    let mut service = None;
    let mut request_id = None;
    let mut user = None;
    let mut latency_ms = None;
    let mut status = None;
    for token in tokens {
        let (key, value) = token.split_once('=')?;
        match key {
            "level" => level = Level::parse(value),
            "service" => service = Some(value.to_owned()),
            "request_id" => request_id = u64::from_str_radix(value, 16).ok(),
            "user" => user = Some(value.to_owned()),
            "latency_ms" => latency_ms = value.parse().ok(),
            "status" => status = value.parse().ok(),
            _ => {}
        }
    }
    Some(LogRecord {
        timestamp_ms,
        level: level?,
        service: service?,
        request_id: request_id?,
        user: user?,
        latency_ms: latency_ms?,
        status: status?,
        message: message.to_owned(),
    })
}

// ---- phase 3: aggregate -----------------------------------------------------------

#[derive(Default)]
struct ServiceStats {
    count: u64,
    errors: u64,
    latency_sum: u64,
    latencies: Vec<u32>,
}

impl ServiceStats {
    fn record(&mut self, r: &LogRecord) {
        self.count += 1;
        if r.status >= 500 {
            self.errors += 1;
        }
        self.latency_sum += r.latency_ms as u64;
        self.latencies.push(r.latency_ms);
    }
}

/// Returns the canonical textual summary and its checksum. The maps borrow their
/// keys straight out of the records: no copies, no reference counts.
fn aggregate(records: &[LogRecord]) -> (String, u64) {
    let mut by_service: HashMap<&str, ServiceStats> = HashMap::new();
    let mut by_user: HashMap<&str, u32> = HashMap::new();
    let mut by_status: HashMap<u16, u64> = HashMap::new();
    let mut first_ts = u64::MAX;
    let mut last_ts = 0u64;
    let mut debug_lines = 0u64;
    let mut message_bytes = 0u64;
    let mut request_xor = 0u64;

    for r in records {
        message_bytes += r.message.len() as u64;
        request_xor ^= r.request_id;
        by_service.entry(r.service.as_str()).or_default().record(r);
        *by_user.entry(r.user.as_str()).or_insert(0) += 1;
        *by_status.entry(r.status).or_insert(0) += 1;
        first_ts = first_ts.min(r.timestamp_ms);
        last_ts = last_ts.max(r.timestamp_ms);
        if r.level == Level::Debug {
            debug_lines += 1;
        }
    }

    let mut summary = String::new();
    writeln!(
        summary,
        "window {}..{} records={} debug={} message_bytes={} request_xor={:016x}",
        first_ts,
        last_ts,
        records.len(),
        debug_lines,
        message_bytes,
        request_xor
    )
    .unwrap();

    let mut names: Vec<&str> = by_service.keys().copied().collect();
    names.sort_unstable();
    for name in names {
        let s = by_service.get_mut(name).unwrap();
        s.latencies.sort_unstable();
        let p50 = s.latencies[s.latencies.len() / 2];
        let p99 = s.latencies[s.latencies.len() * 99 / 100];
        writeln!(
            summary,
            "service {name} count={} errors={} avg_ms={} p50_ms={p50} p99_ms={p99}",
            s.count,
            s.errors,
            s.latency_sum / s.count
        )
        .unwrap();
    }

    let mut users: Vec<(&str, u32)> = by_user.into_iter().collect();
    users.sort_unstable_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    for (user, count) in users.iter().take(10) {
        writeln!(summary, "user {user} count={count}").unwrap();
    }

    let mut statuses: Vec<(u16, u64)> = by_status.into_iter().collect();
    statuses.sort_unstable();
    for (status, count) in statuses {
        writeln!(summary, "status {status} count={count}").unwrap();
    }

    let checksum = fnv1a64(summary.as_bytes());
    (summary, checksum)
}

fn main() {
    let args = Args::parse();
    let lines = args.usize("lines", 500_000);
    let seed = args.u64("seed", 42);
    let quiet = args.flag("quiet");

    let total = Stopwatch::start();

    let sw = Stopwatch::start();
    let text = generate(lines, seed);
    let generate_ms = sw.elapsed_ms();
    let raw_bytes = text.len();

    let sw = Stopwatch::start();
    let mut records = Vec::with_capacity(lines);
    let mut parse_failures = 0u64;
    for line in text.lines() {
        match parse_line(line) {
            Some(r) => records.push(r),
            None => parse_failures += 1,
        }
    }
    let parse_ms = sw.elapsed_ms();

    let sw = Stopwatch::start();
    let (summary, checksum) = aggregate(&records);
    let aggregate_ms = sw.elapsed_ms();

    let sw = Stopwatch::start();
    drop(records);
    drop(text);
    let free_ms = sw.elapsed_ms();

    let total_ms = total.elapsed_ms();

    if !quiet {
        print!("{summary}");
    }
    Report::new("log-analytics")
        .int("lines", lines as u64)
        .int("seed", seed)
        .int("raw_bytes", raw_bytes as u64)
        .int("parse_failures", parse_failures)
        .ms("generate_ms", generate_ms)
        .ms("parse_ms", parse_ms)
        .ms("aggregate_ms", aggregate_ms)
        .ms("free_ms", free_ms)
        .ms("total_ms", total_ms)
        .text("checksum", &format!("{checksum:016x}"))
        .emit();
}
