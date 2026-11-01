// order-graph: an order-management model in which orders share customers and
// products. Swift uses class references for the shared entities; Rust stores
// them in arenas and refers to them by index. See ../README.md.

import BenchKit

let firstNames = [
    "Ada", "Grace", "Linus", "Dennis", "Ken", "Barbara", "Margaret", "Alan", "Edsger", "Donald",
    "Niklaus", "Bjarne", "Guido", "Anders", "Yukihiro", "Rich",
]
let lastNames = [
    "Lovelace", "Hopper", "Torvalds", "Ritchie", "Thompson", "Liskov", "Hamilton", "Turing",
    "Dijkstra", "Knuth", "Wirth", "Stroustrup", "van Rossum", "Hejlsberg", "Matsumoto", "Hickey",
]
let adjectives = [
    "Compact", "Deluxe", "Classic", "Wireless", "Ergonomic", "Vintage", "Portable", "Premium",
]
let nouns = [
    "Lamp", "Chair", "Desk", "Keyboard", "Monitor", "Headphones", "Kettle", "Blender", "Jacket",
    "Sneakers", "Backpack", "Notebook", "Pen", "Camera", "Tripod", "Speaker",
]
let regions = ["north-america", "europe", "asia", "south-america", "africa", "oceania"]
let categories = ["electronics", "furniture", "kitchen", "apparel", "outdoors", "office", "toys", "books"]
let repricedCategory: UInt8 = 0 // electronics

final class Customer {
    let id: UInt32
    let name: String
    let region: UInt8
    var totalCents: UInt64 = 0
    var orderCount: UInt32 = 0

    init(id: UInt32, name: String, region: UInt8) {
        self.id = id
        self.name = name
        self.region = region
    }
}

final class Product {
    let id: UInt32
    let name: String
    let category: UInt8
    var priceCents: UInt64
    var unitsSold: UInt64 = 0

    init(id: UInt32, name: String, category: UInt8, priceCents: UInt64) {
        self.id = id
        self.name = name
        self.category = category
        self.priceCents = priceCents
    }
}

struct Line {
    let product: Product
    let quantity: UInt32
}

struct Order {
    let id: UInt32
    let customer: Customer
    let timestamp: UInt64
    var lines: [Line]
}

/// Shared entities are reference-counted objects; the slot arrays hold one
/// strong reference each and orders hold the rest. A `nil` slot is a deleted entity.
struct Store {
    var customers: [Customer?]
    var products: [Product?]
    var orders: [Order]
}

let tsBase: UInt64 = 1_700_000_000_000
let tsSpan: UInt64 = 365 * 86_400_000

/// Skewed index: the minimum of two uniform draws, so low indices are popular
/// and the tail is rarely referenced (and therefore prunable).
@inline(__always)
func skewed(_ rng: inout SplitMix64, _ n: UInt64) -> UInt64 {
    let a = rng.below(n)
    let b = rng.below(n)
    return min(a, b)
}

@inline(__always)
func pick(_ rng: inout SplitMix64, _ items: [String]) -> String {
    items[Int(rng.below(UInt64(items.count)))]
}

// ---- phase 1: build ---------------------------------------------------------------

func build(_ rng: inout SplitMix64, customers nCustomers: UInt64, products nProducts: UInt64, orders nOrders: UInt64) -> Store {
    var customers: [Customer?] = []
    customers.reserveCapacity(Int(nCustomers))
    for id in 0..<nCustomers {
        let region = UInt8(rng.below(UInt64(regions.count)))
        let first = pick(&rng, firstNames)
        let last = pick(&rng, lastNames)
        customers.append(Customer(id: UInt32(id), name: "\(first) \(last)", region: region))
    }

    var products: [Product?] = []
    products.reserveCapacity(Int(nProducts))
    for id in 0..<nProducts {
        let category = UInt8(rng.below(UInt64(categories.count)))
        let adjective = pick(&rng, adjectives)
        let noun = pick(&rng, nouns)
        let model = 100 + rng.below(900)
        let price = 199 + rng.below(49_800)
        products.append(Product(id: UInt32(id), name: "\(adjective) \(noun) \(model)", category: category, priceCents: price))
    }

    var orders: [Order] = []
    orders.reserveCapacity(Int(nOrders))
    for id in 0..<nOrders {
        let customer = customers[Int(skewed(&rng, nCustomers))]!
        let timestamp = tsBase + rng.below(tsSpan)
        let lineCount = Int(1 + rng.below(5))
        var lines: [Line] = []
        lines.reserveCapacity(lineCount)
        for _ in 0..<lineCount {
            let product = products[Int(skewed(&rng, nProducts))]!
            lines.append(Line(product: product, quantity: UInt32(1 + rng.below(4))))
        }
        orders.append(Order(id: UInt32(id), customer: customer, timestamp: timestamp, lines: lines))
    }
    return Store(customers: customers, products: products, orders: orders)
}

// ---- phase 2: report --------------------------------------------------------------

func report(_ store: Store, pass: UInt64, summary: inout String) {
    for c in store.customers {
        guard let c else { continue }
        c.totalCents = 0
        c.orderCount = 0
    }
    for p in store.products {
        p?.unitsSold = 0
    }

    var regionRevenue = [UInt64](repeating: 0, count: regions.count)
    for order in store.orders {
        var total: UInt64 = 0
        for line in order.lines {
            let p = line.product
            p.unitsSold += UInt64(line.quantity)
            total += p.priceCents * UInt64(line.quantity)
        }
        let c = order.customer
        c.totalCents += total
        c.orderCount += 1
        regionRevenue[Int(c.region)] += total
    }

    var ranked: [(UInt64, UInt32)] = []
    ranked.reserveCapacity(store.customers.count)
    for c in store.customers {
        if let c { ranked.append((c.totalCents, c.id)) }
    }
    ranked.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
    var bestSellers: [(UInt64, UInt32)] = []
    bestSellers.reserveCapacity(store.products.count)
    for p in store.products {
        if let p { bestSellers.append((p.unitsSold, p.id)) }
    }
    bestSellers.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }

    summary += "pass \(pass) revenue"
    for (name, revenue) in zip(regions, regionRevenue) {
        summary += " \(name)=\(revenue)"
    }
    summary += "\n"
    for (total, id) in ranked.prefix(10) {
        let c = store.customers[Int(id)]!
        summary += "top_customer \(id) \(c.name) orders=\(c.orderCount) total=\(total)\n"
    }
    for (units, id) in bestSellers.prefix(10) {
        let p = store.products[Int(id)]!
        summary += "top_product \(id) \(p.name) units=\(units)\n"
    }
}

// ---- phase 3: reprice -------------------------------------------------------------

/// Raises prices in one category through the shared product objects, then
/// re-totals every order so that the change is observed via the references.
func reprice(_ store: Store) -> (changed: UInt64, revenue: UInt64) {
    var changed: UInt64 = 0
    for p in store.products {
        if let p, p.category == repricedCategory {
            p.priceCents = p.priceCents * 110 / 100
            changed += 1
        }
    }
    var revenue: UInt64 = 0
    for order in store.orders {
        for line in order.lines {
            revenue += line.product.priceCents * UInt64(line.quantity)
        }
    }
    return (changed, revenue)
}

// ---- phase 4: prune ---------------------------------------------------------------

struct Pruned {
    var deletedOrders: UInt64 = 0
    var orphanProducts: UInt64 = 0
    var orphanCustomers: UInt64 = 0
    var remainingHash: UInt64 = 0
}

/// Deletes old orders, then removes every product and customer that no
/// remaining order refers to. ARC already knows: an entity whose slot holds the
/// only remaining reference is unreferenced by any order.
func prune(_ store: inout Store, cutoff: UInt64) -> Pruned {
    var result = Pruned()
    let before = store.orders.count
    store.orders.removeAll { $0.timestamp < cutoff }
    result.deletedOrders = UInt64(before - store.orders.count)

    for i in store.products.indices where store.products[i] != nil {
        if isKnownUniquelyReferenced(&store.products[i]) {
            store.products[i] = nil
            result.orphanProducts += 1
        }
    }
    for i in store.customers.indices where store.customers[i] != nil {
        if isKnownUniquelyReferenced(&store.customers[i]) {
            store.customers[i] = nil
            result.orphanCustomers += 1
        }
    }

    var h = Fnv1a()
    for o in store.orders {
        withUnsafeBytes(of: o.id.littleEndian) { h.update($0) }
    }
    for p in store.products {
        if let p { withUnsafeBytes(of: p.id.littleEndian) { h.update($0) } }
    }
    for c in store.customers {
        if let c { withUnsafeBytes(of: c.id.littleEndian) { h.update($0) } }
    }
    result.remainingHash = h.value
    return result
}

// ---- main -------------------------------------------------------------------------

func run() {
    let args = Args()
    let nCustomers = max(args.uint64("customers", default: 50_000), 1)
    let nProducts = max(args.uint64("products", default: 200_000), 1)
    let nOrders = args.uint64("orders", default: 1_000_000)
    let passes = args.uint64("passes", default: 3)
    let seed = args.uint64("seed", default: 42)
    let quiet = args.flag("quiet")

    var summary = ""
    let total = Stopwatch()

    var sw = Stopwatch()
    var rng = SplitMix64(seed: seed)
    var store = build(&rng, customers: nCustomers, products: nProducts, orders: nOrders)
    let buildMs = sw.elapsedMs
    let lineCount = store.orders.reduce(0) { $0 + $1.lines.count }

    sw = Stopwatch()
    for pass in 0..<passes {
        report(store, pass: pass, summary: &summary)
    }
    let reportMs = sw.elapsedMs

    sw = Stopwatch()
    let (repriced, revenue) = reprice(store)
    let repriceMs = sw.elapsedMs
    summary += "reprice changed=\(repriced) revenue=\(revenue)\n"

    sw = Stopwatch()
    let pruned = prune(&store, cutoff: tsBase + tsSpan * 3 / 10)
    let pruneMs = sw.elapsedMs
    summary += "prune deleted=\(pruned.deletedOrders) orphan_products=\(pruned.orphanProducts) orphan_customers=\(pruned.orphanCustomers) remaining_orders=\(store.orders.count) ids=\(hex16(pruned.remainingHash))\n"

    sw = Stopwatch()
    _ = consume store
    let freeMs = sw.elapsedMs

    let totalMs = total.elapsedMs
    var h = Fnv1a()
    h.update(summary.utf8)

    if !quiet {
        print(summary, terminator: "")
    }
    var report = Report(benchmark: "order-graph")
    report.int("customers", nCustomers)
    report.int("products", nProducts)
    report.int("orders", nOrders)
    report.int("passes", passes)
    report.int("seed", seed)
    report.int("line_count", lineCount)
    report.int("deleted_orders", pruned.deletedOrders)
    report.int("orphan_products", pruned.orphanProducts)
    report.int("orphan_customers", pruned.orphanCustomers)
    report.ms("build_ms", buildMs)
    report.ms("report_ms", reportMs)
    report.ms("reprice_ms", repriceMs)
    report.ms("prune_ms", pruneMs)
    report.ms("free_ms", freeMs)
    report.ms("total_ms", totalMs)
    report.text("checksum", hex16(h.value))
    report.emit()
}

run()
