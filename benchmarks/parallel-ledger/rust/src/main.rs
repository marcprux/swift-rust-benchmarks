//! parallel-ledger: a ledger of transactions that each point at a shared,
//! immutable account record, aggregated once on one thread and then across
//! threads. Rust transactions hold `&Account` borrows that threads read for
//! free; Swift transactions hold class references whose atomic reference counts
//! every reading thread must touch. See ../README.md.

use benchkit::{available_parallelism, Args, Fnv1a, Report, SplitMix64, Stopwatch};
use std::fmt::Write as _;
use std::thread;

const REGIONS: usize = 6;
const TIERS: usize = 4;
const CATEGORIES: usize = 8;
const HOURS: usize = 24;

struct Account {
    id: u32,
    region: u8,
    tier: u8,
    credit_limit_cents: u64,
}

#[derive(Clone, Copy)]
struct Transaction<'a> {
    account: &'a Account,
    amount_cents: u32,
    category: u8,
    hour: u8,
}

struct Totals {
    per_account: Vec<u64>,
    per_region: [u64; REGIONS],
    per_tier: [u64; TIERS],
    per_category: [u64; CATEGORIES],
    per_hour: [u64; HOURS],
    flagged: u64,
    count: u64,
}

impl Totals {
    fn new(accounts: usize) -> Self {
        Self {
            per_account: vec![0; accounts],
            per_region: [0; REGIONS],
            per_tier: [0; TIERS],
            per_category: [0; CATEGORIES],
            per_hour: [0; HOURS],
            flagged: 0,
            count: 0,
        }
    }

    fn merge(&mut self, other: &Totals) {
        for (a, b) in self.per_account.iter_mut().zip(&other.per_account) {
            *a += b;
        }
        for i in 0..REGIONS {
            self.per_region[i] += other.per_region[i];
        }
        for i in 0..TIERS {
            self.per_tier[i] += other.per_tier[i];
        }
        for i in 0..CATEGORIES {
            self.per_category[i] += other.per_category[i];
        }
        for i in 0..HOURS {
            self.per_hour[i] += other.per_hour[i];
        }
        self.flagged += other.flagged;
        self.count += other.count;
    }
}

/// Skewed index: the minimum of two uniform draws, so a few accounts are hot.
fn skewed(rng: &mut SplitMix64, n: u64) -> u64 {
    let a = rng.below(n);
    let b = rng.below(n);
    a.min(b)
}

fn build_accounts(rng: &mut SplitMix64, n: usize) -> Vec<Account> {
    let mut accounts = Vec::with_capacity(n);
    for id in 0..n {
        accounts.push(Account {
            id: id as u32,
            region: rng.below(REGIONS as u64) as u8,
            tier: rng.below(TIERS as u64) as u8,
            credit_limit_cents: 50_000 + rng.below(1_000_000) * 100,
        });
    }
    accounts
}

fn build_transactions<'a>(rng: &mut SplitMix64, accounts: &'a [Account], n: usize) -> Vec<Transaction<'a>> {
    let mut txs = Vec::with_capacity(n);
    for _ in 0..n {
        let account = &accounts[skewed(rng, accounts.len() as u64) as usize];
        txs.push(Transaction {
            account,
            amount_cents: (100 + rng.below(50_000)) as u32,
            category: rng.below(CATEGORIES as u64) as u8,
            hour: rng.below(HOURS as u64) as u8,
        });
    }
    txs
}

/// One pass over a slice of transactions, reading three fields of the shared
/// account each one points at.
fn aggregate(txs: &[Transaction], accounts: usize) -> Totals {
    let mut t = Totals::new(accounts);
    for tx in txs {
        let a = tx.account;
        let amount = tx.amount_cents as u64;
        t.per_account[a.id as usize] += amount;
        t.per_region[a.region as usize] += amount;
        t.per_tier[a.tier as usize] += amount;
        t.per_category[tx.category as usize] += amount;
        t.per_hour[tx.hour as usize] += 1;
        if amount * 10 > a.credit_limit_cents {
            t.flagged += 1;
        }
        t.count += 1;
    }
    t
}

/// The same pass written with an index loop instead of an element iterator. In
/// Rust the two compile to the same code; the Swift side differs (see README).
fn aggregate_indexed(txs: &[Transaction], accounts: usize) -> Totals {
    let mut t = Totals::new(accounts);
    for i in 0..txs.len() {
        let amount = txs[i].amount_cents as u64;
        t.per_account[txs[i].account.id as usize] += amount;
        t.per_region[txs[i].account.region as usize] += amount;
        t.per_tier[txs[i].account.tier as usize] += amount;
        t.per_category[txs[i].category as usize] += amount;
        t.per_hour[txs[i].hour as usize] += 1;
        if amount * 10 > txs[i].account.credit_limit_cents {
            t.flagged += 1;
        }
        t.count += 1;
    }
    t
}

type Aggregate = fn(&[Transaction], usize) -> Totals;

/// The same pass split into `threads` contiguous chunks on scoped threads, with
/// the partial totals merged on the calling thread.
fn aggregate_parallel(txs: &[Transaction], accounts: usize, threads: usize, f: Aggregate) -> Totals {
    let chunk = ((txs.len() + threads - 1) / threads).max(1);
    thread::scope(|scope| {
        let handles: Vec<_> = txs
            .chunks(chunk)
            .map(|part| scope.spawn(move || f(part, accounts)))
            .collect();
        let mut total = Totals::new(accounts);
        for handle in handles {
            total.merge(&handle.join().expect("worker panicked"));
        }
        total
    })
}

fn describe(t: &Totals, out: &mut String) {
    let mut top: Vec<(u64, u32)> = t
        .per_account
        .iter()
        .enumerate()
        .filter(|(_, &v)| v > 0)
        .map(|(i, &v)| (v, i as u32))
        .collect();
    top.sort_unstable_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    top.truncate(10);
    write!(out, "count={} flagged={} top=", t.count, t.flagged).unwrap();
    for (v, id) in &top {
        write!(out, "{id}:{v},").unwrap();
    }
    write!(out, " regions=").unwrap();
    for v in &t.per_region {
        write!(out, "{v},").unwrap();
    }
    write!(out, " tiers=").unwrap();
    for v in &t.per_tier {
        write!(out, "{v},").unwrap();
    }
    write!(out, " categories=").unwrap();
    for v in &t.per_category {
        write!(out, "{v},").unwrap();
    }
    write!(out, " hours=").unwrap();
    for v in &t.per_hour {
        write!(out, "{v},").unwrap();
    }
    out.push('\n');
}

fn main() {
    let args = Args::parse();
    let n_accounts = args.usize("accounts", 50_000).max(1);
    let n_txs = args.usize("transactions", 10_000_000);
    let mut threads = args.usize("threads", 0);
    let passes = args.usize("passes", 5).max(1);
    let seed = args.u64("seed", 42);
    let quiet = args.flag("quiet");
    if threads == 0 {
        threads = available_parallelism();
    }

    let mut summary = String::new();
    let total = Stopwatch::start();

    let sw = Stopwatch::start();
    let mut rng = SplitMix64::new(seed);
    let accounts = build_accounts(&mut rng, n_accounts);
    let txs = build_transactions(&mut rng, &accounts, n_txs);
    let build_ms = sw.elapsed_ms();

    let sw = Stopwatch::start();
    let serial = aggregate(&txs, n_accounts);
    let serial_ms = sw.elapsed_ms();
    let mut expected = String::new();
    describe(&serial, &mut expected);
    summary.push_str("serial ");
    summary.push_str(&expected);
    drop(serial);

    let check = |label: &str, pass: usize, totals: &Totals| {
        let mut got = String::new();
        describe(totals, &mut got);
        if got != expected {
            panic!("{label} pass {pass} disagrees with the serial result:\n{got}\n{expected}");
        }
    };

    let sw = Stopwatch::start();
    let serial_indexed = aggregate_indexed(&txs, n_accounts);
    let serial_indexed_ms = sw.elapsed_ms();
    check("serial indexed", 0, &serial_indexed);
    drop(serial_indexed);

    let sw = Stopwatch::start();
    for pass in 0..passes {
        check("parallel", pass, &aggregate_parallel(&txs, n_accounts, threads, aggregate));
    }
    let parallel_ms = sw.elapsed_ms();

    let sw = Stopwatch::start();
    for pass in 0..passes {
        check("parallel indexed", pass, &aggregate_parallel(&txs, n_accounts, threads, aggregate_indexed));
    }
    let parallel_indexed_ms = sw.elapsed_ms();
    writeln!(summary, "parallel passes={passes} threads_agree=true").unwrap();

    let sw = Stopwatch::start();
    drop(txs);
    drop(accounts);
    let free_ms = sw.elapsed_ms();

    let total_ms = total.elapsed_ms();
    let per_pass_ms = parallel_ms / passes as f64;
    let per_pass_indexed_ms = parallel_indexed_ms / passes as f64;
    let speedup = |serial: f64, pass: f64| if pass > 0.0 { serial / pass } else { 0.0 };
    let mut h = Fnv1a::new();
    h.update(summary.as_bytes());

    if !quiet {
        print!("{summary}");
    }
    Report::new("parallel-ledger")
        .int("accounts", n_accounts as u64)
        .int("transactions", n_txs as u64)
        .int("threads", threads as u64)
        .int("passes", passes as u64)
        .int("seed", seed)
        .ms("build_ms", build_ms)
        .ms("serial_ms", serial_ms)
        .ms("parallel_ms", parallel_ms)
        .ms("serial_indexed_ms", serial_indexed_ms)
        .ms("parallel_indexed_ms", parallel_indexed_ms)
        .ms("free_ms", free_ms)
        .ms("total_ms", total_ms)
        .num("speedup", speedup(serial_ms, per_pass_ms))
        .num("speedup_indexed", speedup(serial_indexed_ms, per_pass_indexed_ms))
        .text("checksum", &format!("{:016x}", h.finish()))
        .emit();
}
