//! order-graph: an order-management model in which orders share customers and
//! products. Rust stores the shared entities in arenas (`Vec<Option<T>>`) and
//! orders refer to them by index; Swift uses class references. See ../README.md.

use benchkit::{Args, Fnv1a, Report, SplitMix64, Stopwatch};
use std::fmt::Write as _;

const FIRST_NAMES: &[&str] = &[
    "Ada", "Grace", "Linus", "Dennis", "Ken", "Barbara", "Margaret", "Alan", "Edsger", "Donald",
    "Niklaus", "Bjarne", "Guido", "Anders", "Yukihiro", "Rich",
];
const LAST_NAMES: &[&str] = &[
    "Lovelace", "Hopper", "Torvalds", "Ritchie", "Thompson", "Liskov", "Hamilton", "Turing",
    "Dijkstra", "Knuth", "Wirth", "Stroustrup", "van Rossum", "Hejlsberg", "Matsumoto", "Hickey",
];
const ADJECTIVES: &[&str] = &[
    "Compact", "Deluxe", "Classic", "Wireless", "Ergonomic", "Vintage", "Portable", "Premium",
];
const NOUNS: &[&str] = &[
    "Lamp", "Chair", "Desk", "Keyboard", "Monitor", "Headphones", "Kettle", "Blender", "Jacket",
    "Sneakers", "Backpack", "Notebook", "Pen", "Camera", "Tripod", "Speaker",
];
const REGIONS: [&str; 6] = ["north-america", "europe", "asia", "south-america", "africa", "oceania"];
const CATEGORIES: [&str; 8] = [
    "electronics", "furniture", "kitchen", "apparel", "outdoors", "office", "toys", "books",
];
const REPRICED_CATEGORY: u8 = 0; // electronics

struct Customer {
    id: u32,
    name: String,
    region: u8,
    total_cents: u64,
    order_count: u32,
}

struct Product {
    id: u32,
    name: String,
    category: u8,
    price_cents: u64,
    units_sold: u64,
}

#[derive(Clone, Copy)]
struct Line {
    product: u32,
    quantity: u32,
}

struct Order {
    id: u32,
    customer: u32,
    timestamp: u64,
    lines: Vec<Line>,
}

/// Arena-style store: shared entities live in slot vectors and are addressed by
/// index. A `None` slot is a deleted entity.
struct Store {
    customers: Vec<Option<Customer>>,
    products: Vec<Option<Product>>,
    orders: Vec<Order>,
}

const TS_BASE: u64 = 1_700_000_000_000;
const TS_SPAN: u64 = 365 * 86_400_000;

/// Skewed index: the minimum of two uniform draws, so low indices are popular
/// and the tail is rarely referenced (and therefore prunable).
fn skewed(rng: &mut SplitMix64, n: u64) -> u64 {
    let a = rng.below(n);
    let b = rng.below(n);
    a.min(b)
}

fn pick<'a>(rng: &mut SplitMix64, items: &[&'a str]) -> &'a str {
    items[rng.below(items.len() as u64) as usize]
}

// ---- phase 1: build ---------------------------------------------------------------

fn build(rng: &mut SplitMix64, n_customers: u64, n_products: u64, n_orders: u64) -> Store {
    let mut customers = Vec::with_capacity(n_customers as usize);
    for id in 0..n_customers {
        let region = rng.below(REGIONS.len() as u64) as u8;
        let name = format!("{} {}", pick(rng, FIRST_NAMES), pick(rng, LAST_NAMES));
        customers.push(Some(Customer { id: id as u32, name, region, total_cents: 0, order_count: 0 }));
    }

    let mut products = Vec::with_capacity(n_products as usize);
    for id in 0..n_products {
        let category = rng.below(CATEGORIES.len() as u64) as u8;
        let name = format!("{} {} {}", pick(rng, ADJECTIVES), pick(rng, NOUNS), 100 + rng.below(900));
        let price_cents = 199 + rng.below(49_800);
        products.push(Some(Product { id: id as u32, name, category, price_cents, units_sold: 0 }));
    }

    let mut orders = Vec::with_capacity(n_orders as usize);
    for id in 0..n_orders {
        let customer = skewed(rng, n_customers) as u32;
        let timestamp = TS_BASE + rng.below(TS_SPAN);
        let line_count = 1 + rng.below(5) as usize;
        let mut lines = Vec::with_capacity(line_count);
        for _ in 0..line_count {
            lines.push(Line {
                product: skewed(rng, n_products) as u32,
                quantity: 1 + rng.below(4) as u32,
            });
        }
        orders.push(Order { id: id as u32, customer, timestamp, lines });
    }
    Store { customers, products, orders }
}

// ---- phase 2: report --------------------------------------------------------------

fn report(store: &mut Store, pass: u64, summary: &mut String) {
    let Store { customers, products, orders } = store;
    for c in customers.iter_mut().flatten() {
        c.total_cents = 0;
        c.order_count = 0;
    }
    for p in products.iter_mut().flatten() {
        p.units_sold = 0;
    }

    let mut region_revenue = [0u64; REGIONS.len()];
    for order in orders.iter() {
        let mut total = 0u64;
        for line in &order.lines {
            let p = products[line.product as usize].as_mut().expect("live product");
            p.units_sold += line.quantity as u64;
            total += p.price_cents * line.quantity as u64;
        }
        let c = customers[order.customer as usize].as_mut().expect("live customer");
        c.total_cents += total;
        c.order_count += 1;
        region_revenue[c.region as usize] += total;
    }

    let mut ranked: Vec<(u64, u32)> = customers.iter().flatten().map(|c| (c.total_cents, c.id)).collect();
    ranked.sort_unstable_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    let mut best_sellers: Vec<(u64, u32)> = products.iter().flatten().map(|p| (p.units_sold, p.id)).collect();
    best_sellers.sort_unstable_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));

    write!(summary, "pass {pass} revenue").unwrap();
    for (name, revenue) in REGIONS.iter().zip(region_revenue) {
        write!(summary, " {name}={revenue}").unwrap();
    }
    summary.push('\n');
    for (total, id) in ranked.iter().take(10) {
        let c = customers[*id as usize].as_ref().unwrap();
        writeln!(summary, "top_customer {id} {} orders={} total={total}", c.name, c.order_count).unwrap();
    }
    for (units, id) in best_sellers.iter().take(10) {
        let p = products[*id as usize].as_ref().unwrap();
        writeln!(summary, "top_product {id} {} units={units}", p.name).unwrap();
    }
}

// ---- phase 3: reprice -------------------------------------------------------------

/// Raises prices in one category through the shared product records, then
/// re-totals every order so that the change is observed via the references.
fn reprice(store: &mut Store) -> (u64, u64) {
    let Store { products, orders, .. } = store;
    let mut changed = 0u64;
    for p in products.iter_mut().flatten() {
        if p.category == REPRICED_CATEGORY {
            p.price_cents = p.price_cents * 110 / 100;
            changed += 1;
        }
    }
    let mut revenue = 0u64;
    for order in orders.iter() {
        for line in &order.lines {
            let p = products[line.product as usize].as_ref().expect("live product");
            revenue += p.price_cents * line.quantity as u64;
        }
    }
    (changed, revenue)
}

// ---- phase 4: prune ---------------------------------------------------------------

struct Pruned {
    deleted_orders: u64,
    orphan_products: u64,
    orphan_customers: u64,
    remaining_hash: u64,
}

/// Deletes old orders, then removes every product and customer that no
/// remaining order refers to. The arena has no reference counts, so liveness is
/// established with a scan over the remaining orders.
fn prune(store: &mut Store, cutoff: u64) -> Pruned {
    let Store { customers, products, orders } = store;
    let before = orders.len();
    orders.retain(|o| o.timestamp >= cutoff);
    let deleted_orders = (before - orders.len()) as u64;

    let mut product_refs = vec![0u32; products.len()];
    let mut customer_refs = vec![0u32; customers.len()];
    for order in orders.iter() {
        customer_refs[order.customer as usize] += 1;
        for line in &order.lines {
            product_refs[line.product as usize] += 1;
        }
    }

    let mut orphan_products = 0u64;
    for (slot, refs) in products.iter_mut().zip(&product_refs) {
        if slot.is_some() && *refs == 0 {
            *slot = None;
            orphan_products += 1;
        }
    }
    let mut orphan_customers = 0u64;
    for (slot, refs) in customers.iter_mut().zip(&customer_refs) {
        if slot.is_some() && *refs == 0 {
            *slot = None;
            orphan_customers += 1;
        }
    }

    let mut h = Fnv1a::new();
    for o in orders.iter() {
        h.update(&o.id.to_le_bytes());
    }
    for p in products.iter().flatten() {
        h.update(&p.id.to_le_bytes());
    }
    for c in customers.iter().flatten() {
        h.update(&c.id.to_le_bytes());
    }
    Pruned { deleted_orders, orphan_products, orphan_customers, remaining_hash: h.finish() }
}

// ---- main -------------------------------------------------------------------------

fn main() {
    let args = Args::parse();
    let n_customers = args.u64("customers", 50_000).max(1);
    let n_products = args.u64("products", 200_000).max(1);
    let n_orders = args.u64("orders", 1_000_000);
    let passes = args.u64("passes", 3);
    let seed = args.u64("seed", 42);
    let quiet = args.flag("quiet");

    let mut summary = String::new();
    let total = Stopwatch::start();

    let sw = Stopwatch::start();
    let mut rng = SplitMix64::new(seed);
    let mut store = build(&mut rng, n_customers, n_products, n_orders);
    let build_ms = sw.elapsed_ms();
    let line_count: usize = store.orders.iter().map(|o| o.lines.len()).sum();

    let sw = Stopwatch::start();
    for pass in 0..passes {
        report(&mut store, pass, &mut summary);
    }
    let report_ms = sw.elapsed_ms();

    let sw = Stopwatch::start();
    let (repriced, revenue) = reprice(&mut store);
    let reprice_ms = sw.elapsed_ms();
    writeln!(summary, "reprice changed={repriced} revenue={revenue}").unwrap();

    let sw = Stopwatch::start();
    let pruned = prune(&mut store, TS_BASE + TS_SPAN * 3 / 10);
    let prune_ms = sw.elapsed_ms();
    writeln!(
        summary,
        "prune deleted={} orphan_products={} orphan_customers={} remaining_orders={} ids={:016x}",
        pruned.deleted_orders, pruned.orphan_products, pruned.orphan_customers, store.orders.len(),
        pruned.remaining_hash
    )
    .unwrap();

    let sw = Stopwatch::start();
    drop(store);
    let free_ms = sw.elapsed_ms();

    let total_ms = total.elapsed_ms();
    let mut h = Fnv1a::new();
    h.update(summary.as_bytes());

    if !quiet {
        print!("{summary}");
    }
    Report::new("order-graph")
        .int("customers", n_customers)
        .int("products", n_products)
        .int("orders", n_orders)
        .int("passes", passes)
        .int("seed", seed)
        .int("line_count", line_count as u64)
        .int("deleted_orders", pruned.deleted_orders)
        .int("orphan_products", pruned.orphan_products)
        .int("orphan_customers", pruned.orphan_customers)
        .ms("build_ms", build_ms)
        .ms("report_ms", report_ms)
        .ms("reprice_ms", reprice_ms)
        .ms("prune_ms", prune_ms)
        .ms("free_ms", free_ms)
        .ms("total_ms", total_ms)
        .text("checksum", &format!("{:016x}", h.finish()))
        .emit();
}
