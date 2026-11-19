// What `iter()` of a slice and of a vector gives a chain: both ends and
// the count. `rev()`, `next_back()` and `remaining()` work on the chain
// itself and through the adapters that keep them (`map`, `enumerate`, `zip`,
// `take`, `skip`, `copied`), and a `collect` of such a chain sizes its
// vector once: the capacity is the length.

import std::iter::*
import std::io

var failed: i32 = 0

fn hold(const label: string, cond: bool) {
    if !cond {
        failed += 1
        io::println(f"FAILED {label}")
    }
}

fn triple(x: i32) -> i32 = x * 3
fn deref(p: *const i32) -> i32 = *p
fn digits(acc: i64, x: i32) -> i64 = acc * 10 + (x as i64)
fn at(acc: i64, e: (usize, i32)) -> i64 = acc * 100 + (e.0 as i64) * 10 + (e.1 as i64)
fn product(e: (i32, i32)) -> i32 = e.0 * e.1
fn bump(p: *i32) {
    *p += 10
}

/// The source itself, with no chain around it.
fn bare() {
    var v: [i32] = [1, 2, 3, 4, 5]
    var s: [const i32;] = v
    var it = s.iter()
    hold("remaining", it.remaining() == 5)
    var a? = it.next()
    var z? = it.next_back()
    hold("both ends", a? && z? && *unwrap!(a) == 1 && *unwrap!(z) == 5 && it.remaining() == 3)
    hold("the rest as a slice", it.as_slice().size() == 3 && it.as_slice()[0] == 2)
    it.keep_first(2)
    hold("keep_first", it.remaining() == 2 && it.as_slice()[1] == 3)
    it.keep_last(1)
    hold("keep_last", it.remaining() == 1 && it.as_slice()[0] == 3)
    it.keep_last(4)
    hold("keep more than is left", it.remaining() == 1)
    var m? = it.next_back()
    var none? = it.next()
    var none_back? = it.next_back()
    hold("the two ends meet", m? && !none? && !none_back? && it.remaining() == 0)

    var total = 0
    for p in v.iter() {
        total = total * 10 + *p
    }
    hold("for over iter()", total == 12345)

    var e: [i32]
    var ev = e.iter()
    var nothing? = ev.next_back()
    hold("empty", ev.remaining() == 0 && !nothing?)
}

/// Writing through `iter_mut()`, from either end.
fn writes() {
    var v: [i32] = [1, 2, 3, 4]
    var m: [i32;] = v
    var it = m.iter_mut()
    hold("iter_mut remaining", it.remaining() == 4)
    var z? = it.next_back()
    *unwrap!(z) = 40
    var a? = it.next()
    *unwrap!(a) = 10
    hold("iter_mut ends", v[0] == 10 && v[3] == 40 && it.remaining() == 2)
    for p in m.iter_mut() {
        *p += 1
    }
    hold("for over iter_mut()", v[0] == 11 && v[1] == 3 && v[2] == 4 && v[3] == 41)
    iter(m.iter_mut()).rev().take(2).for_each(bump)
    hold("iter_mut chain", v[0] == 11 && v[1] == 3 && v[2] == 14 && v[3] == 51)
    for p in v.iter_mut() {
        *p -= 1
    }
    var w = v.iter_mut()
    var last? = w.next_back()
    hold("iter_mut of the vector", v[0] == 10 && v[3] == 50 && last? && *unwrap!(last) == 50 && w.remaining() == 3)
}

/// One chain shape over the vector's `iter()` and the slice's: the two are
/// one type and give one answer.
macro both!(label, want, tail) {
    {
        hold(label, iter(v.iter()) tail == want)
        hold(label, iter(s.iter()) tail == want)
    }
}

fn chains() {
    var v: [i32] = [1, 2, 3, 4, 5]
    var s: [const i32;] = v

    both!("rev", 54321, .copied().rev().fold<i64>(0, digits))
    both!("map rev", 15 * 10000 + 12 * 1000 + 9 * 100 + 6 * 10 + 3, .copied().map(triple).rev().fold<i64>(0, digits))
    both!("pointers rev", 54321, .rev().map(deref).fold<i64>(0, digits))
    both!("rev copied", 54321, .rev().copied().fold<i64>(0, digits))
    both!("take rev", 321, .copied().take(3).rev().fold<i64>(0, digits))
    both!("skip rev", 543, .copied().skip(2).rev().fold<i64>(0, digits))
    both!("rev take", 54, .copied().rev().take(2).fold<i64>(0, digits))
    both!("rev skip", 21, .copied().rev().skip(3).fold<i64>(0, digits))
    both!("enumerate", 1 * 1000000 + 12 * 10000 + 23 * 100 + 34, .copied().enumerate().take(4).fold<i64>(0, at))
    both!("zip", 5 + 8 + 9 + 8 + 5, .copied().zip(iter(v.iter()).copied().rev()).map(product).sum())

    both!("remaining", 5, .remaining())
    both!("remaining copied", 5, .copied().remaining())
    both!("remaining map", 5, .copied().map(triple).remaining())
    both!("remaining enumerate", 5, .enumerate().remaining())
    both!("remaining take", 3, .take(3).remaining())
    both!("remaining take past the end", 5, .take(9).remaining())
    both!("remaining skip", 3, .skip(2).remaining())
    both!("remaining skip past the end", 0, .skip(9).remaining())
    both!("remaining rev", 5, .rev().remaining())
    both!("remaining zip", 2, .copied().zip(iter(v.iter()).take(2)).remaining())
    both!("remaining of a long chain", 2, .copied().map(triple).enumerate().skip(1).take(2).remaining())
}

/// `next_back()` on the chain, with no `rev()`.
fn back() {
    var v: [i32] = [1, 2, 3, 4, 5]
    var c = iter(v.iter()).copied().map(triple)
    var z? = c.next_back()
    var a? = c.next()
    hold("next_back through map", z? && a? && unwrap!(z) == 15 && unwrap!(a) == 3 && c.remaining() == 3)
    var p = iter(v.iter())
    var last? = p.next_back()
    hold("next_back of pointers", last? && *unwrap!(last) == 5)
    var r = iter(v.iter()).copied().rev()
    var first? = r.next_back()
    hold("next_back of rev is the front", first? && unwrap!(first) == 1)
    // A chain is the second part of a reversed chain.
    hold("chain of two chains, reversed", iter(v.iter()).copied().take(2).chain(iter(v.iter()).copied().skip(3)).rev().fold<i64>(0, digits) == 5421)
}

/// A vector collected from a chain that knows its length is allocated once,
/// for exactly its items.
fn collects() {
    var v: [i32] = [1, 2, 3, 4, 5]
    var s: [const i32;] = v
    var a = iter(v.iter()).copied().map(triple).collect<[i32]>()
    hold("collect of a vector's iter", a.size() == 5 && a.capacity() == 5 && a[4] == 15)
    var b = iter(s.iter()).copied().map(triple).collect<[i32]>()
    hold("collect of a slice's iter", b.size() == 5 && b.capacity() == 5 && b[0] == 3)
    var c = iter(v.iter()).copied().rev().collect<[i32]>()
    hold("collect rev", c.size() == 5 && c.capacity() == 5 && c[0] == 5)
    var d = iter(v.iter()).copied().enumerate().collect<[(usize, i32)]>()
    hold("collect enumerate", d.size() == 5 && d.capacity() == 5 && d[4].0 == 4 && d[4].1 == 5)
    var e = iter(v.iter()).copied().zip(iter(s.iter()).copied().take(3)).collect<[(i32, i32)]>()
    hold("collect zip", e.size() == 3 && e.capacity() == 3 && e[2].1 == 3)
    var f = iter(v.iter()).copied().take(2).collect<[i32]>()
    hold("collect take", f.size() == 2 && f.capacity() == 2 && f[1] == 2)
    var g = iter(v.iter()).copied().skip(4).collect<[i32]>()
    hold("collect skip", g.size() == 1 && g.capacity() == 1 && g[0] == 5)
    var h = iter(v.iter()).enumerate().collect<[(usize, *const i32)]>()
    hold("collect pointers", h.size() == 5 && h.capacity() == 5 && *h[2].1 == 3)
}

fn walk(const s: [const i32;]) -> yield *const i32 {
    var i: usize = 0
    while i < s.size() {
        yield const &s[i]
        i += 1
    }
}

/// `copied()` over a generator of pointers, which has one end and no count.
fn generators() {
    var v: [i32] = [1, 2, 3, 4, 5]
    hold("generator copied", iter(walk(v)).copied().fold<i64>(0, digits) == 12345)
    hold("generator copied map", iter(walk(v)).copied().map(triple).sum() == 45)
    var c = iter(walk(v)).copied().collect<[i32]>()
    hold("generator collect", c.size() == 5 && c[4] == 5)
    hold("generator pointers", iter(walk(v)).map(deref).take(2).fold<i64>(0, digits) == 12)
}

fn main() -> i32 {
    generators()
    bare()
    writes()
    chains()
    back()
    collects()
    return if failed == 0 => 0 else => 1
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: rm -f %t.O2.exe
// RUN: rm -rf %t.d
// RUN: %kairo -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
