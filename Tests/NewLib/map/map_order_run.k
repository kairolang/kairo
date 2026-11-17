// Growth, capacity and insertion order of HashMap<u64, u64>, and the index
// after removals: capacity changes exactly when an insert finds the table
// full, insertion order survives every growth, shift removal keeps order
// and swap removal moves the last entry, and the index stays consistent
// (every entry reachable from its home) after every removal in forward,
// reverse and random order. Two cases have broken backward-shift deletion
// before: a slot at its home followed by one far from its own, and a
// cluster that wraps past the last slot.

import std::io
import self::Inputs::table_peek::*

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
            var want = (if cap == 0 => 7usize else => cap * 2)
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
    ck(bad == 0, "growth exactly at 7/8, to double, with insertion order kept")
    ck(growths == 14, "14 growths to 40000 entries")
    var old? = m.insert(0, 99)
    ck(old? && old == 0 && m[0] == 99 && m.size() == 40000, "insert of a present key replaces in place")
}

fn test_reserve_shrink() {
    var m: {u64: u64}
    m.reserve(7)
    ck(m.capacity() == 7, "reserve(7)")
    m.reserve(100)
    ck(m.capacity() == 112, "reserve(100)")
    m.reserve(50)
    ck(m.capacity() == 112, "reserve never shrinks")
    for var i: u64 = 0; i < 1000; i += 1 { m.insert(i, i * 3) }
    m.reserve(5000)
    ck(m.capacity() == 7168, "reserve(5000)")
    ck(tp_ok(const &m, "after reserve"), "consistent after reserve")
    for var i: u64 = 10; i < 1000; i += 1 { m.shift_remove(i) }
    m.shrink_to_fit()
    ck(m.capacity() == 14, "shrink to fit 10 entries")
    ck(tp_ok(const &m, "after shrink"), "consistent after shrink")
    var bad: u64 = 0
    var j: u64 = 0
    for (k, v) in m {
        if k != j || v != j * 3 { bad += 1 }
        j += 1
    }
    ck(bad == 0 && j == 10, "contents and order after shrink")
    m.shrink_to_fit()
    ck(m.capacity() == 14, "shrink is idempotent")
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

/// Keys whose home slot in a fresh 8-slot table is `home`, as the table
/// itself reports it.
fn keys_with_home(home: usize, count: usize, start: u64) -> [u64] {
    var out: [u64]
    var c = start
    while out.size() < count {
        var m: {u64: u64}
        m.insert(c, 0)
        if tp_home_of(const &m, 0) == home { out.push(c) }
        c += 1
    }
    return out
}

fn test_erase_past_home() {
    // Homes 0, 2, 0, 0 land in slots 0, 2, 1, 3. Erasing slot 0 moves the
    // key in slot 1 back and must also move the one in slot 3, past the key
    // that sits at its home in slot 2.
    var h0 = keys_with_home(0, 3, 1000)
    var h2 = keys_with_home(2, 1, 2000)
    var m: {u64: u64}
    m.insert(h0[0], 1)
    m.insert(h2[0], 2)
    m.insert(h0[1], 3)
    m.insert(h0[2], 4)
    ck(m.capacity() == 7 && tp_home_of(const &m, 3) == 0, "one 8-slot block, homes as planned")
    m.shift_remove(h0[0])
    ck(tp_ok(const &m, "past home"), "consistent after an erase past an at-home slot")
    ck(m.contains(h0[2]) && m.contains(h0[1]) && m.contains(h2[0]), "every key still reachable")

    // A cluster across the wrap: homes 7, 7, 0, 7 land in 7, 0, 1, 2.
    var h7 = keys_with_home(7, 3, 3000)
    var z = keys_with_home(0, 1, 4000)
    var w: {u64: u64}
    w.insert(h7[0], 1)
    w.insert(h7[1], 2)
    w.insert(z[0], 3)
    w.insert(h7[2], 4)
    w.swap_remove(h7[0])
    ck(tp_ok(const &w, "wrap"), "consistent after an erase across the wrap")
    ck(w.contains(h7[1]) && w.contains(z[0]) && w.contains(h7[2]), "keys after a wrapped erase")
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
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
