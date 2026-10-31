# document-tree

A DOM-style document tree: the data structure behind HTML/XML processing,
templating engines, scrapers, editors and configuration loaders. This is the
textbook case for ARC versus ownership, because every node is a separately
allocated object that other code reaches through references.

## What it does

1. **build** - construct a tree of `--nodes` nodes directly in memory from a
   seeded PRNG. Elements carry a tag, zero to three attributes (`id`, `class`,
   `href`, `data-weight`, `title`) and children; text nodes carry a short
   sentence. The node budget is split among children so the tree stays roughly
   balanced; with the defaults it is about 19 levels deep.

2. **serialize** - render the tree to markup, escaping `& < > "`, into one byte
   buffer:

   ```
   <section id="n48213" class="hot" data-weight="412"><p>lorem ipsum R&amp;D</p><ul>...</ul></section>
   ```

3. **parse** - recursive-descent parse of that buffer back into a second,
   independent tree, with entity unescaping. A structural hash of both trees is
   compared to prove the round trip is lossless.

4. **query** - `--passes` rounds of (a) a full traversal collecting node and
   attribute counts, text bytes, max depth, a per-tag histogram, and the count
   and summed `data-weight` of elements with `class="hot"` (a
   `querySelectorAll(".hot")` stand-in), then (b) `--lookups` random
   root-to-leaf walks, which is pure pointer chasing.

5. **mutate** - in place on the parsed tree: remove every `<ad>` subtree, stamp
   `data-visited="1"` on hot elements, reverse the children of every `<ul>`,
   then serialize the result again.

6. **free** - release both trees and both buffers.

Swift models a node as a `final class Node` with a `[Node]` children array,
which is how every Swift DOM library does it. Rust models it as an owned
`enum Node { Element { tag, attributes, children: Vec<Node> }, Text(String) }`:
children live inline in their parent's `Vec`, there are no reference counts, and
the whole tree is freed by one drop of the root. Tag and attribute *names* are
closed enums in both languages, the stand-in for the interned atoms every real
DOM uses, so that the memory comparison is about nodes, arrays and reference
counts rather than about how each language stores a three-letter string.
Attribute values and text content are ordinary owned strings. Both parse
through plain byte buffers (`&[u8]` and `[UInt8]`) indexed by integers, so
neither side pays the `String.Index` overhead seen in log-analytics.

## Knobs

| knob | default | effect |
|---|---|---|
| `--nodes` | 500000 | total elements + text nodes (exact) |
| `--fanout` | 6 | children per element drawn uniformly from 1..2*fanout; smaller means deeper |
| `--passes` | 3 | query rounds |
| `--lookups` | 200000 | random root-to-leaf walks per round |
| `--seed` | 42 | PRNG seed |

```sh
./run.py
./run.py --nodes 2000000 --runs 5
./run.py --fanout 2 --passes 10     # deep tree, traversal-heavy
```

## Sample result

Apple M1 Max, macOS, Swift 6.4, Rust 1.99, 2026-10-31, median of 5 runs:

| language | wall (ms) | in-process (ms) | build (ms) | serialize (ms) | parse (ms) | query (ms) | mutate (ms) | free (ms) | peak RSS (MB) | binary (KB) |
|---|---|---|---|---|---|---|---|---|---|---|
| swift 6.4 | 768.5 | 758.2 | 90.4 | 96.0 | 153.6 | 171.2 | 89.0 | 63.8 | 187.5 | 150 |
| rust 1.99.0 | 391.1 | 383.3 | 79.4 | 37.4 | 69.1 | 64.8 | 34.7 | 37.6 | 169.8 | 505 |
| swift / rust | 1.96x | 1.98x | 1.14x | 2.57x | 2.22x | 2.64x | 2.57x | 1.70x | 1.10x | 0.30x |

## Findings and caveats

- **Peak memory is within 10%.** Live heap sampled inside the programs after
  parsing (both trees plus the 19 MB of markup) is 144 MB for Rust and 174 MB
  for Swift. The difference is structural: every Swift node is a heap object
  with a 16-byte header, and each of its two arrays has a 32-byte header, where
  Rust stores nodes inline in their parent's `Vec`. Swift makes 2.1
  allocations per node, Rust 2.9 (every attribute value and text is a heap
  `String`; Swift keeps values of up to 15 bytes inline).

- **Building the tree is nearly even.** Constructing 500k reference-counted
  objects costs 14% more than constructing 500k owned enum values; the
  allocation counts above explain why it is not more.

- **Traversal, serialization and mutation are 2.2 to 2.6x slower in Swift.**
  A sampling profile of a long query phase shows roughly 18% of samples in
  `swift_retain` / `swift_release` (each `node = node.children[i]` hop and each
  `for child in children` iteration adjusts a reference count) and another 12%
  in `swift_beginAccess` / `swift_endAccess`, the runtime exclusivity checks
  Swift performs on class stored-property accesses in release builds. Rust's
  `&Node` hops are plain pointer loads. In-place mutation through a class
  reference additionally pays a uniqueness check before each array mutation.

- **Freeing is 1.7x slower in Swift.** Releasing 1M objects one by one versus
  dropping owned vectors whose elements are contiguous in memory.

- **The two parsers are deliberately not identical.** Rust's `Vec` starts at a
  capacity of 4 and doubles, and a `Node` is 72 bytes stored inline, so a tree
  built by `push` carries about 60 MB of unused capacity at its peak; the
  macOS allocator keeps those pages resident even after `shrink_to_fit`. The
  Rust parser therefore accumulates children and attributes on an open-element
  stack and moves them into exactly sized vectors with `split_off`, a standard
  parser technique. The same technique in Swift measured 21 MB *larger* and 10%
  slower (`Array(slice)` over-allocates and every move is a retain/release),
  while plain `append` on arrays of 8-byte references, which grow from a
  capacity of 1, leaves little slack. Each side therefore uses the lean idiom
  for its language. Before this change Rust's peak RSS was 296 MB and Swift's
  195 MB, which said more about `Vec`'s growth policy than about ownership.

- **Interned names matter more for Rust.** With `String` tag and attribute
  names, Rust performed 5.5 allocations per node (versus 2.1 for Swift, whose
  small strings are inline) and used 117 MB for the built tree against Swift's
  85 MB. Switching both languages to enums removed that confound and made Rust
  faster across every phase.
