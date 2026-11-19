// Entries that cannot move as bytes: a key that holds its own address and
// checks it on every use and in its destructor, and a move-only value that
// counts live objects and detects a double destroy or a read after a move.
// Growth, reserve, shrink and every removal form move them one by one;
// afterwards no object is left and none was destroyed twice. The key's
// hash is a constant, so the tables stay small.

import std::io
import self::inputs::table_peek::*

var checks: u64 = 0
var failures: u64 = 0
var live: i64 = 0
var errors: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

eval DEAD: u64 = 0xDEADDEADDEADDEAD

/// Not relocatable: `me` is its own address.
class NR {
    pub var v:  u64
    var me: unsafe *const NR

    pub fn NR(self, v: u64) {
        self.v = v
        unsafe { self.me = &self as unsafe *const NR }
        live += 1
    }

    @move pub fn NR(self, other: Self) {
        other.verify()
        self.v = other.v
        unsafe { self.me = &self as unsafe *const NR }
        other.v = DEAD
        live += 1
    }

    pub fn verify(const self) {
        unsafe {
            if self.me != (&self as unsafe *const NR) { errors += 1 }
        }
    }

    pub fn op finally(self) {
        self.verify()
        unsafe { self.me = &null }
        live -= 1
    }
}

extend NR impl Hash {
    fn hash(const self, @inout h: Hasher) {
    }

    fn op == (const self, const o: NR) -> bool {
        self.verify()
        o.verify()
        if self.v == DEAD || o.v == DEAD { errors += 1 }
        return self.v == o.v
    }
}

extend NR impl Copyable {
    fn copy(const self) -> NR {
        self.verify()
        return NR(self.v)
    }
}

/// Move-only, counted.
class MO {
    pub var v:     u64
    var state: u64

    pub fn MO(self, v: u64) {
        self.v = v
        self.state = 1
        live += 1
    }

    @move pub fn MO(self, other: Self) {
        if other.state != 1 { errors += 1 }
        self.v = other.v
        self.state = 1
        other.state = 2
        live += 1
    }

    pub fn op finally(self) {
        if self.state == 0 { errors += 1 }
        self.state = 0
        live -= 1
    }
}

fn keep_even(k: *const NR, v: *MO) -> bool {
    return k->v % 2 == 0
}

fn resolve(a: MO, b: MO) -> MO {
    return MO(a.v + b.v)
}

fn test_moving(n: u64) {
    ck(!__builtin_is_trivially_relocatable<MapEntry<NR, MO>>(), "the entry is not trivially relocatable")
    {
        var m: {NR: MO}
        for var i: u64 = 0; i < n; i += 1 {
            m.insert(NR(i), MO(i * 10))
        }
        ck(tp_ok(const &m, "built") && m.size() == n as usize, "built through growth")
        ck(live == 2 * (n as i64), "one key and one value per entry")
        var bad: u64 = 0
        for var i: u64 = 0; i < n; i += 1 {
            var *v? = m.get(NR(i))
            if !v? || v->v != i * 10 { bad += 1 }
        }
        var j: u64 = 0
        for (const *k, *v) in m {
            if k->v != j || v->v != j * 10 { bad += 1 }
            j += 1
        }
        ck(bad == 0, "contents and order after growth")

        m.reserve(4 * n as usize)
        ck(tp_ok(const &m, "reserve"), "reserve moves the entries")
        var r? = m.swap_remove(NR(3))
        ck(r? && r.v == 30 && m.entries()[3].key.v == n - 1, "swap_remove")
        r = m.shift_remove(NR(5))
        ck(r? && r.v == 50 && m.entries()[5].key.v == 6, "shift_remove")
        var p? = m.pop()
        ck(p? && p.0.v == n - 2 && p.1.v == (n - 2) * 10, "pop")
        ck(tp_ok(const &m, "removals"), "consistent after removals")
        m.shrink_to_fit()
        ck(tp_ok(const &m, "shrink"), "shrink moves the entries")
        m.retain(keep_even)
        bad = 0
        for (const *k, *v) in m {
            if k->v % 2 != 0 || v->v != k->v * 10 { bad += 1 }
        }
        ck(bad == 0 && tp_ok(const &m, "retain"), "retain")

        var o: {NR: MO}
        o.insert(NR(0), MO(1))
        o.insert(NR(n + 1), MO(7))
        m.merge(o, resolve)
        var *a? = m.get(NR(0))
        var *b? = m.get(NR(n + 1))
        ck(a? && b? && a->v == 1 && b->v == 7, "merge")
        var old? = m.insert(NR(n + 2), MO(9))
        ck(!old? && m.get(NR(n + 2))?, "insert of a new key")
        old = m.insert(NR(n + 2), MO(10))
        ck(old? && old.v == 9, "insert replaces and hands the old value back")
        var size = m.size()
        m.clear()
        ck(m.size() == 0 && tp_ok(const &m, "clear"), "clear")
        ck(size > 0, "something was cleared")
        for var i: u64 = 0; i < 100; i += 1 { m.insert(NR(i), MO(i)) }
    }
    ck(live == 0, f"no object left ({live})")
    ck(errors == 0, f"no double destroy, stale address or read after move ({errors})")
}

fn test_copy() {
    {
        var m: {NR: u64}
        for var i: u64 = 0; i < 300; i += 1 { m.insert(NR(i), i) }
        var c = m.copy()
        ck(c.size() == 300 && tp_ok(const &c, "copy"), "copy of non-relocatable keys")
        var bad: u64 = 0
        var j: u64 = 0
        for (const *k, *v) in c {
            if k->v != j || *v != j { bad += 1 }
            j += 1
        }
        ck(bad == 0, "copy keeps order")
        ck(live == 600, "copy built every key")
    }
    ck(live == 0 && errors == 0, "copies destroyed")
}

/// Every NR key has one home, so sixteen of them fill a two-bucket table:
/// twelve in the home bucket, four in the other. Removals in the full
/// bucket leave tombstones that hold the room. The next insert rebuilds
/// the index in place when the table is at most half full, with no entry
/// moved, and moves every entry to a block twice the size otherwise.
fn test_tombstone_room(remove: u64, grows: bool, const what: string) {
    {
        var m: {NR: MO}
        m.reserve(14)
        for var i: u64 = 0; i < 16; i += 1 { m.insert(NR(i), MO(i)) }
        ck(m.capacity() == 16 && tp_room(const &m) == 0, f"{what}: full")
        // The first twelve keys are the ones in the home bucket.
        for var i: u64 = 0; i < remove; i += 1 { m.swap_remove(NR(i)) }
        ck(tp_tombstones(const &m) == remove as usize && tp_room(const &m) == 0, f"{what}: tombstones hold the room")
        var first: usize = 0
        var after: usize = 0
        unsafe { first = tp_block(const &m) as usize }
        m.insert(NR(100), MO(100))
        unsafe { after = tp_block(const &m) as usize }
        var moved = after != first
        if grows {
            ck(m.capacity() == 32 && moved, f"{what}: the block doubles")
        } else {
            ck(m.capacity() == 16 && !moved, f"{what}: the index is rebuilt in place")
        }
        ck(tp_tombstones(const &m) == 0 && tp_ok(const &m, what), f"{what}: consistent")
        var bad: u64 = 0
        for var i: u64 = remove; i < 16; i += 1 {
            var *v? = m.get(NR(i))
            if !v? || v->v != i { bad += 1 }
        }
        var *n? = m.get(NR(100))
        ck(bad == 0 && n? && n->v == 100 && m.size() == (17 - remove) as usize, f"{what}: contents")
        ck(live == 2 * (17 - remove as i64), f"{what}: one key and one value per entry")
    }
    ck(live == 0 && errors == 0, f"{what}: all destroyed")
}

fn main() -> i32 {
    test_moving(1200)
    test_copy()
    test_tombstone_room(9, false, "rebuild")
    test_tombstone_room(3, true, "grow")
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
