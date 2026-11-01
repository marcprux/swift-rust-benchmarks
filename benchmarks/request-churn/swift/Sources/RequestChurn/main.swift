// request-churn: a small in-memory shop API served in a loop. Every request
// is parsed zero-copy, routed, answered with a freshly built JSON body, and
// then all of its state dies. Measures steady-state throughput and whether the
// process footprint stays flat. See ../README.md.

import BenchKit

let categories = ["lamps", "chairs", "desks", "audio", "kitchen", "apparel", "outdoors", "toys"]
let adjectives = ["Compact", "Deluxe", "Classic", "Wireless", "Ergonomic", "Vintage", "Portable", "Premium"]
let nouns = [
    "Lamp", "Chair", "Desk", "Keyboard", "Monitor", "Headphones", "Kettle", "Blender", "Jacket",
    "Sneakers", "Backpack", "Notebook", "Pen", "Camera", "Tripod", "Speaker",
]
let catalogueSize: UInt64 = 500

// ---- byte-slice helpers -----------------------------------------------------------

typealias Bytes = ArraySlice<UInt8>

extension ArraySlice where Element == UInt8 {
    /// Plain byte scan for `needle`, returning the index of its first occurrence.
    func find(_ needle: StaticString) -> Int? {
        let n = needle.utf8CodeUnitCount
        guard n > 0, count >= n else { return nil }
        let first = needle.utf8Start[0]
        var i = startIndex
        let last = endIndex - n
        while i <= last {
            if self[i] == first {
                var k = 1
                while k < n, self[i + k] == needle.utf8Start[k] { k += 1 }
                if k == n { return i }
            }
            i += 1
        }
        return nil
    }

    func splitOnce(_ needle: StaticString) -> (Bytes, Bytes)? {
        guard let at = find(needle) else { return nil }
        return (self[startIndex..<at], self[(at + needle.utf8CodeUnitCount)...])
    }

    func splitOnce(byte: UInt8) -> (Bytes, Bytes)? {
        guard let at = firstIndex(of: byte) else { return nil }
        return (self[startIndex..<at], self[(at + 1)...])
    }

    func equals(_ s: StaticString) -> Bool {
        elementsEqual(UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount))
    }

    func hasPrefix(_ s: StaticString) -> Bool {
        starts(with: UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount))
    }

    func equals(_ s: String) -> Bool {
        elementsEqual(s.utf8)
    }
}

func parseUInt(_ bytes: Bytes) -> UInt64? {
    guard !bytes.isEmpty else { return nil }
    var v: UInt64 = 0
    for c in bytes {
        guard c >= 48, c <= 57 else { return nil }
        v = v &* 10 &+ UInt64(c - 48)
    }
    return v
}

func parseHex(_ bytes: Bytes) -> UInt64? {
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

// ---- server state -----------------------------------------------------------------

struct Item {
    let id: UInt32
    let name: String
    let category: UInt8
    let priceCents: UInt32
}

final class Session {
    let userId: UInt32
    var requestCount: UInt32 = 0
    var lastSeen: UInt64
    var cart: [(item: UInt32, quantity: UInt32)] = []

    init(userId: UInt32, now: UInt64) {
        self.userId = userId
        lastSeen = now
    }
}

enum Route: Int {
    case search = 0, item, cartAdd, cartGet, health, notFound
}
let routeNames = ["search", "item", "cart_add", "cart_get", "health", "not_found"]

struct Metrics {
    var routeCount = [UInt64](repeating: 0, count: 6)
    var routeBytes = [UInt64](repeating: 0, count: 6)
    var status200: UInt64 = 0
    var status201: UInt64 = 0
    var status400: UInt64 = 0
    var status404: UInt64 = 0
    var sessionsCreated: UInt64 = 0
    var sessionsEvicted: UInt64 = 0
}

/// FIFO of session tokens with O(1) push and pop (the standard library has no deque).
struct TokenQueue {
    private var slots: [String?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        slots = [String?](repeating: nil, count: capacity)
    }

    mutating func push(_ token: String) {
        slots[(head + count) % slots.count] = token
        count += 1
    }

    mutating func pop() -> String? {
        guard count > 0 else { return nil }
        let token = slots[head]
        slots[head] = nil
        head = (head + 1) % slots.count
        count -= 1
        return token
    }
}

// ---- request parsing (zero-copy: every field is a view into the raw request) ------

struct Request {
    var method: Bytes
    var path: Bytes
    var query: [(Bytes, Bytes)]
    var headers: [(Bytes, Bytes)]
    var body: Bytes

    static func parse(_ raw: [UInt8]) -> Request? {
        guard let (head, body) = raw[...].splitOnce("\r\n\r\n") else { return nil }
        var remaining = head
        guard let (requestLine, rest) = remaining.splitOnce("\r\n") ?? (remaining, remaining[remaining.endIndex...]) as (Bytes, Bytes)? else { return nil }
        remaining = rest
        guard let (method, afterMethod) = requestLine.splitOnce(byte: UInt8(ascii: " ")),
              let (target, _) = afterMethod.splitOnce(byte: UInt8(ascii: " "))
        else { return nil }
        let path: Bytes
        var query: [(Bytes, Bytes)] = []
        if let (p, queryText) = target.splitOnce(byte: UInt8(ascii: "?")) {
            path = p
            var pairs = queryText
            while !pairs.isEmpty {
                let pair: Bytes
                if let (first, rest) = pairs.splitOnce(byte: UInt8(ascii: "&")) {
                    pair = first
                    pairs = rest
                } else {
                    pair = pairs
                    pairs = pairs[pairs.endIndex...]
                }
                guard let kv = pair.splitOnce(byte: UInt8(ascii: "=")) else { return nil }
                query.append(kv)
            }
        } else {
            path = target
        }
        var headers: [(Bytes, Bytes)] = []
        while !remaining.isEmpty {
            let line: Bytes
            if let (first, rest) = remaining.splitOnce("\r\n") {
                line = first
                remaining = rest
            } else {
                line = remaining
                remaining = remaining[remaining.endIndex...]
            }
            guard let kv = line.splitOnce(": ") else { return nil }
            headers.append(kv)
        }
        return Request(method: method, path: path, query: query, headers: headers, body: body)
    }

    func header(_ name: StaticString) -> Bytes? {
        headers.first { $0.0.equals(name) }?.1
    }

    func param(_ name: StaticString) -> Bytes? {
        query.first { $0.0.equals(name) }?.1
    }
}

func formField(_ body: Bytes, _ name: StaticString) -> Bytes? {
    var pairs = body
    while !pairs.isEmpty {
        let pair: Bytes
        if let (first, rest) = pairs.splitOnce(byte: UInt8(ascii: "&")) {
            pair = first
            pairs = rest
        } else {
            pair = pairs
            pairs = pairs[pairs.endIndex...]
        }
        if let (k, v) = pair.splitOnce(byte: UInt8(ascii: "=")), k.equals(name) {
            return v
        }
    }
    return nil
}

// ---- request handling -------------------------------------------------------------

final class Server {
    let catalogue: [Item]
    var sessions: [String: Session]
    var eviction: TokenQueue
    let capacity: Int
    var metrics = Metrics()

    init(catalogue: [Item], capacity: Int) {
        self.catalogue = catalogue
        self.capacity = capacity
        sessions = Dictionary(minimumCapacity: capacity + 1)
        eviction = TokenQueue(capacity: capacity + 1)
    }

    /// Finds or creates the session for a token, evicting the oldest session
    /// when the cache is full.
    func session(_ token: String, now: UInt64) -> Session {
        if let existing = sessions[token] {
            return existing
        }
        if sessions.count >= capacity, let oldest = eviction.pop() {
            sessions[oldest] = nil
            metrics.sessionsEvicted += 1
        }
        let userId = UInt32(parseHex(Array(token.utf8)[...][0..<6]) ?? 0)
        let created = Session(userId: userId, now: now)
        sessions[token] = created
        eviction.push(token)
        metrics.sessionsCreated += 1
        return created
    }

    func handle(_ req: Request, now: UInt64, body: inout String) -> (Route, UInt16) {
        var token = "anonymous"
        if let cookie = req.header("Cookie"), cookie.hasPrefix("session=") {
            token = String(decoding: cookie[(cookie.startIndex + 8)...], as: UTF8.self)
        }
        let session = session(token, now: now)
        session.requestCount += 1
        session.lastSeen = now
        let userId = session.userId

        let isGet = req.method.equals("GET")
        if isGet, req.path.equals("/healthz") {
            body += "{\"status\":\"ok\",\"sessions\":\(sessions.count),\"now\":\(now)}"
            return (.health, 200)
        }
        if isGet, req.path.equals("/api/v1/items") {
            let category = req.param("category").flatMap { c in categories.firstIndex { c.equals($0) } }
            let maxPrice = req.param("max_price").flatMap(parseUInt).flatMap { UInt32(exactly: $0) } ?? UInt32.max
            let limit = req.param("limit").flatMap(parseUInt).map { Int($0) } ?? 20
            guard let category else {
                body += "{\"error\":\"unknown category\"}"
                return (.search, 400)
            }
            var matches = catalogue.filter { Int($0.category) == category && $0.priceCents <= maxPrice }
            matches.sort { $0.priceCents != $1.priceCents ? $0.priceCents < $1.priceCents : $0.id < $1.id }
            body += "{\"items\":["
            for (n, item) in matches.prefix(limit).enumerated() {
                if n > 0 { body += "," }
                body += "{\"id\":\(item.id),\"name\":\"\(item.name)\",\"price\":\(item.priceCents)}"
            }
            body += "],\"count\":\(matches.count),\"user\":\(userId)}"
            return (.search, 200)
        }
        if isGet, req.path.hasPrefix("/api/v1/items/") {
            guard let id = parseUInt(req.path[(req.path.startIndex + 14)...]) else {
                body += "{\"error\":\"bad id\"}"
                return (.item, 400)
            }
            if id < UInt64(catalogue.count) {
                let item = catalogue[Int(id)]
                body += "{\"id\":\(item.id),\"name\":\"\(item.name)\",\"category\":\"\(categories[Int(item.category)])\",\"price\":\(item.priceCents)}"
                return (.item, 200)
            }
            body += "{\"error\":\"not found\"}"
            return (.item, 404)
        }
        if req.method.equals("POST"), req.path.equals("/api/v1/cart") {
            let item = formField(req.body, "item").flatMap(parseUInt)
            let qty = formField(req.body, "qty").flatMap(parseUInt) ?? 1
            if let item, item < UInt64(catalogue.count) {
                session.cart.append((UInt32(item), UInt32(qty)))
                body += "{\"cart_size\":\(session.cart.count)}"
                return (.cartAdd, 201)
            }
            body += "{\"error\":\"unknown item\"}"
            return (.cartAdd, 400)
        }
        if isGet, req.path.equals("/api/v1/cart") {
            var total: UInt64 = 0
            body += "{\"items\":["
            for (n, line) in session.cart.enumerated() {
                total += UInt64(catalogue[Int(line.item)].priceCents) * UInt64(line.quantity)
                if n > 0 { body += "," }
                body += "{\"id\":\(line.item),\"qty\":\(line.quantity)}"
            }
            body += "],\"total\":\(total)}"
            return (.cartGet, 200)
        }
        body += "{\"error\":\"no such route\"}"
        return (.notFound, 404)
    }
}

// ---- workload generation ----------------------------------------------------------

func buildCatalogue(_ rng: inout SplitMix64) -> [Item] {
    var items: [Item] = []
    items.reserveCapacity(Int(catalogueSize))
    for id in 0..<catalogueSize {
        let adjective = adjectives[Int(rng.below(UInt64(adjectives.count)))]
        let noun = nouns[Int(rng.below(UInt64(nouns.count)))]
        let model = 100 + rng.below(900)
        let category = UInt8(rng.below(UInt64(categories.count)))
        let price = UInt32(199 + rng.below(49_800))
        items.append(Item(id: UInt32(id), name: "\(adjective) \(noun) \(model)", category: category, priceCents: price))
    }
    return items
}

func buildPool(_ rng: inout SplitMix64, poolSize: UInt64, tokenCount: UInt64) -> [[UInt8]] {
    var tokens: [String] = []
    tokens.reserveCapacity(Int(tokenCount))
    for _ in 0..<tokenCount {
        tokens.append(String(hex16(rng.next() & 0xFFFF_FFFF_FFFF).suffix(12)))
    }
    var pool: [[UInt8]] = []
    pool.reserveCapacity(Int(poolSize))
    for _ in 0..<poolSize {
        let token = tokens[Int(rng.below(tokenCount))]
        let requestID = rng.next()
        let roll = rng.below(100)
        var raw = ""
        raw.reserveCapacity(320)
        var body = ""
        if roll < 50 {
            let category = categories[Int(rng.below(UInt64(categories.count)))]
            let maxPrice = 1000 + rng.below(49_000)
            raw += "GET /api/v1/items?category=\(category)&max_price=\(maxPrice)&sort=price&limit=20 HTTP/1.1\r\n"
        } else if roll < 75 {
            raw += "GET /api/v1/items/\(rng.below(catalogueSize + 50)) HTTP/1.1\r\n"
        } else if roll < 85 {
            let item = rng.below(catalogueSize + 20)
            let qty = 1 + rng.below(3)
            body = "item=\(item)&qty=\(qty)"
            raw += "POST /api/v1/cart HTTP/1.1\r\n"
        } else if roll < 92 {
            raw += "GET /api/v1/cart HTTP/1.1\r\n"
        } else if roll < 98 {
            raw += "GET /healthz HTTP/1.1\r\n"
        } else {
            raw += "GET /api/v2/unknown HTTP/1.1\r\n"
        }
        raw += "Host: shop.example.com\r\n"
        raw += "User-Agent: bench-client/1.0 (+https://example.com/bench)\r\n"
        raw += "Accept: application/json\r\n"
        raw += "Cookie: session=\(token)\r\n"
        raw += "X-Request-Id: \(hex16(requestID))\r\n"
        if !body.isEmpty {
            raw += "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n"
        }
        raw += "\r\n"
        raw += body
        pool.append(Array(raw.utf8))
    }
    return pool
}

// ---- main -------------------------------------------------------------------------

func run() {
    let args = Args()
    let requests = args.uint64("requests", default: 1_000_000)
    let poolSize = max(args.uint64("pool", default: 10_000), 1)
    let capacity = max(args.uint64("sessions", default: 5_000), 1)
    let seed = args.uint64("seed", default: 42)
    let quiet = args.flag("quiet")

    var summary = ""
    let total = Stopwatch()

    var sw = Stopwatch()
    var rng = SplitMix64(seed: seed)
    let catalogue = buildCatalogue(&rng)
    var pool = buildPool(&rng, poolSize: poolSize, tokenCount: capacity * 2)
    let poolBytes = pool.reduce(0) { $0 + $1.count }
    let generateMs = sw.elapsedMs

    sw = Stopwatch()
    var server: Server? = Server(catalogue: catalogue, capacity: Int(capacity))
    var sample = Fnv1a()
    var parseFailures: UInt64 = 0
    var earlyPeak: UInt64 = 0
    do {
        let server = server!
        for i in 0..<requests {
            let raw = pool[Int(rng.below(poolSize))]
            guard let req = Request.parse(raw) else {
                parseFailures += 1
                continue
            }
            var body = ""
            let (route, status) = server.handle(req, now: i, body: &body)
            server.metrics.routeCount[route.rawValue] += 1
            server.metrics.routeBytes[route.rawValue] += UInt64(body.utf8.count)
            switch status {
            case 200: server.metrics.status200 += 1
            case 201: server.metrics.status201 += 1
            case 400: server.metrics.status400 += 1
            default: server.metrics.status404 += 1
            }
            if i % 1000 == 0 {
                sample.update(body.utf8)
            }
            if i == requests / 10 {
                earlyPeak = peakRSSBytes()
            }
        }
    }
    let serveMs = sw.elapsedMs

    let m = server!.metrics
    for (name, (count, bytes)) in zip(routeNames, zip(m.routeCount, m.routeBytes)) {
        summary += "route \(name) count=\(count) bytes=\(bytes)\n"
    }
    summary += "status 200=\(m.status200) 201=\(m.status201) 400=\(m.status400) 404=\(m.status404)\n"
    let cartItems = server!.sessions.values.reduce(0) { $0 + UInt64($1.cart.count) }
    let requestTotal = server!.sessions.values.reduce(0) { $0 + UInt64($1.requestCount) }
    summary += "sessions live=\(server!.sessions.count) created=\(m.sessionsCreated) evicted=\(m.sessionsEvicted) cart_items=\(cartItems) requests=\(requestTotal)\n"
    summary += "sample \(hex16(sample.value)) parse_failures=\(parseFailures)\n"

    sw = Stopwatch()
    server = nil
    pool.removeAll()
    let shutdownMs = sw.elapsedMs

    let totalMs = total.elapsedMs
    let finalPeak = peakRSSBytes()
    var h = Fnv1a()
    h.update(summary.utf8)

    if !quiet {
        print(summary, terminator: "")
    }
    var report = Report(benchmark: "request-churn")
    report.int("requests", requests)
    report.int("pool", poolSize)
    report.int("sessions", capacity)
    report.int("seed", seed)
    report.int("pool_bytes", poolBytes)
    report.int("requests_per_sec", UInt64(Double(requests) / (serveMs / 1000.0)))
    report.int("rss_growth_bytes", finalPeak > earlyPeak ? finalPeak - earlyPeak : 0)
    report.ms("generate_ms", generateMs)
    report.ms("serve_ms", serveMs)
    report.ms("shutdown_ms", shutdownMs)
    report.ms("total_ms", totalMs)
    report.text("checksum", hex16(h.value))
    report.emit()
}

run()
