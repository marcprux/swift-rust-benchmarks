//! request-churn: a small in-memory shop API served in a loop. Every request
//! is parsed zero-copy, routed, answered with a freshly built JSON body, and
//! then all of its state dies. Measures steady-state throughput and whether the
//! process footprint stays flat. See ../README.md.

use benchkit::{peak_rss_bytes, Args, Fnv1a, Report, SplitMix64, Stopwatch};
use std::collections::{HashMap, VecDeque};
use std::fmt::Write as _;

const CATEGORIES: [&str; 8] = ["lamps", "chairs", "desks", "audio", "kitchen", "apparel", "outdoors", "toys"];
const ADJECTIVES: &[&str] = &[
    "Compact", "Deluxe", "Classic", "Wireless", "Ergonomic", "Vintage", "Portable", "Premium",
];
const NOUNS: &[&str] = &[
    "Lamp", "Chair", "Desk", "Keyboard", "Monitor", "Headphones", "Kettle", "Blender", "Jacket",
    "Sneakers", "Backpack", "Notebook", "Pen", "Camera", "Tripod", "Speaker",
];
const CATALOGUE_SIZE: u64 = 500;

// ---- server state -----------------------------------------------------------------

struct Item {
    id: u32,
    name: String,
    category: u8,
    price_cents: u32,
}

struct Session {
    user_id: u32,
    request_count: u32,
    last_seen: u64,
    cart: Vec<(u32, u32)>, // (item id, quantity)
}

#[derive(Clone, Copy)]
enum Route {
    Search = 0,
    Item = 1,
    CartAdd = 2,
    CartGet = 3,
    Health = 4,
    NotFound = 5,
}
const ROUTE_NAMES: [&str; 6] = ["search", "item", "cart_add", "cart_get", "health", "not_found"];

#[derive(Default)]
struct Metrics {
    route_count: [u64; 6],
    route_bytes: [u64; 6],
    status_200: u64,
    status_201: u64,
    status_400: u64,
    status_404: u64,
    sessions_created: u64,
    sessions_evicted: u64,
}

struct Server {
    catalogue: Vec<Item>,
    sessions: HashMap<String, Session>,
    eviction: VecDeque<String>,
    capacity: usize,
    metrics: Metrics,
}

// ---- request parsing (zero-copy: everything borrows from the raw request) ----------

struct Request<'a> {
    method: &'a str,
    path: &'a str,
    query: Vec<(&'a str, &'a str)>,
    headers: Vec<(&'a str, &'a str)>,
    body: &'a str,
}

impl<'a> Request<'a> {
    fn parse(raw: &'a str) -> Option<Request<'a>> {
        let (head, body) = raw.split_once("\r\n\r\n")?;
        let mut lines = head.split("\r\n");
        let mut parts = lines.next()?.split(' ');
        let method = parts.next()?;
        let target = parts.next()?;
        let (path, query_text) = target.split_once('?').unwrap_or((target, ""));
        let mut query = Vec::new();
        if !query_text.is_empty() {
            for pair in query_text.split('&') {
                query.push(pair.split_once('=')?);
            }
        }
        let mut headers = Vec::new();
        for line in lines {
            headers.push(line.split_once(": ")?);
        }
        Some(Request { method, path, query, headers, body })
    }

    fn header(&self, name: &str) -> Option<&'a str> {
        self.headers.iter().find(|(k, _)| *k == name).map(|(_, v)| *v)
    }

    fn param(&self, name: &str) -> Option<&'a str> {
        self.query.iter().find(|(k, _)| *k == name).map(|(_, v)| *v)
    }
}

fn form_field<'a>(body: &'a str, name: &str) -> Option<&'a str> {
    body.split('&').find_map(|pair| {
        let (k, v) = pair.split_once('=')?;
        (k == name).then_some(v)
    })
}

// ---- request handling -------------------------------------------------------------

impl Server {
    fn new(catalogue: Vec<Item>, capacity: usize) -> Self {
        Self {
            catalogue,
            sessions: HashMap::with_capacity(capacity + 1),
            eviction: VecDeque::with_capacity(capacity + 1),
            capacity,
            metrics: Metrics::default(),
        }
    }

    /// Finds or creates the session for a token, evicting the oldest session
    /// when the cache is full.
    fn session(&mut self, token: &str, now: u64) -> &mut Session {
        if !self.sessions.contains_key(token) {
            if self.sessions.len() >= self.capacity {
                if let Some(oldest) = self.eviction.pop_front() {
                    self.sessions.remove(&oldest);
                    self.metrics.sessions_evicted += 1;
                }
            }
            let user_id = u32::from_str_radix(&token[..6], 16).unwrap_or(0);
            self.sessions.insert(
                token.to_string(),
                Session { user_id, request_count: 0, last_seen: now, cart: Vec::new() },
            );
            self.eviction.push_back(token.to_string());
            self.metrics.sessions_created += 1;
        }
        self.sessions.get_mut(token).unwrap()
    }

    fn handle(&mut self, req: &Request, now: u64, body: &mut String) -> (Route, u16) {
        let token = req.header("Cookie").and_then(|c| c.strip_prefix("session=")).unwrap_or("anonymous");
        let session = self.session(token, now);
        session.request_count += 1;
        session.last_seen = now;
        let user_id = session.user_id;

        match (req.method, req.path) {
            ("GET", "/healthz") => {
                write!(body, "{{\"status\":\"ok\",\"sessions\":{},\"now\":{now}}}", self.sessions.len()).unwrap();
                (Route::Health, 200)
            }
            ("GET", "/api/v1/items") => {
                let category = req.param("category").and_then(|c| CATEGORIES.iter().position(|n| *n == c));
                let max_price: u32 = req.param("max_price").and_then(|v| v.parse().ok()).unwrap_or(u32::MAX);
                let limit: usize = req.param("limit").and_then(|v| v.parse().ok()).unwrap_or(20);
                let Some(category) = category else {
                    body.push_str("{\"error\":\"unknown category\"}");
                    return (Route::Search, 400);
                };
                let mut matches: Vec<&Item> = self
                    .catalogue
                    .iter()
                    .filter(|i| i.category as usize == category && i.price_cents <= max_price)
                    .collect();
                matches.sort_unstable_by_key(|i| (i.price_cents, i.id));
                body.push_str("{\"items\":[");
                for (n, item) in matches.iter().take(limit).enumerate() {
                    if n > 0 {
                        body.push(',');
                    }
                    write!(body, "{{\"id\":{},\"name\":\"{}\",\"price\":{}}}", item.id, item.name, item.price_cents).unwrap();
                }
                write!(body, "],\"count\":{},\"user\":{user_id}}}", matches.len()).unwrap();
                (Route::Search, 200)
            }
            ("GET", path) if path.starts_with("/api/v1/items/") => {
                let id: usize = match path["/api/v1/items/".len()..].parse() {
                    Ok(id) => id,
                    Err(_) => {
                        body.push_str("{\"error\":\"bad id\"}");
                        return (Route::Item, 400);
                    }
                };
                match self.catalogue.get(id) {
                    Some(item) => {
                        write!(
                            body,
                            "{{\"id\":{},\"name\":\"{}\",\"category\":\"{}\",\"price\":{}}}",
                            item.id, item.name, CATEGORIES[item.category as usize], item.price_cents
                        )
                        .unwrap();
                        (Route::Item, 200)
                    }
                    None => {
                        body.push_str("{\"error\":\"not found\"}");
                        (Route::Item, 404)
                    }
                }
            }
            ("POST", "/api/v1/cart") => {
                let item: Option<u32> = form_field(req.body, "item").and_then(|v| v.parse().ok());
                let qty: u32 = form_field(req.body, "qty").and_then(|v| v.parse().ok()).unwrap_or(1);
                match item {
                    Some(item) if (item as usize) < self.catalogue.len() => {
                        let session = self.sessions.get_mut(token).unwrap();
                        session.cart.push((item, qty));
                        write!(body, "{{\"cart_size\":{}}}", session.cart.len()).unwrap();
                        (Route::CartAdd, 201)
                    }
                    _ => {
                        body.push_str("{\"error\":\"unknown item\"}");
                        (Route::CartAdd, 400)
                    }
                }
            }
            ("GET", "/api/v1/cart") => {
                let session = &self.sessions[token];
                let mut total = 0u64;
                body.push_str("{\"items\":[");
                for (n, (item, qty)) in session.cart.iter().enumerate() {
                    let price = self.catalogue[*item as usize].price_cents as u64;
                    total += price * *qty as u64;
                    if n > 0 {
                        body.push(',');
                    }
                    write!(body, "{{\"id\":{item},\"qty\":{qty}}}").unwrap();
                }
                write!(body, "],\"total\":{total}}}").unwrap();
                (Route::CartGet, 200)
            }
            _ => {
                body.push_str("{\"error\":\"no such route\"}");
                (Route::NotFound, 404)
            }
        }
    }
}

// ---- workload generation ----------------------------------------------------------

fn build_catalogue(rng: &mut SplitMix64) -> Vec<Item> {
    (0..CATALOGUE_SIZE)
        .map(|id| {
            let adjective = ADJECTIVES[rng.below(ADJECTIVES.len() as u64) as usize];
            let noun = NOUNS[rng.below(NOUNS.len() as u64) as usize];
            let model = 100 + rng.below(900);
            Item {
                id: id as u32,
                name: format!("{adjective} {noun} {model}"),
                category: rng.below(CATEGORIES.len() as u64) as u8,
                price_cents: (199 + rng.below(49_800)) as u32,
            }
        })
        .collect()
}

fn build_pool(rng: &mut SplitMix64, pool_size: u64, token_count: u64) -> Vec<String> {
    let tokens: Vec<String> = (0..token_count).map(|_| format!("{:012x}", rng.next_u64() & 0xFFFF_FFFF_FFFF)).collect();
    let mut pool = Vec::with_capacity(pool_size as usize);
    for _ in 0..pool_size {
        let token = &tokens[rng.below(token_count) as usize];
        let request_id = rng.next_u64();
        let roll = rng.below(100);
        let mut raw = String::with_capacity(320);
        let mut body = String::new();
        if roll < 50 {
            let category = CATEGORIES[rng.below(CATEGORIES.len() as u64) as usize];
            let max_price = 1000 + rng.below(49_000);
            write!(raw, "GET /api/v1/items?category={category}&max_price={max_price}&sort=price&limit=20 HTTP/1.1\r\n").unwrap();
        } else if roll < 75 {
            write!(raw, "GET /api/v1/items/{} HTTP/1.1\r\n", rng.below(CATALOGUE_SIZE + 50)).unwrap();
        } else if roll < 85 {
            write!(body, "item={}&qty={}", rng.below(CATALOGUE_SIZE + 20), 1 + rng.below(3)).unwrap();
            raw.push_str("POST /api/v1/cart HTTP/1.1\r\n");
        } else if roll < 92 {
            raw.push_str("GET /api/v1/cart HTTP/1.1\r\n");
        } else if roll < 98 {
            raw.push_str("GET /healthz HTTP/1.1\r\n");
        } else {
            raw.push_str("GET /api/v2/unknown HTTP/1.1\r\n");
        }
        raw.push_str("Host: shop.example.com\r\n");
        raw.push_str("User-Agent: bench-client/1.0 (+https://example.com/bench)\r\n");
        raw.push_str("Accept: application/json\r\n");
        write!(raw, "Cookie: session={token}\r\n").unwrap();
        write!(raw, "X-Request-Id: {request_id:016x}\r\n").unwrap();
        if !body.is_empty() {
            write!(raw, "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {}\r\n", body.len()).unwrap();
        }
        raw.push_str("\r\n");
        raw.push_str(&body);
        pool.push(raw);
    }
    pool
}

// ---- main -------------------------------------------------------------------------

fn main() {
    let args = Args::parse();
    let requests = args.u64("requests", 1_000_000);
    let pool_size = args.u64("pool", 10_000).max(1);
    let capacity = args.u64("sessions", 5_000).max(1);
    let seed = args.u64("seed", 42);
    let quiet = args.flag("quiet");

    let mut summary = String::new();
    let total = Stopwatch::start();

    let sw = Stopwatch::start();
    let mut rng = SplitMix64::new(seed);
    let catalogue = build_catalogue(&mut rng);
    let pool = build_pool(&mut rng, pool_size, capacity * 2);
    let pool_bytes: usize = pool.iter().map(|r| r.len()).sum();
    let generate_ms = sw.elapsed_ms();

    let sw = Stopwatch::start();
    let mut server = Server::new(catalogue, capacity as usize);
    let mut sample = Fnv1a::new();
    let mut parse_failures = 0u64;
    let mut early_peak = 0u64;
    for i in 0..requests {
        let raw = &pool[rng.below(pool_size) as usize];
        let Some(req) = Request::parse(raw) else {
            parse_failures += 1;
            continue;
        };
        let mut body = String::new();
        let (route, status) = server.handle(&req, i, &mut body);
        let m = &mut server.metrics;
        m.route_count[route as usize] += 1;
        m.route_bytes[route as usize] += body.len() as u64;
        match status {
            200 => m.status_200 += 1,
            201 => m.status_201 += 1,
            400 => m.status_400 += 1,
            _ => m.status_404 += 1,
        }
        if i % 1000 == 0 {
            sample.update(body.as_bytes());
        }
        if i == requests / 10 {
            early_peak = peak_rss_bytes();
        }
    }
    let serve_ms = sw.elapsed_ms();

    let m = &server.metrics;
    for (name, (count, bytes)) in ROUTE_NAMES.iter().zip(m.route_count.iter().zip(m.route_bytes)) {
        writeln!(summary, "route {name} count={count} bytes={bytes}").unwrap();
    }
    writeln!(summary, "status 200={} 201={} 400={} 404={}", m.status_200, m.status_201, m.status_400, m.status_404).unwrap();
    let cart_items: u64 = server.sessions.values().map(|s| s.cart.len() as u64).sum();
    let request_total: u64 = server.sessions.values().map(|s| s.request_count as u64).sum();
    writeln!(
        summary,
        "sessions live={} created={} evicted={} cart_items={cart_items} requests={request_total}",
        server.sessions.len(), m.sessions_created, m.sessions_evicted
    )
    .unwrap();
    writeln!(summary, "sample {:016x} parse_failures={parse_failures}", sample.finish()).unwrap();

    let sw = Stopwatch::start();
    drop(server);
    drop(pool);
    let shutdown_ms = sw.elapsed_ms();

    let total_ms = total.elapsed_ms();
    let final_peak = peak_rss_bytes();
    let mut h = Fnv1a::new();
    h.update(summary.as_bytes());

    if !quiet {
        print!("{summary}");
    }
    Report::new("request-churn")
        .int("requests", requests)
        .int("pool", pool_size)
        .int("sessions", capacity)
        .int("seed", seed)
        .int("pool_bytes", pool_bytes as u64)
        .int("requests_per_sec", (requests as f64 / (serve_ms / 1000.0)) as u64)
        .int("rss_growth_bytes", final_peak.saturating_sub(early_peak))
        .ms("generate_ms", generate_ms)
        .ms("serve_ms", serve_ms)
        .ms("shutdown_ms", shutdown_ms)
        .ms("total_ms", total_ms)
        .text("checksum", &format!("{:016x}", h.finish()))
        .emit();
}
