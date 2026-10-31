//! document-tree: build a DOM-like tree of heap nodes, serialize it to markup,
//! parse the markup back into a second tree, run query passes over it, mutate
//! it in place, serialize again, then free everything. See ../README.md.

use benchkit::{Args, Fnv1a, Report, SplitMix64, Stopwatch};
use std::fmt::Write as _;

/// Element names. A real DOM interns its known vocabulary (html5ever's `Atom`,
/// WebKit's `QualifiedName`); a closed enum is the idiomatic stand-in and keeps
/// string representation details out of the memory comparison.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Tag {
    Div, Span, P, Ul, Li, A, Section, Article, H2, Table, Tr, Td, Ad, Img, Nav, Footer,
}

impl Tag {
    const ALL: [Tag; 16] = [
        Tag::Div, Tag::Span, Tag::P, Tag::Ul, Tag::Li, Tag::A, Tag::Section, Tag::Article,
        Tag::H2, Tag::Table, Tag::Tr, Tag::Td, Tag::Ad, Tag::Img, Tag::Nav, Tag::Footer,
    ];
    const NAMES: [&'static str; 16] = [
        "div", "span", "p", "ul", "li", "a", "section", "article", "h2", "table", "tr", "td", "ad",
        "img", "nav", "footer",
    ];

    fn name(self) -> &'static str {
        Self::NAMES[self as usize]
    }

    fn parse(bytes: &[u8]) -> Option<Tag> {
        Self::NAMES.iter().position(|n| n.as_bytes() == bytes).map(|i| Self::ALL[i])
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum AttrName {
    Id, Class, Href, DataWeight, Title, DataVisited,
}

impl AttrName {
    const ALL: [AttrName; 6] = [
        AttrName::Id, AttrName::Class, AttrName::Href, AttrName::DataWeight, AttrName::Title,
        AttrName::DataVisited,
    ];
    const NAMES: [&'static str; 6] = ["id", "class", "href", "data-weight", "title", "data-visited"];

    fn name(self) -> &'static str {
        Self::NAMES[self as usize]
    }

    fn parse(bytes: &[u8]) -> Option<AttrName> {
        Self::NAMES.iter().position(|n| n.as_bytes() == bytes).map(|i| Self::ALL[i])
    }
}

const CLASSES: &[&str] = &["row", "col", "card", "hot", "nav-item", "muted", "hero", "list"];
const WORDS: &[&str] = &[
    "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do",
    "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore", "magna", "aliqua", "R&D",
    "<tag>",
];

struct Attribute {
    name: AttrName,
    value: String,
}

/// A node owns its children outright; the whole tree is one ownership hierarchy
/// and is freed by a single drop of the root.
enum Node {
    Element {
        tag: Tag,
        attributes: Vec<Attribute>,
        children: Vec<Node>,
    },
    Text(String),
}

fn attr(attributes: &[Attribute], name: AttrName) -> Option<&str> {
    attributes.iter().find(|a| a.name == name).map(|a| a.value.as_str())
}

// ---- phase 1: build ---------------------------------------------------------------

fn pick<'a>(rng: &mut SplitMix64, items: &[&'a str]) -> &'a str {
    items[rng.below(items.len() as u64) as usize]
}

fn random_text(rng: &mut SplitMix64) -> String {
    let words = 3 + rng.below(10);
    let mut s = String::new();
    for i in 0..words {
        if i > 0 {
            s.push(' ');
        }
        s.push_str(pick(rng, WORDS));
    }
    s
}

fn random_attributes(rng: &mut SplitMix64) -> Vec<Attribute> {
    let n = rng.below(4) as usize;
    let mut attributes = Vec::with_capacity(n);
    for _ in 0..n {
        let (name, value) = match rng.below(5) {
            0 => (AttrName::Id, format!("n{}", rng.below(1_000_000))),
            1 => (AttrName::Class, pick(rng, CLASSES).to_string()),
            2 => (AttrName::Href, format!("/p/{}", rng.below(100_000))),
            3 => (AttrName::DataWeight, rng.below(1000).to_string()),
            _ => {
                let a = pick(rng, WORDS);
                let b = pick(rng, WORDS);
                (AttrName::Title, format!("{a} {b}"))
            }
        };
        attributes.push(Attribute { name, value });
    }
    attributes
}

/// Builds an element with exactly `budget` descendants, spreading the budget
/// across its children so that the tree stays roughly balanced.
fn build_element(rng: &mut SplitMix64, fanout: u64, budget: u64) -> Node {
    let tag = Tag::ALL[rng.below(Tag::ALL.len() as u64) as usize];
    let attributes = random_attributes(rng);
    let mut children = Vec::new();
    if budget > 0 {
        let k = budget.min(1 + rng.below(2 * fanout));
        let mut remaining = budget - k;
        let mut prev_text = false;
        children.reserve(k as usize);
        for i in 0..k {
            let last = i == k - 1;
            let roll = rng.below(100);
            let is_text = !prev_text && !(last && remaining > 0) && roll < 30;
            if is_text {
                children.push(Node::Text(random_text(rng)));
                prev_text = true;
            } else {
                let share = if last {
                    remaining
                } else {
                    rng.below(remaining * 2 / (k - i) + 1).min(remaining)
                };
                remaining -= share;
                children.push(build_element(rng, fanout, share));
                prev_text = false;
            }
        }
    }
    Node::Element { tag, attributes, children }
}

// ---- phase 2: serialize -----------------------------------------------------------

fn escape_into(s: &str, out: &mut Vec<u8>) {
    for &b in s.as_bytes() {
        match b {
            b'&' => out.extend_from_slice(b"&amp;"),
            b'<' => out.extend_from_slice(b"&lt;"),
            b'>' => out.extend_from_slice(b"&gt;"),
            b'"' => out.extend_from_slice(b"&quot;"),
            _ => out.push(b),
        }
    }
}

fn serialize(node: &Node, out: &mut Vec<u8>) {
    match node {
        Node::Text(text) => escape_into(text, out),
        Node::Element { tag, attributes, children } => {
            out.push(b'<');
            out.extend_from_slice(tag.name().as_bytes());
            for a in attributes {
                out.push(b' ');
                out.extend_from_slice(a.name.name().as_bytes());
                out.extend_from_slice(b"=\"");
                escape_into(&a.value, out);
                out.push(b'"');
            }
            out.push(b'>');
            for child in children {
                serialize(child, out);
            }
            out.extend_from_slice(b"</");
            out.extend_from_slice(tag.name().as_bytes());
            out.push(b'>');
        }
    }
}

// ---- phase 3: parse ---------------------------------------------------------------

/// Recursive-descent parser. Children and attributes are accumulated on scratch
/// stacks and moved into exactly sized vectors once a node is complete, so the
/// tree carries no growth slack (the usual open-element-stack technique).
struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
    attr_stack: Vec<Attribute>,
    node_stack: Vec<Node>,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn take_until(&mut self, stop: impl Fn(u8) -> bool) -> &'a [u8] {
        let start = self.pos;
        while let Some(b) = self.peek() {
            if stop(b) {
                break;
            }
            self.pos += 1;
        }
        &self.bytes[start..self.pos]
    }

    fn unescape(bytes: &[u8]) -> Option<String> {
        if !bytes.contains(&b'&') {
            return std::str::from_utf8(bytes).ok().map(str::to_owned);
        }
        let mut out = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'&' {
                let semi = bytes[i..].iter().position(|&b| b == b';')? + i;
                out.push(match &bytes[i + 1..semi] {
                    b"amp" => b'&',
                    b"lt" => b'<',
                    b"gt" => b'>',
                    b"quot" => b'"',
                    _ => return None,
                });
                i = semi + 1;
            } else {
                out.push(bytes[i]);
                i += 1;
            }
        }
        String::from_utf8(out).ok()
    }

    fn parse_node(&mut self) -> Option<Node> {
        if self.peek()? != b'<' {
            let text = self.take_until(|b| b == b'<');
            return Some(Node::Text(Self::unescape(text)?));
        }
        self.pos += 1;
        let tag_bytes = self.take_until(|b| b == b' ' || b == b'>');
        let tag = Tag::parse(tag_bytes)?;

        let attr_mark = self.attr_stack.len();
        loop {
            while self.peek() == Some(b' ') {
                self.pos += 1;
            }
            if self.peek()? == b'>' {
                self.pos += 1;
                break;
            }
            let name = self.take_until(|b| b == b'=');
            if self.bytes.get(self.pos..self.pos + 2) != Some(b"=\"") {
                return None;
            }
            self.pos += 2;
            let value = self.take_until(|b| b == b'"');
            if self.peek()? != b'"' {
                return None;
            }
            self.pos += 1;
            self.attr_stack.push(Attribute {
                name: AttrName::parse(name)?,
                value: Self::unescape(value)?,
            });
        }
        let attributes = self.attr_stack.split_off(attr_mark);

        let node_mark = self.node_stack.len();
        loop {
            if self.bytes.get(self.pos..self.pos + 2) == Some(b"</") {
                break;
            }
            let child = self.parse_node()?;
            self.node_stack.push(child);
        }
        let children = self.node_stack.split_off(node_mark);

        self.pos += 2;
        let closing = self.take_until(|b| b == b'>');
        if closing != tag_bytes || self.peek()? != b'>' {
            return None;
        }
        self.pos += 1;
        Some(Node::Element { tag, attributes, children })
    }
}

fn parse(bytes: &[u8]) -> Option<Node> {
    let mut parser = Parser { bytes, pos: 0, attr_stack: Vec::new(), node_stack: Vec::new() };
    let root = parser.parse_node()?;
    (parser.pos == bytes.len()).then_some(root)
}

// ---- structural hash (used to verify the round trip) -----------------------------

fn hash_tree(node: &Node, h: &mut Fnv1a) {
    match node {
        Node::Text(text) => {
            h.byte(b'T');
            h.update(text.as_bytes());
            h.byte(0);
        }
        Node::Element { tag, attributes, children } => {
            h.byte(b'E');
            h.update(tag.name().as_bytes());
            h.byte(0);
            for a in attributes {
                h.update(a.name.name().as_bytes());
                h.byte(b'=');
                h.update(a.value.as_bytes());
                h.byte(0);
            }
            h.byte(b'>');
            for child in children {
                hash_tree(child, h);
            }
            h.byte(b'/');
        }
    }
}

// ---- phase 4: query ---------------------------------------------------------------

#[derive(Default)]
struct Stats {
    elements: u64,
    texts: u64,
    attributes: u64,
    text_bytes: u64,
    max_depth: u64,
    hot_count: u64,
    hot_weight: u64,
}

/// One full traversal collecting document statistics.
fn walk(node: &Node, depth: u64, stats: &mut Stats, by_tag: &mut [u64; 16]) {
    stats.max_depth = stats.max_depth.max(depth);
    match node {
        Node::Text(text) => {
            stats.texts += 1;
            stats.text_bytes += text.len() as u64;
        }
        Node::Element { tag, attributes, children } => {
            stats.elements += 1;
            stats.attributes += attributes.len() as u64;
            by_tag[*tag as usize] += 1;
            if attr(attributes, AttrName::Class) == Some("hot") {
                stats.hot_count += 1;
                if let Some(w) = attr(attributes, AttrName::DataWeight) {
                    stats.hot_weight += w.parse::<u64>().unwrap_or(0);
                }
            }
            for child in children {
                walk(child, depth + 1, stats, by_tag);
            }
        }
    }
}

/// Random root-to-leaf walks: pure pointer chasing.
fn lookups(root: &Node, count: u64, seed: u64) -> u64 {
    let mut rng = SplitMix64::new(seed);
    let mut acc = 0u64;
    for _ in 0..count {
        let mut node = root;
        let mut depth = 0u64;
        loop {
            match node {
                Node::Element { children, .. } if !children.is_empty() => {
                    node = &children[rng.below(children.len() as u64) as usize];
                    depth += 1;
                }
                _ => break,
            }
        }
        let first = match node {
            Node::Element { tag, .. } => tag.name().as_bytes()[0],
            Node::Text(text) => text.as_bytes()[0],
        };
        acc = acc.wrapping_mul(31).wrapping_add(depth * 256 + first as u64);
    }
    acc
}

// ---- phase 5: mutate --------------------------------------------------------------

#[derive(Default)]
struct Mutations {
    purged: u64,
    marked: u64,
    reversed: u64,
}

/// Drops every `<ad>` subtree, stamps `data-visited` on hot elements and
/// reverses the children of every `<ul>`, all in place.
fn mutate(node: &mut Node, m: &mut Mutations) {
    if let Node::Element { tag, attributes, children } = node {
        let before = children.len();
        children.retain(|c| !matches!(c, Node::Element { tag: Tag::Ad, .. }));
        m.purged += (before - children.len()) as u64;

        if attr(attributes, AttrName::Class) == Some("hot") {
            if let Some(a) = attributes.iter_mut().find(|a| a.name == AttrName::DataVisited) {
                a.value = "1".to_string();
            } else {
                attributes.push(Attribute { name: AttrName::DataVisited, value: "1".to_string() });
            }
            m.marked += 1;
        }

        if *tag == Tag::Ul {
            children.reverse();
            m.reversed += 1;
        }

        for child in children.iter_mut() {
            mutate(child, m);
        }
    }
}

// ---- main -------------------------------------------------------------------------

fn main() {
    let args = Args::parse();
    let nodes = args.u64("nodes", 500_000);
    let fanout = args.u64("fanout", 6).max(1);
    let passes = args.u64("passes", 3);
    let lookup_count = args.u64("lookups", 200_000);
    let seed = args.u64("seed", 42);
    let quiet = args.flag("quiet");

    let mut summary = String::new();
    let total = Stopwatch::start();

    // build
    let sw = Stopwatch::start();
    let mut rng = SplitMix64::new(seed);
    let original = build_element(&mut rng, fanout, nodes.saturating_sub(1));
    let build_ms = sw.elapsed_ms();

    // serialize
    let sw = Stopwatch::start();
    let mut markup = Vec::with_capacity(nodes as usize * 48);
    serialize(&original, &mut markup);
    let serialize_ms = sw.elapsed_ms();

    // parse
    let sw = Stopwatch::start();
    let Some(mut parsed) = parse(&markup) else {
        eprintln!("parse failed");
        std::process::exit(1);
    };
    let parse_ms = sw.elapsed_ms();

    let mut h = Fnv1a::new();
    hash_tree(&original, &mut h);
    let original_hash = h.finish();
    let mut h = Fnv1a::new();
    hash_tree(&parsed, &mut h);
    let parsed_hash = h.finish();
    writeln!(summary, "roundtrip original={original_hash:016x} parsed={parsed_hash:016x} bytes={}", markup.len()).unwrap();

    // query
    let sw = Stopwatch::start();
    let mut stats = Stats::default();
    let mut by_tag = [0u64; 16];
    let mut lookup_acc = Vec::new();
    for pass in 0..passes {
        stats = Stats::default();
        by_tag = [0u64; 16];
        walk(&parsed, 0, &mut stats, &mut by_tag);
        lookup_acc.push(lookups(&parsed, lookup_count, seed ^ (pass + 1)));
    }
    let query_ms = sw.elapsed_ms();
    writeln!(
        summary,
        "stats elements={} texts={} attributes={} text_bytes={} max_depth={} hot={} hot_weight={}",
        stats.elements, stats.texts, stats.attributes, stats.text_bytes, stats.max_depth,
        stats.hot_count, stats.hot_weight
    )
    .unwrap();
    for (tag, count) in Tag::ALL.iter().zip(by_tag) {
        writeln!(summary, "tag {} count={count}", tag.name()).unwrap();
    }
    for (i, acc) in lookup_acc.iter().enumerate() {
        writeln!(summary, "lookups pass={i} acc={acc:016x}").unwrap();
    }

    // mutate
    let sw = Stopwatch::start();
    let mut m = Mutations::default();
    mutate(&mut parsed, &mut m);
    let mut mutated = Vec::with_capacity(markup.len());
    serialize(&parsed, &mut mutated);
    let mutate_ms = sw.elapsed_ms();
    let mut h = Fnv1a::new();
    h.update(&mutated);
    writeln!(
        summary,
        "mutate purged={} marked={} reversed={} bytes={} hash={:016x}",
        m.purged, m.marked, m.reversed, mutated.len(), h.finish()
    )
    .unwrap();

    let serialized_bytes = markup.len() as u64;

    // free
    let sw = Stopwatch::start();
    drop(original);
    drop(parsed);
    drop(markup);
    drop(mutated);
    let free_ms = sw.elapsed_ms();

    let total_ms = total.elapsed_ms();
    let mut h = Fnv1a::new();
    h.update(summary.as_bytes());
    let checksum = h.finish();

    if !quiet {
        print!("{summary}");
    }
    Report::new("document-tree")
        .int("nodes", nodes)
        .int("fanout", fanout)
        .int("passes", passes)
        .int("lookups", lookup_count)
        .int("seed", seed)
        .int("node_count", stats.elements + stats.texts)
        .int("max_depth", stats.max_depth)
        .int("serialized_bytes", serialized_bytes)
        .ms("build_ms", build_ms)
        .ms("serialize_ms", serialize_ms)
        .ms("parse_ms", parse_ms)
        .ms("query_ms", query_ms)
        .ms("mutate_ms", mutate_ms)
        .ms("free_ms", free_ms)
        .ms("total_ms", total_ms)
        .text("checksum", &format!("{checksum:016x}"))
        .emit();
}
