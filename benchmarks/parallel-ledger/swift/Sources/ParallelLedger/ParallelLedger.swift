// parallel-ledger: a ledger of transactions that each point at a shared,
// immutable account record, aggregated once on one thread and then across
// threads. Swift transactions hold class references whose atomic reference
// counts every reading thread must touch; Rust transactions hold `&Account`
// borrows that threads read for free. See ../README.md.

import BenchKit

let regions = 6
let tiers = 4
let categories = 8
let hours = 24

final class Account: Sendable {
    let id: UInt32
    let region: UInt8
    let tier: UInt8
    let creditLimitCents: UInt64

    init(id: UInt32, region: UInt8, tier: UInt8, creditLimitCents: UInt64) {
        self.id = id
        self.region = region
        self.tier = tier
        self.creditLimitCents = creditLimitCents
    }
}

struct Transaction: Sendable {
    let account: Account
    let amountCents: UInt32
    let category: UInt8
    let hour: UInt8
}

struct Totals: Sendable {
    var perAccount: [UInt64]
    var perRegion = [UInt64](repeating: 0, count: regions)
    var perTier = [UInt64](repeating: 0, count: tiers)
    var perCategory = [UInt64](repeating: 0, count: categories)
    var perHour = [UInt64](repeating: 0, count: hours)
    var flagged: UInt64 = 0
    var count: UInt64 = 0

    init(accounts: Int) {
        perAccount = [UInt64](repeating: 0, count: accounts)
    }

    mutating func merge(_ other: Totals) {
        for i in perAccount.indices {
            perAccount[i] += other.perAccount[i]
        }
        for i in 0..<regions {
            perRegion[i] += other.perRegion[i]
        }
        for i in 0..<tiers {
            perTier[i] += other.perTier[i]
        }
        for i in 0..<categories {
            perCategory[i] += other.perCategory[i]
        }
        for i in 0..<hours {
            perHour[i] += other.perHour[i]
        }
        flagged += other.flagged
        count += other.count
    }
}

/// Skewed index: the minimum of two uniform draws, so a few accounts are hot.
@inline(__always)
func skewed(_ rng: inout SplitMix64, _ n: UInt64) -> UInt64 {
    let a = rng.below(n)
    let b = rng.below(n)
    return min(a, b)
}

func buildAccounts(_ rng: inout SplitMix64, count: Int) -> [Account] {
    var accounts: [Account] = []
    accounts.reserveCapacity(count)
    for id in 0..<count {
        accounts.append(Account(
            id: UInt32(id),
            region: UInt8(rng.below(UInt64(regions))),
            tier: UInt8(rng.below(UInt64(tiers))),
            creditLimitCents: 50_000 + rng.below(1_000_000) * 100
        ))
    }
    return accounts
}

func buildTransactions(_ rng: inout SplitMix64, accounts: [Account], count: Int) -> [Transaction] {
    var txs: [Transaction] = []
    txs.reserveCapacity(count)
    for _ in 0..<count {
        let account = accounts[Int(skewed(&rng, UInt64(accounts.count)))]
        txs.append(Transaction(
            account: account,
            amountCents: UInt32(100 + rng.below(50_000)),
            category: UInt8(rng.below(UInt64(categories))),
            hour: UInt8(rng.below(UInt64(hours)))
        ))
    }
    return txs
}

/// One pass over a slice of transactions, reading three fields of the shared
/// account each one points at.
func aggregate(_ txs: ArraySlice<Transaction>, accounts: Int) -> Totals {
    var t = Totals(accounts: accounts)
    for tx in txs {
        let a = tx.account
        let amount = UInt64(tx.amountCents)
        t.perAccount[Int(a.id)] += amount
        t.perRegion[Int(a.region)] += amount
        t.perTier[Int(a.tier)] += amount
        t.perCategory[Int(tx.category)] += amount
        t.perHour[Int(tx.hour)] += 1
        if amount * 10 > a.creditLimitCents {
            t.flagged += 1
        }
        t.count += 1
    }
    return t
}

/// The same pass written with an index loop instead of `for tx in txs`. The
/// element loop copies each `Transaction` out of the array, which retains and
/// releases its `account`; reading fields through `txs[i].account` does not.
func aggregateIndexed(_ txs: ArraySlice<Transaction>, accounts: Int) -> Totals {
    var t = Totals(accounts: accounts)
    for i in txs.indices {
        let amount = UInt64(txs[i].amountCents)
        t.perAccount[Int(txs[i].account.id)] += amount
        t.perRegion[Int(txs[i].account.region)] += amount
        t.perTier[Int(txs[i].account.tier)] += amount
        t.perCategory[Int(txs[i].category)] += amount
        t.perHour[Int(txs[i].hour)] += 1
        if amount * 10 > txs[i].account.creditLimitCents {
            t.flagged += 1
        }
        t.count += 1
    }
    return t
}

/// The same pass split into `threads` contiguous chunks as child tasks of a
/// task group, with the partial totals merged on the calling task.
func aggregateParallel(_ txs: [Transaction], accounts: Int, threads: Int, indexed: Bool) async -> Totals {
    let chunk = max((txs.count + threads - 1) / threads, 1)
    return await withTaskGroup(of: Totals.self) { group in
        var start = 0
        while start < txs.count {
            let end = min(start + chunk, txs.count)
            let part = txs[start..<end]
            group.addTask {
                indexed ? aggregateIndexed(part, accounts: accounts) : aggregate(part, accounts: accounts)
            }
            start = end
        }
        var total = Totals(accounts: accounts)
        for await partial in group {
            total.merge(partial)
        }
        return total
    }
}

func describe(_ t: Totals, into out: inout String) {
    var top: [(UInt64, UInt32)] = []
    for (i, v) in t.perAccount.enumerated() where v > 0 {
        top.append((v, UInt32(i)))
    }
    top.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
    if top.count > 10 {
        top.removeLast(top.count - 10)
    }
    out += "count=\(t.count) flagged=\(t.flagged) top="
    for (v, id) in top {
        out += "\(id):\(v),"
    }
    out += " regions="
    for v in t.perRegion {
        out += "\(v),"
    }
    out += " tiers="
    for v in t.perTier {
        out += "\(v),"
    }
    out += " categories="
    for v in t.perCategory {
        out += "\(v),"
    }
    out += " hours="
    for v in t.perHour {
        out += "\(v),"
    }
    out += "\n"
}

struct Ledger {
    var accounts: [Account]
    var transactions: [Transaction]
}

@main
struct ParallelLedger {
    static func main() async {
        let args = Args()
        let nAccounts = max(args.int("accounts", default: 50_000), 1)
        let nTxs = args.int("transactions", default: 10_000_000)
        var threads = args.int("threads", default: 0)
        let passes = max(args.int("passes", default: 5), 1)
        let seed = args.uint64("seed", default: 42)
        let quiet = args.flag("quiet")
        if threads == 0 {
            threads = availableParallelism()
        }

        var summary = ""
        let total = Stopwatch()

        var sw = Stopwatch()
        var rng = SplitMix64(seed: seed)
        let accounts = buildAccounts(&rng, count: nAccounts)
        let transactions = buildTransactions(&rng, accounts: accounts, count: nTxs)
        let ledger = Ledger(accounts: accounts, transactions: transactions)
        let buildMs = sw.elapsedMs

        sw = Stopwatch()
        let serial = aggregate(ledger.transactions[...], accounts: nAccounts)
        let serialMs = sw.elapsedMs
        var expected = ""
        describe(serial, into: &expected)
        summary += "serial " + expected

        func check(_ label: String, _ pass: Int, _ totals: Totals) {
            var got = ""
            describe(totals, into: &got)
            if got != expected {
                fatalError("\(label) pass \(pass) disagrees with the serial result:\n\(got)\n\(expected)")
            }
        }

        sw = Stopwatch()
        let serialIndexed = aggregateIndexed(ledger.transactions[...], accounts: nAccounts)
        let serialIndexedMs = sw.elapsedMs
        check("serial indexed", 0, serialIndexed)

        sw = Stopwatch()
        for pass in 0..<passes {
            check("parallel", pass, await aggregateParallel(ledger.transactions, accounts: nAccounts, threads: threads, indexed: false))
        }
        let parallelMs = sw.elapsedMs

        sw = Stopwatch()
        for pass in 0..<passes {
            check("parallel indexed", pass, await aggregateParallel(ledger.transactions, accounts: nAccounts, threads: threads, indexed: true))
        }
        let parallelIndexedMs = sw.elapsedMs
        summary += "parallel passes=\(passes) threads_agree=true\n"

        sw = Stopwatch()
        _ = consume ledger
        let freeMs = sw.elapsedMs

        let totalMs = total.elapsedMs
        let perPassMs = parallelMs / Double(passes)
        let perPassIndexedMs = parallelIndexedMs / Double(passes)
        func speedup(_ serial: Double, _ pass: Double) -> Double { pass > 0 ? serial / pass : 0 }
        var h = Fnv1a()
        h.update(summary.utf8)

        if !quiet {
            print(summary, terminator: "")
        }
        var report = Report(benchmark: "parallel-ledger")
        report.int("accounts", nAccounts)
        report.int("transactions", nTxs)
        report.int("threads", threads)
        report.int("passes", passes)
        report.int("seed", seed)
        report.ms("build_ms", buildMs)
        report.ms("serial_ms", serialMs)
        report.ms("parallel_ms", parallelMs)
        report.ms("serial_indexed_ms", serialIndexedMs)
        report.ms("parallel_indexed_ms", parallelIndexedMs)
        report.ms("free_ms", freeMs)
        report.ms("total_ms", totalMs)
        report.num("speedup", speedup(serialMs, perPassMs))
        report.num("speedup_indexed", speedup(serialIndexedMs, perPassIndexedMs))
        report.text("checksum", hex16(h.value))
        report.emit()
    }
}
