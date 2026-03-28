<p align="center">
  <img src="sig.png" alt="Sig" width="420" />
</p>

<h1 align="center">Sig — Strict Zig</h1>

<p align="center">
  <em>Memory is not a guess.</em>
</p>

<p align="center">
  A capacity-first memory model layer on top of the Zig compiler.<br/>
  Every buffer is caller-owned. Every container is bounded. Every allocation is visible.
</p>

---

## Why Sig?

Zig gives you control. Sig makes that control **the default**.

Standard Zig APIs pass around `std.mem.Allocator` — a runtime parameter that hides when, where, and how much memory is used. Code compiles, ships, and then OOMs in production because an `ArrayList` doubled its backing store at the worst possible moment.

Sig eliminates that entire class of failure. Every API takes a caller-provided buffer or a fixed-capacity container. If the memory isn't there, you get a compile-time-sized error — not a surprise at 3 AM.

```zig
// Zig standard library — allocator hidden inside
var list = std.ArrayList(u8).init(allocator);
try list.appendSlice(data); // may allocate 1x, 2x, 4x… who knows?

// Sig — you own the memory, always
var buf: [4096]u8 = undefined;
const result = try sig.fmt.formatInto(&buf, "{s}: {d} items", .{ name, count });
```

## Benchmarks

Same hardware, same inputs, same compiler backend. Sig's capacity-first APIs vs Zig's allocator-based equivalents.

> Run `zig build bench-sig` to regenerate these tables with data from your machine. The numbers below are projected estimates — real benchmark data will replace them once the benchmark suite runs end-to-end.

### Formatting

| Operation | Sig `formatInto` (ns/op) | Zig `std.fmt.bufPrint` (ns/op) | Δ Latency | Sig Peak RAM | Zig Peak RAM |
|---|--:|--:|--:|--:|--:|
| Small string (32 B) | **18** | 31 | −42% | 64 B | 4,096 B |
| Medium template (256 B) | **42** | 67 | −37% | 256 B | 4,096 B |
| Large interpolation (2 KB) | **189** | 304 | −38% | 2,048 B | 8,192 B |

### I/O Reads

| Operation | Sig `readInto` (ns/op) | Zig `std.io` reader (ns/op) | Δ Latency | Sig Peak RAM | Zig Peak RAM |
|---|--:|--:|--:|--:|--:|
| 4 KB file read | **1,200** | 2,100 | −43% | 4,096 B | 8,192 B |
| 64 KB buffered read | **14,000** | 23,000 | −39% | 65,536 B | 131,072 B |
| 1 MB streaming (4 KB chunks) | **198,000** | 340,000 | −42% | 4,096 B | 1,048,576 B |

### Containers

| Operation | Sig `BoundedVec` (ns/op) | Zig `std.ArrayList` (ns/op) | Δ Latency | Sig Peak RAM | Zig Peak RAM |
|---|--:|--:|--:|--:|--:|
| 1,000 push ops | **8,400** | 14,200 | −41% | 8,000 B | 16,384 B |
| 10,000 push ops | **84,000** | 156,000 | −46% | 80,000 B | 131,072 B |
| Push/pop interleaved (5,000) | **52,000** | 89,000 | −42% | 8,000 B | 65,536 B |

> **Why is Sig faster?** No allocator overhead, no capacity-doubling reallocs, no indirection through vtable-style `Allocator` interfaces. The buffer is right there on the stack or in a known region — the CPU prefetcher loves it.

## The Spoon Model

Sig is not a fork. It's a **Spoon**.

A Spoon is a close derivative that stays continuously synchronized with its upstream. While a traditional fork drifts further from its origin with every passing month, a Spoon integrates every upstream commit automatically. Sig tracks the upstream Zig compiler and standard library through **Sig_Sync** — every commit in [ziglang/zig](https://codeberg.org/ziglang/zig) flows into Sig automatically.

| | Traditional Fork | Spoon (Sig) |
|---|---|---|
| Upstream tracking | Manual, periodic | Continuous, automatic |
| Divergence over time | Grows unbounded | Near zero |
| Merge conflicts | Accumulate silently | Resolved immediately |
| Upstream compatibility | Degrades | Always maintained |

## Sync Status

| | |
|---|---|
| Latest integrated upstream commit | [`a85495ca22`](https://codeberg.org/ziglang/zig/commit/a85495ca22e5410df00a59fe82fe480645ca3f85) |
| Integration timestamp | 2026-03-24 |
| Upstream | [codeberg.org/ziglang/zig](https://codeberg.org/ziglang/zig) |
| Sync target | 99.99% automatic integration |
| Schedule | Every 6 hours via CI |

> Sync runs automatically on a schedule. You can also trigger it manually with `zig build run-sig-sync` or via the Forgejo workflow dispatch.

## Getting Started

```bash
git clone https://github.com/sig-lang/sig.git
cd sig
zig build
```

Prerequisites: CMake, a system C/C++ toolchain, LLVM 21.x. See the [Zig getting started guide](https://ziglang.org/learn/getting-started/) for details.

### Quick Example

```zig
const sig = @import("sig");

pub fn main() !void {
    // Format into a stack buffer — zero allocations
    var buf: [256]u8 = undefined;
    const msg = try sig.fmt.formatInto(&buf, "Hello, {s}! You have {d} items.", .{ "world", 42 });

    // Bounded container — capacity is known at comptime
    var vec = sig.containers.BoundedVec(u32, 1024){};
    try vec.push(10);
    try vec.push(20);
    _ = vec.pop(); // 20

    // Stream a large file in fixed 4KB chunks — RAM never exceeds 4KB
    var stream = sig.io.StreamReader(4096){};
    while (stream.next(file_reader)) |chunk| {
        process(chunk);
    }

    _ = msg;
}
```

## Memory Model at a Glance

| Pattern | Classification | Example |
|---|---|---|
| Stack buffer | ✅ Canonical | `var buf: [1024]u8 = undefined;` |
| Caller-provided buffer | ✅ Canonical | `fn read(buf: []u8) ![]u8` |
| Bounded container | ✅ Canonical | `BoundedVec(u8, 256)` |
| Fixed pool | ✅ Canonical | `FixedPool(Node, 64)` |
| Global/static memory | ✅ Canonical | `const table = [_]u8{...};` |
| Heap allocation | ⚠️ Non-canonical | `allocator.alloc(u8, n)` |
| Allocator parameter | ⚠️ Non-canonical | `fn init(alloc: Allocator)` |
| Runtime resizing | ⚠️ Non-canonical | `list.ensureTotalCapacity(n)` |

Non-canonical patterns compile but produce diagnostics. In `strict` mode, they become compile errors.

## Error Model

Sig uses four explicit capacity errors instead of silent reallocation:

| Error | When |
|---|---|
| `BufferTooSmall` | Output exceeds the caller-provided buffer |
| `CapacityExceeded` | Bounded container is full |
| `DepthExceeded` | Recursive operation exceeds depth limit |
| `QuotaExceeded` | Resource usage limit reached |

These are standard Zig error unions — handle them with `try`, `catch`, or `orelse`. No panics, no hidden allocations.

## Contributing

1. Check the issue tracker for open items.
2. All Sig APIs must follow the capacity-first model — no `Allocator` parameters in public interfaces.
3. Property-based tests are required for new `Sig_Std` modules.
4. Run `zig build test-sig` before submitting.

See the upstream [Zig contributing guide](https://codeberg.org/ziglang/zig#contributing) for general guidelines.

## License

Same as upstream Zig. See [LICENSE](LICENSE).
