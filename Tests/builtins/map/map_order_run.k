// Growth, capacity and insertion order of HashMap<u64, u64>, and the index
// after removals: capacity changes exactly when an insert finds the table
// full, insertion order survives every growth, shift removal keeps order
// and swap removal moves the last entry, and the index stays consistent
// (every entry reachable from its home) after every removal in forward,
// reverse and random order. An erase in a full bucket leaves a tombstone so
// the keys past the bucket stay reachable, also across the wrap past the
// last bucket; a table whose room tombstones have used up is rebuilt in
// place.

import std::io
import self::inputs::table_peek::*

var checks: u64 = 0
var failures: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

class Rng {
    var s: u64
    pub fn Rng(self, seed: u64) { self.s = seed * 0x9E3779B97F4A7C15 + 1 }
    pub fn next(self) -> u64 {
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s
    }
    pub fn below(self, n: u64) -> u64 { return self.next() % n }
}

fn test_growth() {
    var m: {u64: u64}
    var growths: u64 = 0
    var bad: u64 = 0
    for var i: u64 = 0; i < 40000; i += 1 {
        var cap = m.capacity()
        var full = m.size() == cap
        m.insert(i * 2654435761, i)
        var now = m.capacity()
        if full {
            var want = (if cap == 0 => 8usize else => cap * 2)
            if now != want { bad += 1 }
            growths += 1
            var j: u64 = 0
            for (k, v) in m {
                if k != j * 2654435761 || v != j { bad += 1 }
                j += 1
            }
            ck(tp_ok(const &m, f"growth {growths}"), "consistent after growth")
        } else if now != cap {
            bad += 1
        }
    }
    ck(bad == 0, "growth exactly when full, to double, with insertion order kept")
    ck(growths == 14, "14 growths to 40000 entries")
    var old? = m.insert(0, 99)
    ck(old? && old == 0 && m[0] == 99 && m.size() == 40000, "insert of a present key replaces in place")
}

fn test_reserve_shrink() {
    var m: {u64: u64}
    m.reserve(7)
    ck(m.capacity() == 8, "reserve(7)")
    m.reserve(100)
    ck(m.capacity() == 128, "reserve(100)")
    m.reserve(50)
    ck(m.capacity() == 128, "reserve never shrinks")
    for var i: u64 = 0; i < 1000; i += 1 { m.insert(i, i * 3) }
    m.reserve(5000)
    ck(m.capacity() == 8192, "reserve(5000)")
    ck(tp_ok(const &m, "after reserve"), "consistent after reserve")
    for var i: u64 = 10; i < 1000; i += 1 { m.shift_remove(i) }
    m.shrink_to_fit()
    ck(m.capacity() == 16, "shrink to fit 10 entries")
    ck(tp_ok(const &m, "after shrink"), "consistent after shrink")
    var bad: u64 = 0
    var j: u64 = 0
    for (k, v) in m {
        if k != j || v != j * 3 { bad += 1 }
        j += 1
    }
    ck(bad == 0 && j == 10, "contents and order after shrink")
    m.shrink_to_fit()
    ck(m.capacity() == 16, "shrink is idempotent")
}

fn expect(const m: {u64: u64}, const want: [u64], const what: string) {
    var ok = m.size() == want.size()
    var i: usize = 0
    for e in m.entries() {
        if i >= want.size() || e.key != want[i] { ok = false }
        i += 1
    }
    ck(ok, what)
}

fn test_remove_order() {
    var a: {u64: u64}
    var b: {u64: u64}
    for var i: u64 = 0; i < 10; i += 1 {
        a.insert(i, i)
        b.insert(i, i)
    }
    a.shift_remove(3)
    expect(a, [0, 1, 2, 4, 5, 6, 7, 8, 9], "shift_remove keeps the order")
    b.swap_remove(3)
    expect(b, [0, 1, 2, 9, 4, 5, 6, 7, 8], "swap_remove moves the last entry into the hole")
    b.swap_remove(8)
    expect(b, [0, 1, 2, 9, 4, 5, 6, 7], "swap_remove of the last entry moves nothing")
    var p? = a.pop()
    ck(p? && p.0 == 9 && a.size() == 8, "pop takes the last entry")
    ck(tp_ok(const &a, "a") && tp_ok(const &b, "b"), "consistent after removals")
}

/// Keys whose home bucket in a two-bucket table is `home`, as the table
/// itself reports it.
fn keys_with_home(home: usize, count: usize, start: u64) -> [u64] {
    var out: [u64]
    var c = start
    while out.size() < count {
        var m: {u64: u64}
        m.reserve(14)
        m.insert(c, 0)
        if tp_home_of(const &m, 0) == home { out.push(c) }
        c += 1
    }
    return out
}

/// Thirteen keys with one home in a two-bucket table: twelve fill the home
/// bucket and the thirteenth lies in the other. Removing one of the twelve
/// must leave a tombstone, not an empty slot, or the thirteenth is cut off;
/// the next key with that home takes the tombstone and uses no room.
fn erase_in_full_bucket(home: usize, start: u64, swap: bool, const what: string) {
    var k = keys_with_home(home, 14, start)
    var m: {u64: u64}
    m.reserve(14)
    for var i: usize = 0; i < 13; i += 1 { m.insert(k[i], i as u64) }
    ck(m.capacity() == 16 && tp_nbuckets(const &m) == 2 && tp_home_of(const &m, 12) == home, f"{what}: two buckets, homes as planned")
    ck(tp_bucket_of(const &m, 12) == 1 - home, f"{what}: the thirteenth key lies in the other bucket")
    ck(tp_tombstones(const &m) == 0 && tp_room(const &m) == 3, f"{what}: no tombstone yet")
    if swap { m.swap_remove(k[0]) } else { m.shift_remove(k[0]) }
    ck(tp_ok(const &m, what), f"{what}: consistent after an erase in a full bucket")
    ck(tp_tombstones(const &m) == 1 && tp_room(const &m) == 3, f"{what}: the erase left a tombstone")
    var all = true
    for var i: usize = 1; i < 13; i += 1 { if !m.contains(k[i]) { all = false } }
    ck(all && !m.contains(k[0]), f"{what}: every other key still reachable")
    m.insert(k[13], 13)
    ck(tp_tombstones(const &m) == 0 && tp_room(const &m) == 3, f"{what}: the next key takes the tombstone")
    ck(tp_ok(const &m, what) && m.contains(k[13]) && m.contains(k[12]), f"{what}: consistent after the reuse")
    // In a bucket with an empty slot an erase leaves an empty slot.
    m.swap_remove(k[12])
    ck(tp_tombstones(const &m) == 0 && tp_room(const &m) == 4 && tp_ok(const &m, what), f"{what}: an erase beside an empty slot leaves none")
}

fn test_erase_past_home() {
    erase_in_full_bucket(0, 1000, false, "shift")
    erase_in_full_bucket(0, 2000, true, "swap")
    // The probe sequence from the last bucket wraps to the first.
    erase_in_full_bucket(1, 3000, true, "wrap")
    erase_in_full_bucket(1, 4000, false, "wrap, shift")
}

/// Tombstones use up the room of a two-bucket table (capacity 16). At most
/// half full, the index is rebuilt in place and the capacity stays; more
/// than half full, the block doubles.
fn test_tombstone_room() {
    var h0 = keys_with_home(0, 13, 5000)
    var h1 = keys_with_home(1, 5, 6000)

    // Twelve keys fill bucket 0; removing them leaves twelve tombstones
    // and room for four. The fifth key for bucket 1 finds no room.
    var m: {u64: u64}
    m.reserve(14)
    for var i: usize = 0; i < 12; i += 1 { m.insert(h0[i], i as u64) }
    for var i: usize = 0; i < 12; i += 1 { m.swap_remove(h0[i]) }
    ck(m.size() == 0 && tp_tombstones(const &m) == 12 && tp_room(const &m) == 4, "twelve tombstones, room for four")
    for var i: usize = 0; i < 4; i += 1 { m.insert(h1[i], i as u64) }
    ck(tp_room(const &m) == 0 && tp_tombstones(const &m) == 12 && m.capacity() == 16, "the room is used up")
    m.insert(h1[4], 4)
    ck(m.capacity() == 16 && m.size() == 5, "at most half full: the block stays")
    ck(tp_tombstones(const &m) == 0 && tp_room(const &m) == 11, "the index was rebuilt in place")
    var all = true
    for var i: usize = 0; i < 5; i += 1 { if !m.contains(h1[i]) || m[h1[i]] != i as u64 { all = false } }
    ck(all && tp_ok(const &m, "rebuilt"), "contents after the rebuild")

    // Thirteen keys with home 0, four of the first twelve removed: nine
    // live, four tombstones, room for three. Three keys for bucket 1 use
    // it up; the next insert finds twelve live entries and doubles.
    var g: {u64: u64}
    g.reserve(14)
    for var i: usize = 0; i < 13; i += 1 { g.insert(h0[i], i as u64) }
    for var i: usize = 0; i < 4; i += 1 { g.shift_remove(h0[i]) }
    ck(g.size() == 9 && tp_tombstones(const &g) == 4 && tp_room(const &g) == 3, "nine live, four tombstones")
    // A reserve the capacity covers clears the tombstones that hold the
    // room it promises.
    var r: {u64: u64}
    r.reserve(14)
    for var i: usize = 0; i < 13; i += 1 { r.insert(h0[i], i as u64) }
    for var i: usize = 0; i < 4; i += 1 { r.swap_remove(h0[i]) }
    r.reserve(12)
    ck(tp_tombstones(const &r) == 4 && tp_room(const &r) == 3, "reserve within the room changes nothing")
    r.reserve(16)
    ck(r.capacity() == 16 && tp_tombstones(const &r) == 0 && tp_room(const &r) == 7, "reserve rebuilds the index for its room")
    for var i: usize = 0; i < 5; i += 1 { r.insert(h1[i], i as u64) }
    r.insert(h0[0], 0)
    r.insert(h0[1], 1)
    ck(r.capacity() == 16 && r.size() == 16 && tp_ok(const &r, "reserved"), "the reserved inserts keep the block")

    for var i: usize = 0; i < 3; i += 1 { g.insert(h1[i], 100 + i as u64) }
    ck(tp_room(const &g) == 0 && g.capacity() == 16, "the room is used up again")
    g.insert(h1[3], 103)
    ck(g.capacity() == 32 && g.size() == 13 && tp_tombstones(const &g) == 0, "more than half full: the block doubles")
    all = true
    for var i: usize = 4; i < 13; i += 1 { if !g.contains(h0[i]) { all = false } }
    for var i: usize = 0; i < 4; i += 1 { if !g.contains(h1[i]) || g.contains(h0[i]) { all = false } }
    ck(all && tp_ok(const &g, "doubled"), "contents after the doubling")
    var j: usize = 4
    var ordered = true
    for (k, v) in g {
        if j < 13 { if k != h0[j] { ordered = false } } else { if k != h1[j - 13] { ordered = false } }
        j += 1
    }
    ck(ordered && j == 17, "insertion order after the doubling")
}

/// Removes every entry of an n-entry map in forward, reverse and random key
/// order through swap_remove, shift_remove and pop, checking the index and
/// the size after each.
fn test_remove_all(n: u64) {
    for var order: u64 = 0; order < 3; order += 1 {
        for var form: u64 = 0; form < 3; form += 1 {
            var m: {u64: u64}
            var keys: [u64]
            for var i: u64 = 0; i < n; i += 1 {
                keys.push(if order == 1 => n - 1 - i else => i)
                m.insert(i * 0x9E3779B97F4A7C15, i + 1000)
            }
            if order == 2 {
                var r = Rng(order * 10 + form)
                var i = n
                while i > 1 {
                    var j = r.below(i)
                    var t = keys[(i - 1) as usize]
                    keys[(i - 1) as usize] = keys[j as usize]
                    keys[j as usize] = t
                    i -= 1
                }
            }
            var bad: u64 = 0
            for var i: u64 = 0; i < n; i += 1 {
                var k = keys[i as usize]
                if form == 0 {
                    var got? = m.swap_remove(k * 0x9E3779B97F4A7C15)
                    if !got? || got != k + 1000 { bad += 1 }
                } else if form == 1 {
                    var got? = m.shift_remove(k * 0x9E3779B97F4A7C15)
                    if !got? || got != k + 1000 { bad += 1 }
                } else {
                    var got? = m.pop()
                    if got? { k = got.1 - 1000 } else { bad += 1 }
                }
                if m.contains(k * 0x9E3779B97F4A7C15) { bad += 1 }
                if m.size() as u64 != n - 1 - i { bad += 1 }
                if tp_check(const &m) != 0 { bad += 1 }
            }
            ck(bad == 0, f"remove all, order {order}, form {form}")
        }
    }
}

fn main() -> i32 {
    test_growth()
    test_reserve_shrink()
    test_remove_order()
    test_erase_past_home()
    test_tombstone_room()
    test_remove_all(700)
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// The tag compare as one 128-bit word, the form targets without SSE2 take.
// RUN: %kairo_new %s -O2 -DKAIRO_TABLE_NO_SIMD -o %t.word.exe --cache-dir %t.dw
// RUN: %t.word.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
