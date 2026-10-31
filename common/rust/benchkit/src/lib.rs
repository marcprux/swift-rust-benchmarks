//! Dependency-free support code shared by the Rust side of every benchmark.
//!
//! The Swift package at `common/swift/BenchKit` is a line-for-line mirror of this
//! module so that both sides of a benchmark pair measure and report identically.

use std::collections::HashMap;
use std::time::Instant;

/// SplitMix64: a tiny, fast, deterministic PRNG. Both languages implement the
/// exact same sequence so that a given seed produces identical workloads.
pub struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    #[inline]
    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform-ish integer in `0..n` (modulo bias is irrelevant here; what
    /// matters is that Swift and Rust agree).
    #[inline]
    pub fn below(&mut self, n: u64) -> u64 {
        self.next_u64() % n
    }
}

/// 64-bit FNV-1a, used to turn a canonical textual summary into a checksum that
/// the harness compares across languages.
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xCBF2_9CE4_8422_2325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01B3);
    }
    h
}

/// Minimal `--key value` / `--key=value` / `--flag` command-line parser.
pub struct Args {
    values: HashMap<String, String>,
}

impl Args {
    pub fn parse() -> Self {
        let mut values = HashMap::new();
        let mut it = std::env::args().skip(1).peekable();
        while let Some(arg) = it.next() {
            let Some(key) = arg.strip_prefix("--") else {
                eprintln!("ignoring unexpected argument `{arg}`");
                continue;
            };
            if let Some((k, v)) = key.split_once('=') {
                values.insert(k.to_string(), v.to_string());
            } else if it.peek().map_or(false, |next| !next.starts_with("--")) {
                values.insert(key.to_string(), it.next().unwrap());
            } else {
                values.insert(key.to_string(), "true".to_string());
            }
        }
        Self { values }
    }

    pub fn u64(&self, key: &str, default: u64) -> u64 {
        match self.values.get(key) {
            None => default,
            Some(v) => v
                .replace('_', "")
                .parse()
                .unwrap_or_else(|_| panic!("--{key} expects an integer, got `{v}`")),
        }
    }

    pub fn usize(&self, key: &str, default: usize) -> usize {
        self.u64(key, default as u64) as usize
    }

    pub fn flag(&self, key: &str) -> bool {
        self.values.get(key).map_or(false, |v| v == "true")
    }
}

/// Wall-clock stopwatch with millisecond readout.
pub struct Stopwatch(Instant);

impl Stopwatch {
    pub fn start() -> Self {
        Self(Instant::now())
    }

    pub fn elapsed_ms(&self) -> f64 {
        self.0.elapsed().as_secs_f64() * 1000.0
    }
}

/// Peak resident set size of the current process, in bytes (0 if unavailable).
pub fn peak_rss_bytes() -> u64 {
    sys::peak_rss_bytes()
}

#[cfg(unix)]
mod sys {
    #[repr(C)]
    struct Timeval {
        tv_sec: i64,
        tv_usec: i64, // i32 + padding on macOS, i64 on Linux: same 16-byte layout
    }

    #[repr(C)]
    struct Rusage {
        ru_utime: Timeval,
        ru_stime: Timeval,
        ru_maxrss: i64,
        ru_ixrss: i64,
        ru_idrss: i64,
        ru_isrss: i64,
        ru_minflt: i64,
        ru_majflt: i64,
        ru_nswap: i64,
        ru_inblock: i64,
        ru_oublock: i64,
        ru_msgsnd: i64,
        ru_msgrcv: i64,
        ru_nsignals: i64,
        ru_nvcsw: i64,
        ru_nivcsw: i64,
    }

    extern "C" {
        fn getrusage(who: i32, usage: *mut Rusage) -> i32;
    }

    pub fn peak_rss_bytes() -> u64 {
        let mut usage = std::mem::MaybeUninit::<Rusage>::zeroed();
        // RUSAGE_SELF == 0 on every supported platform.
        let rc = unsafe { getrusage(0, usage.as_mut_ptr()) };
        if rc != 0 {
            return 0;
        }
        let maxrss = unsafe { usage.assume_init().ru_maxrss } as u64;
        if cfg!(target_os = "macos") {
            maxrss // bytes
        } else {
            maxrss * 1024 // kilobytes
        }
    }
}

#[cfg(windows)]
mod sys {
    use std::ffi::c_void;

    #[repr(C)]
    struct ProcessMemoryCounters {
        cb: u32,
        page_fault_count: u32,
        peak_working_set_size: usize,
        working_set_size: usize,
        quota_peak_paged_pool_usage: usize,
        quota_paged_pool_usage: usize,
        quota_peak_non_paged_pool_usage: usize,
        quota_non_paged_pool_usage: usize,
        pagefile_usage: usize,
        peak_pagefile_usage: usize,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> *mut c_void;
        fn K32GetProcessMemoryInfo(
            process: *mut c_void,
            counters: *mut ProcessMemoryCounters,
            cb: u32,
        ) -> i32;
    }

    pub fn peak_rss_bytes() -> u64 {
        let mut pmc = std::mem::MaybeUninit::<ProcessMemoryCounters>::zeroed();
        let cb = std::mem::size_of::<ProcessMemoryCounters>() as u32;
        let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), pmc.as_mut_ptr(), cb) };
        if ok == 0 {
            return 0;
        }
        unsafe { pmc.assume_init().peak_working_set_size as u64 }
    }
}

#[cfg(not(any(unix, windows)))]
mod sys {
    pub fn peak_rss_bytes() -> u64 {
        0
    }
}

/// Collects the benchmark's measurements and prints them as a single JSON line.
/// The harness reads the last line of stdout that starts with `{`.
pub struct Report {
    fields: Vec<(String, String)>,
}

impl Report {
    pub fn new(benchmark: &str) -> Self {
        let mut r = Self { fields: Vec::new() };
        r.text("benchmark", benchmark);
        r.text("language", "rust");
        r
    }

    pub fn int(&mut self, key: &str, value: u64) -> &mut Self {
        self.fields.push((key.to_string(), value.to_string()));
        self
    }

    pub fn ms(&mut self, key: &str, value: f64) -> &mut Self {
        self.fields.push((key.to_string(), format!("{value:.3}")));
        self
    }

    pub fn text(&mut self, key: &str, value: &str) -> &mut Self {
        let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
        self.fields.push((key.to_string(), format!("\"{escaped}\"")));
        self
    }

    /// Appends the peak RSS and prints the JSON line.
    pub fn emit(&mut self) {
        self.int("peak_rss_bytes", peak_rss_bytes());
        let body: Vec<String> = self
            .fields
            .iter()
            .map(|(k, v)| format!("\"{k}\":{v}"))
            .collect();
        println!("{{{}}}", body.join(","));
    }
}
