// document-tree: build a DOM-like tree of heap nodes, serialize it to markup,
// parse the markup back into a second tree, run query passes over it, mutate
// it in place, serialize again, then free everything. See ../README.md.

import BenchKit

/// Element names. A real DOM interns its known vocabulary (html5ever's `Atom`,
/// WebKit's `QualifiedName`); a closed enum is the idiomatic stand-in and keeps
/// string representation details out of the memory comparison.
enum Tag: UInt8, CaseIterable {
    case div, span, p, ul, li, a, section, article, h2, table, tr, td, ad, img, nav, footer

    static let names = [
        "div", "span", "p", "ul", "li", "a", "section", "article", "h2", "table", "tr", "td", "ad",
        "img", "nav", "footer",
    ]

    var name: String { Tag.names[Int(rawValue)] }

    init?(utf8 bytes: ArraySlice<UInt8>) {
        guard let i = Tag.names.firstIndex(where: { bytes.elementsEqual($0.utf8) }) else { return nil }
        self = Tag.allCases[i]
    }
}

enum AttrName: UInt8, CaseIterable {
    case id, `class`, href, dataWeight, title, dataVisited

    static let names = ["id", "class", "href", "data-weight", "title", "data-visited"]

    var name: String { AttrName.names[Int(rawValue)] }

    init?(utf8 bytes: ArraySlice<UInt8>) {
        guard let i = AttrName.names.firstIndex(where: { bytes.elementsEqual($0.utf8) }) else { return nil }
        self = AttrName.allCases[i]
    }
}

let classes = ["row", "col", "card", "hot", "nav-item", "muted", "hero", "list"]
let words = [
    "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do",
    "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore", "magna", "aliqua", "R&D",
    "<tag>",
]

struct Attribute {
    var name: AttrName
    var value: String
}

enum Kind: UInt8 {
    case element, text
}

/// A reference-counted node, as a DOM is modelled in Swift: parents hold strong
/// references to their children and the tree is freed when the last reference
/// to the root goes away.
final class Node {
    let kind: Kind
    var tag: Tag
    /// The content of text nodes (empty for elements).
    var text: String
    var attributes: [Attribute]
    var children: [Node]

    init(tag: Tag, attributes: [Attribute], children: [Node]) {
        kind = .element
        self.tag = tag
        text = ""
        self.attributes = attributes
        self.children = children
    }

    init(text: String) {
        kind = .text
        tag = .div
        self.text = text
        attributes = []
        children = []
    }

    func attribute(_ name: AttrName) -> String? {
        attributes.first { $0.name == name }?.value
    }
}

// ---- phase 1: build ---------------------------------------------------------------

@inline(__always)
func pick(_ rng: inout SplitMix64, _ items: [String]) -> String {
    items[Int(rng.below(UInt64(items.count)))]
}

func randomText(_ rng: inout SplitMix64) -> String {
    let count = 3 + rng.below(10)
    var s = ""
    for i in 0..<count {
        if i > 0 { s += " " }
        s += pick(&rng, words)
    }
    return s
}

func randomAttributes(_ rng: inout SplitMix64) -> [Attribute] {
    let n = Int(rng.below(4))
    var attributes: [Attribute] = []
    attributes.reserveCapacity(n)
    for _ in 0..<n {
        switch rng.below(5) {
        case 0: attributes.append(Attribute(name: .id, value: "n\(rng.below(1_000_000))"))
        case 1: attributes.append(Attribute(name: .class, value: pick(&rng, classes)))
        case 2: attributes.append(Attribute(name: .href, value: "/p/\(rng.below(100_000))"))
        case 3: attributes.append(Attribute(name: .dataWeight, value: String(rng.below(1000))))
        default:
            let a = pick(&rng, words)
            let b = pick(&rng, words)
            attributes.append(Attribute(name: .title, value: "\(a) \(b)"))
        }
    }
    return attributes
}

/// Builds an element with exactly `budget` descendants, spreading the budget
/// across its children so that the tree stays roughly balanced.
func buildElement(_ rng: inout SplitMix64, fanout: UInt64, budget: UInt64) -> Node {
    let tag = Tag.allCases[Int(rng.below(UInt64(Tag.allCases.count)))]
    let attributes = randomAttributes(&rng)
    var children: [Node] = []
    if budget > 0 {
        let k = min(budget, 1 + rng.below(2 * fanout))
        var remaining = budget - k
        var prevText = false
        children.reserveCapacity(Int(k))
        for i in 0..<k {
            let last = i == k - 1
            let roll = rng.below(100)
            let isText = !prevText && !(last && remaining > 0) && roll < 30
            if isText {
                children.append(Node(text: randomText(&rng)))
                prevText = true
            } else {
                let share = last ? remaining : min(rng.below(remaining * 2 / (k - i) + 1), remaining)
                remaining -= share
                children.append(buildElement(&rng, fanout: fanout, budget: share))
                prevText = false
            }
        }
    }
    return Node(tag: tag, attributes: attributes, children: children)
}

// ---- phase 2: serialize -----------------------------------------------------------

func escape(_ s: String, into out: inout [UInt8]) {
    for b in s.utf8 {
        switch b {
        case UInt8(ascii: "&"): out.append(contentsOf: "&amp;".utf8)
        case UInt8(ascii: "<"): out.append(contentsOf: "&lt;".utf8)
        case UInt8(ascii: ">"): out.append(contentsOf: "&gt;".utf8)
        case UInt8(ascii: "\""): out.append(contentsOf: "&quot;".utf8)
        default: out.append(b)
        }
    }
}

func serialize(_ node: Node, into out: inout [UInt8]) {
    switch node.kind {
    case .text:
        escape(node.text, into: &out)
    case .element:
        out.append(UInt8(ascii: "<"))
        out.append(contentsOf: node.tag.name.utf8)
        for a in node.attributes {
            out.append(UInt8(ascii: " "))
            out.append(contentsOf: a.name.name.utf8)
            out.append(contentsOf: "=\"".utf8)
            escape(a.value, into: &out)
            out.append(UInt8(ascii: "\""))
        }
        out.append(UInt8(ascii: ">"))
        for child in node.children {
            serialize(child, into: &out)
        }
        out.append(contentsOf: "</".utf8)
        out.append(contentsOf: node.tag.name.utf8)
        out.append(UInt8(ascii: ">"))
    }
}

// ---- phase 3: parse ---------------------------------------------------------------

/// Recursive-descent parser. Children and attributes are appended directly to
/// the node's arrays: with 8-byte element references and growth starting at a
/// capacity of 1, Swift arrays carry little slack, and the open-element-stack
/// technique used on the Rust side measured slower and larger here (see README).
struct Parser {
    let bytes: [UInt8]
    var pos = 0

    func peek() -> UInt8? {
        pos < bytes.count ? bytes[pos] : nil
    }

    mutating func take(until stop: (UInt8) -> Bool) -> ArraySlice<UInt8> {
        let start = pos
        while pos < bytes.count, !stop(bytes[pos]) {
            pos += 1
        }
        return bytes[start..<pos]
    }

    static func unescape(_ bytes: ArraySlice<UInt8>) -> String? {
        if !bytes.contains(UInt8(ascii: "&")) {
            return String(decoding: bytes, as: UTF8.self)
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if bytes[i] == UInt8(ascii: "&") {
                guard let semi = bytes[i...].firstIndex(of: UInt8(ascii: ";")) else { return nil }
                let entity = bytes[(i + 1)..<semi]
                if entity.elementsEqual("amp".utf8) {
                    out.append(UInt8(ascii: "&"))
                } else if entity.elementsEqual("lt".utf8) {
                    out.append(UInt8(ascii: "<"))
                } else if entity.elementsEqual("gt".utf8) {
                    out.append(UInt8(ascii: ">"))
                } else if entity.elementsEqual("quot".utf8) {
                    out.append(UInt8(ascii: "\""))
                } else {
                    return nil
                }
                i = semi + 1
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func parseNode() -> Node? {
        guard let first = peek() else { return nil }
        if first != UInt8(ascii: "<") {
            let text = take { $0 == UInt8(ascii: "<") }
            guard let content = Parser.unescape(text) else { return nil }
            return Node(text: content)
        }
        pos += 1
        let tagBytes = take { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: ">") }
        guard let tag = Tag(utf8: tagBytes) else { return nil }

        var attributes: [Attribute] = []
        while true {
            while peek() == UInt8(ascii: " ") { pos += 1 }
            guard let b = peek() else { return nil }
            if b == UInt8(ascii: ">") {
                pos += 1
                break
            }
            let name = take { $0 == UInt8(ascii: "=") }
            guard pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "="), bytes[pos + 1] == UInt8(ascii: "\"") else {
                return nil
            }
            pos += 2
            let value = take { $0 == UInt8(ascii: "\"") }
            guard peek() == UInt8(ascii: "\"") else { return nil }
            pos += 1
            guard let unescaped = Parser.unescape(value), let attrName = AttrName(utf8: name) else { return nil }
            attributes.append(Attribute(name: attrName, value: unescaped))
        }

        var children: [Node] = []
        while true {
            if pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "<"), bytes[pos + 1] == UInt8(ascii: "/") {
                break
            }
            guard let child = parseNode() else { return nil }
            children.append(child)
        }

        pos += 2
        let closing = take { $0 == UInt8(ascii: ">") }
        guard closing.elementsEqual(tagBytes), peek() == UInt8(ascii: ">") else { return nil }
        pos += 1
        return Node(tag: tag, attributes: attributes, children: children)
    }
}

func parse(_ bytes: [UInt8]) -> Node? {
    var parser = Parser(bytes: bytes)
    guard let root = parser.parseNode(), parser.pos == bytes.count else { return nil }
    return root
}

// ---- structural hash (used to verify the round trip) -----------------------------

func hashTree(_ node: Node, into h: inout Fnv1a) {
    switch node.kind {
    case .text:
        h.byte(UInt8(ascii: "T"))
        h.update(node.text.utf8)
        h.byte(0)
    case .element:
        h.byte(UInt8(ascii: "E"))
        h.update(node.tag.name.utf8)
        h.byte(0)
        for a in node.attributes {
            h.update(a.name.name.utf8)
            h.byte(UInt8(ascii: "="))
            h.update(a.value.utf8)
            h.byte(0)
        }
        h.byte(UInt8(ascii: ">"))
        for child in node.children {
            hashTree(child, into: &h)
        }
        h.byte(UInt8(ascii: "/"))
    }
}

// ---- phase 4: query ---------------------------------------------------------------

struct Stats {
    var elements: UInt64 = 0
    var texts: UInt64 = 0
    var attributes: UInt64 = 0
    var textBytes: UInt64 = 0
    var maxDepth: UInt64 = 0
    var hotCount: UInt64 = 0
    var hotWeight: UInt64 = 0
}

/// One full traversal collecting document statistics.
func walk(_ node: Node, depth: UInt64, stats: inout Stats, byTag: inout [UInt64]) {
    stats.maxDepth = max(stats.maxDepth, depth)
    switch node.kind {
    case .text:
        stats.texts += 1
        stats.textBytes += UInt64(node.text.utf8.count)
    case .element:
        stats.elements += 1
        stats.attributes += UInt64(node.attributes.count)
        byTag[Int(node.tag.rawValue)] += 1
        if node.attribute(.class) == "hot" {
            stats.hotCount += 1
            if let w = node.attribute(.dataWeight) {
                stats.hotWeight += UInt64(w) ?? 0
            }
        }
        for child in node.children {
            walk(child, depth: depth + 1, stats: &stats, byTag: &byTag)
        }
    }
}

/// Random root-to-leaf walks: pure pointer chasing.
func lookups(_ root: Node, count: UInt64, seed: UInt64) -> UInt64 {
    var rng = SplitMix64(seed: seed)
    var acc: UInt64 = 0
    for _ in 0..<count {
        var node = root
        var depth: UInt64 = 0
        while node.kind == .element, !node.children.isEmpty {
            node = node.children[Int(rng.below(UInt64(node.children.count)))]
            depth += 1
        }
        let first = node.kind == .element ? node.tag.name.utf8.first! : node.text.utf8.first!
        acc = acc &* 31 &+ (depth * 256 + UInt64(first))
    }
    return acc
}

// ---- phase 5: mutate --------------------------------------------------------------

struct Mutations {
    var purged: UInt64 = 0
    var marked: UInt64 = 0
    var reversed: UInt64 = 0
}

/// Drops every `<ad>` subtree, stamps `data-visited` on hot elements and
/// reverses the children of every `<ul>`, all in place.
func mutate(_ node: Node, _ m: inout Mutations) {
    guard node.kind == .element else { return }
    let before = node.children.count
    node.children.removeAll { $0.kind == .element && $0.tag == .ad }
    m.purged += UInt64(before - node.children.count)

    if node.attribute(.class) == "hot" {
        if let i = node.attributes.firstIndex(where: { $0.name == .dataVisited }) {
            node.attributes[i].value = "1"
        } else {
            node.attributes.append(Attribute(name: .dataVisited, value: "1"))
        }
        m.marked += 1
    }

    if node.tag == .ul {
        node.children.reverse()
        m.reversed += 1
    }

    for child in node.children {
        mutate(child, &m)
    }
}

// ---- main -------------------------------------------------------------------------

func run() {
    let args = Args()
    let nodes = args.uint64("nodes", default: 500_000)
    let fanout = max(args.uint64("fanout", default: 6), 1)
    let passes = args.uint64("passes", default: 3)
    let lookupCount = args.uint64("lookups", default: 200_000)
    let seed = args.uint64("seed", default: 42)
    let quiet = args.flag("quiet")

    var summary = ""
    let total = Stopwatch()

    // build
    var sw = Stopwatch()
    var rng = SplitMix64(seed: seed)
    let original = buildElement(&rng, fanout: fanout, budget: nodes > 0 ? nodes - 1 : 0)
    let buildMs = sw.elapsedMs

    // serialize
    sw = Stopwatch()
    var markup: [UInt8] = []
    markup.reserveCapacity(Int(nodes) * 48)
    serialize(original, into: &markup)
    let serializeMs = sw.elapsedMs

    // parse
    sw = Stopwatch()
    guard let parsed = parse(markup) else {
        fatalError("parse failed")
    }
    let parseMs = sw.elapsedMs

    var h = Fnv1a()
    hashTree(original, into: &h)
    let originalHash = h.value
    h = Fnv1a()
    hashTree(parsed, into: &h)
    let parsedHash = h.value
    summary += "roundtrip original=\(hex16(originalHash)) parsed=\(hex16(parsedHash)) bytes=\(markup.count)\n"

    // query
    sw = Stopwatch()
    var stats = Stats()
    var byTag = [UInt64](repeating: 0, count: Tag.allCases.count)
    var lookupAcc: [UInt64] = []
    for pass in 0..<passes {
        stats = Stats()
        byTag = [UInt64](repeating: 0, count: Tag.allCases.count)
        walk(parsed, depth: 0, stats: &stats, byTag: &byTag)
        lookupAcc.append(lookups(parsed, count: lookupCount, seed: seed ^ (pass + 1)))
    }
    let queryMs = sw.elapsedMs
    summary += "stats elements=\(stats.elements) texts=\(stats.texts) attributes=\(stats.attributes) text_bytes=\(stats.textBytes) max_depth=\(stats.maxDepth) hot=\(stats.hotCount) hot_weight=\(stats.hotWeight)\n"
    for (tag, count) in zip(Tag.allCases, byTag) {
        summary += "tag \(tag.name) count=\(count)\n"
    }
    for (i, acc) in lookupAcc.enumerated() {
        summary += "lookups pass=\(i) acc=\(hex16(acc))\n"
    }

    // mutate
    sw = Stopwatch()
    var m = Mutations()
    mutate(parsed, &m)
    var mutated: [UInt8] = []
    mutated.reserveCapacity(markup.count)
    serialize(parsed, into: &mutated)
    let mutateMs = sw.elapsedMs
    h = Fnv1a()
    h.update(mutated)
    summary += "mutate purged=\(m.purged) marked=\(m.marked) reversed=\(m.reversed) bytes=\(mutated.count) hash=\(hex16(h.value))\n"

    let serializedBytes = markup.count

    // free
    sw = Stopwatch()
    _ = consume original
    _ = consume parsed
    markup.removeAll()
    mutated.removeAll()
    let freeMs = sw.elapsedMs

    let totalMs = total.elapsedMs
    h = Fnv1a()
    h.update(summary.utf8)
    let checksum = h.value

    if !quiet {
        print(summary, terminator: "")
    }
    var report = Report(benchmark: "document-tree")
    report.int("nodes", nodes)
    report.int("fanout", fanout)
    report.int("passes", passes)
    report.int("lookups", lookupCount)
    report.int("seed", seed)
    report.int("node_count", stats.elements + stats.texts)
    report.int("max_depth", stats.maxDepth)
    report.int("serialized_bytes", serializedBytes)
    report.ms("build_ms", buildMs)
    report.ms("serialize_ms", serializeMs)
    report.ms("parse_ms", parseMs)
    report.ms("query_ms", queryMs)
    report.ms("mutate_ms", mutateMs)
    report.ms("free_ms", freeMs)
    report.ms("total_ms", totalMs)
    report.text("checksum", hex16(checksum))
    report.emit()
}

run()
